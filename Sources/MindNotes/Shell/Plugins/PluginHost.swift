import AppKit
import CryptoKit
import Security
import SwiftUI

/// Хост плагинов (ADR-0019): установка пакетов `.mnplugin`, включение, привязанные клиенты и локальный API.
/// Код плагина здесь не исполняется: приложение только отвечает на запросы в пределах разрешений плагина.
@MainActor
final class PluginHost: ObservableObject {
    static let shared = PluginHost()

    weak var shell: ShellModel?

    @Published private(set) var clients: [PluginClient] = []
    @Published private(set) var enabled: [String: Bool] = [:]
    /// nil — слушатель работает или не нужен; иначе причина, по которой он не запустился.
    @Published private(set) var serverProblem: String?
    @Published private(set) var serverRunning = false

    private var server: LocalAPIServer?
    private let pairing = PluginPairing()
    /// Окно автоподключения (ADR-0019): после установки плагина фоновый запрос браузера может показать вопрос
    /// о подключении. Ключ без согласия пользователя не выдаётся.
    @Published private(set) var autoPairUntil: [String: Date] = [:]
    static let autoPairWindow: TimeInterval = 10 * 60
    /// Программа-установщик расширений Web Clipper (находится по идентификатору).
    static let installerBundleID = "local.personal.MindNotes.WebClipper"
    private static let enabledKey = "plugins.enabled"
    private static let clientsKey = "plugins.clients"

    private init() {
        enabled = (UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool]) ?? [:]
        if let data = UserDefaults.standard.data(forKey: Self.clientsKey), let saved = try? JSONDecoder().decode([PluginClient].self, from: data) {
            clients = PluginClient.deduplicated(saved)
            if clients.count != saved.count { saveClients() }
        }
    }

    // MARK: Состав

    struct Plugin: Identifiable {
        var manifest: PluginManifest
        var folder: URL
        var problem: String?
        var id: String { manifest.id }
    }

    var plugins: [Plugin] {
        ExtensionRegistry.shared.plugins.compactMap { item in
            item.plugin.map { Plugin(manifest: $0, folder: item.folder, problem: item.problem) }
        }
    }

    func plugin(_ id: String) -> Plugin? { plugins.first { $0.id == id } }

    func isEnabled(_ id: String) -> Bool { enabled[id] == true }

    /// Работает: установлен, без ошибок и включён.
    func isActive(_ id: String) -> Bool { plugin(id).map { $0.problem == nil && isEnabled($0.id) } ?? false }

    func setEnabled(_ id: String, _ on: Bool) {
        enabled[id] = on
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        refreshServer()
    }

    func registryChanged() {
        objectWillChange.send()
        refreshServer()
    }

    // MARK: Слушатель

    /// Слушатель нужен, только пока включён хотя бы один исправный плагин.
    func refreshServer() {
        let needed = plugins.contains { $0.problem == nil && isEnabled($0.id) }
        if needed {
            if server == nil {
                server = LocalAPIServer(handler: { [weak self] in await self?.handle($0) ?? .error(503, "unavailable", "MindNotes завершается") },
                                        onState: { [weak self] problem in
                                            self?.serverProblem = problem
                                            self?.serverRunning = problem == nil
                                            if problem != nil { self?.server = nil }
                                        })
                server?.start()
            }
        } else if let server {
            server.stop()
            self.server = nil
            serverRunning = false
            serverProblem = nil
        }
    }

    func retryServer() {
        server?.stop()
        server = nil
        serverProblem = nil
        refreshServer()
    }

    // MARK: Установка

    func presentInstall() {
        let panel = NSOpenPanel()
        panel.message = L("Выберите плагин MindNotes (.mnplugin)")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install(from: url)
    }

    /// Пакет копируется в папку расширений только после согласия; прежняя версия уходит в корзину.
    func install(from url: URL) {
        guard url.pathExtension.lowercased() == PluginManifest.packageExtension,
              let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else {
            alert(L("Это не плагин MindNotes"), L("Нужна папка-пакет .mnplugin с manifest.json."))
            return
        }
        let manifest: PluginManifest
        switch PluginManifest.parse(data) {
        case .success(let m): manifest = m
        case .failure(let problem): alert(L("Плагин не установлен"), Self.describe(problem)); return
        }
        let app = AppVersion((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")
        if let problem = manifest.problem(app: app) { alert(L("Плагин не установлен"), Self.describe(problem)); return }

        let registry = ExtensionRegistry.shared
        let destination = registry.folder.appendingPathComponent("\(manifest.id).\(PluginManifest.packageExtension)", isDirectory: true)
        let existing = registry.items.first { $0.id == manifest.id }
        // Та же версия уже стоит (установщик открывает пакет при каждом запуске). Повторное открытие пакета —
        // не решение пользователя: выключенный плагин не включается, окно подключения не открывается.
        if let existing, existing.manifest.version == manifest.version, existing.problem == nil {
            shell?.notice = isEnabled(manifest.id)
                ? String(format: L("Плагин «%@» уже установлен. Чтобы подключить браузер, нажмите «Подключить» в расширении."), manifest.name)
                : String(format: L("Плагин «%@» уже установлен, но выключен. Включите его в разделе «Расширения»."), manifest.name)
            return
        }
        let confirm = NSAlert()
        confirm.messageText = existing == nil ? String(format: L("Установить плагин «%@»?"), manifest.name)
                                              : String(format: L("Обновить плагин «%@» с версии %@ до %@?"), manifest.name, existing!.manifest.version, manifest.version)
        var text = ""
        if let summary = manifest.summary { text += summary + "\n\n" }
        text += L("Плагин сможет:") + "\n" + manifest.permissions.map { "• " + Self.title($0) }.joined(separator: "\n")
        text += "\n\n" + L("Код плагина не запускается внутри MindNotes: он работает в браузере и обращается к приложению только после того, как вы подключите его.")
        confirm.informativeText = text
        confirm.addButton(withTitle: existing == nil ? L("Установить") : L("Обновить"))
        confirm.addButton(withTitle: L("Отмена"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do { try copyIntoExtensions(url, destination: destination, replacing: existing?.folder) } catch {
            alert(L("Плагин не установлен"), error.localizedDescription)
            return
        }
        registry.reload()
        setEnabled(manifest.id, true)
        openAutoPair(manifest.id)
        shell?.goSettings()
        shell?.notice = String(format: L("Плагин «%@» установлен. Настройки — в разделе «Расширения»."), manifest.name)
    }

    /// Пакет в папку расширений: через временную копию, прежняя версия — в корзину.
    private func copyIntoExtensions(_ url: URL, destination: URL, replacing old: URL?) throws {
        let fm = FileManager.default
        let folder = ExtensionRegistry.shared.folder
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard url.standardizedFileURL != destination.standardizedFileURL else { return }
        let staging = folder.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: url, to: staging)
        if let old, fm.fileExists(atPath: old.path) { try fm.trashItem(at: old, resultingItemURL: nil) }
        if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
        try fm.moveItem(at: staging, to: destination)
    }

    /// Обновление плагина из выпуска (ADR-0019, п. 9). Доверенное — тот же плагин, версия новее, разрешений не больше —
    /// ставится без вопроса; иначе обычная установка с показом разрешений. Возвращает, стоит ли теперь новая версия.
    @discardableResult
    func installUpdate(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
              case .success(let manifest) = PluginManifest.parse(data) else { return false }
        let registry = ExtensionRegistry.shared
        let existing = registry.items.first { $0.id == manifest.id }
        let app = AppVersion((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")
        if let existing, let installed = existing.plugin, manifest.isTrustedUpdate(of: installed, app: app) {
            let destination = registry.folder.appendingPathComponent("\(manifest.id).\(PluginManifest.packageExtension)", isDirectory: true)
            do { try copyIntoExtensions(url, destination: destination, replacing: existing.folder) } catch { return false }
            registry.reload() // включённость и подключения браузеров сохраняются
            return true
        }
        install(from: url)
        return registry.items.first { $0.id == manifest.id }?.manifest.version == manifest.version
    }

    /// Удаление — в корзину Finder; подключения плагина отзываются.
    func uninstall(_ plugin: Plugin) {
        let confirm = NSAlert()
        confirm.messageText = String(format: L("Удалить плагин «%@»?"), plugin.manifest.name)
        confirm.informativeText = L("Пакет плагина уйдёт в корзину, подключённые браузеры потеряют доступ. Сохранённые страницы останутся.")
        confirm.addButton(withTitle: L("Удалить"))
        confirm.addButton(withTitle: L("Отмена"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do { try FileManager.default.trashItem(at: plugin.folder, resultingItemURL: nil) }
        catch { alert(L("Плагин не удалён"), error.localizedDescription); return }
        clients.removeAll { $0.plugin == plugin.id }
        saveClients()
        enabled[plugin.id] = nil
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        ExtensionRegistry.shared.reload()
    }

    /// Компонент плагина вне приложения: путь внутри пакета, если файл на месте.
    func component(_ name: String, of plugin: Plugin) -> URL? {
        guard let path = plugin.manifest.components[name] else { return nil }
        let url = plugin.folder.appendingPathComponent(path)
        guard url.standardizedFileURL.path.hasPrefix(plugin.folder.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Клиенты

    /// Окно открывает только действие пользователя: установка после согласия или кнопка в настройках.
    func openAutoPair(_ id: String) {
        autoPairUntil[id] = Date().addingTimeInterval(Self.autoPairWindow)
        pairing.windowOpened(id)
    }

    func isAutoPairOpen(_ id: String) -> Bool { (autoPairUntil[id] ?? .distantPast) > Date() }

    /// Установщик расширений, если он есть на этом Mac.
    var installerURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.installerBundleID) }

    func openInstaller() {
        guard let url = installerURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func revoke(_ client: PluginClient) {
        clients.removeAll { $0.id == client.id }
        saveClients()
    }

    private func saveClients() {
        if let data = try? JSONEncoder().encode(clients) { UserDefaults.standard.set(data, forKey: Self.clientsKey) }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func newToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func client(for request: LocalAPI.Request) -> PluginClient? {
        guard let token = request.bearer else { return nil }
        let hashed = Self.hash(token)
        return clients.first { $0.tokenHash == hashed }
    }

    // MARK: Запросы

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard LocalAPI.isAllowedOrigin(request.origin) else {
            return .error(403, "origin", L("Запросы принимаются только от расширений браузера."))
        }
        guard let route = LocalAPI.route(request) else { return .error(404, "not_found", L("Нет такого метода API.")) }
        if route == .options { return LocalAPI.Response(status: 204, body: Data()) }

        let caller = client(for: request)
        switch route {
        case .status:
            var out: [String: Any] = ["app": AppEdition.displayName, "api": PluginManifest.apiVersion, "features": LocalAPI.features,
                                      "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
                                      "workspace": shell?.isOpen == true, "paired": caller != nil]
            if let caller { out["plugin"] = caller.plugin; out["active"] = isActive(caller.plugin) }
            // Открытые окна автоподключения: расширение без ключа подключается само, не беспокоя пользователя.
            out["pairing"] = plugins.filter { isActive($0.id) && isAutoPairOpen($0.id) }.map(\.id)
            return .json(200, out)
        case .pair:
            return await pair(request)
        default: break
        }

        guard let caller else { return .error(401, "unpaired", L("Подключите расширение к MindNotes.")) }
        guard let plugin = plugin(caller.plugin), isActive(plugin.id) else {
            return .error(403, "plugin_disabled", L("Плагин выключен или удалён в MindNotes."))
        }
        if let needed = LocalAPI.permission(for: route), !plugin.manifest.permissions.contains(needed) {
            return .error(403, "permission", String(format: L("У плагина нет разрешения: %@."), Self.title(needed)))
        }
        if let i = clients.firstIndex(where: { $0.id == caller.id }) {
            clients[i].lastUsedAt = SystemClock().nowMillis()
            saveClients()
        }
        guard let shell, shell.isOpen else { return .error(409, "no_workspace", L("В MindNotes не открыто пространство.")) }

        switch route {
        case .targets:
            let targets = shell.clipTargets().prefix(2000).map { ["id": $0.id.uuidString.lowercased(), "title": $0.title, "path": $0.path, "folder": $0.isFolder] as [String: Any] }
            return .json(200, ["targets": Array(targets), "defaultFolder": ShellModel.clipFolderTitle])
        case .clips:
            var clip: WebClip
            switch WebClip.parse(request.body) {
            case .success(let c): clip = c
            case .failure(let problem): return .error(400, "bad_clip", Self.describe(problem))
            }
            if !clip.images.isEmpty || !clip.remoteImages.isEmpty, !plugin.manifest.permissions.contains(.assetsCreate) {
                return .error(403, "permission", String(format: L("У плагина нет разрешения: %@."), Self.title(.assetsCreate)))
            }
            if !clip.tags.isEmpty, !plugin.manifest.permissions.contains(.tagsWrite) {
                return .error(403, "permission", String(format: L("У плагина нет разрешения: %@."), Self.title(.tagsWrite)))
            }
            // Картинки с других сайтов скачивает приложение: расширению не нужен доступ ко всем сайтам.
            if !clip.remoteImages.isEmpty {
                let budget = WebClip.maxTotalImageBytes - clip.images.reduce(0) { $0 + $1.data.count }
                let fetched = await ClipImageFetcher.fetch(clip.remoteImages, budget: max(0, budget))
                clip = clip.resolvingRemote(fetched, label: L("Картинка"))
            }
            switch await shell.saveClip(clip) {
            case .success(let page): return .json(201, ["page": ["id": page.id.uuidString.lowercased(), "title": page.title]])
            case .failure(.noWorkspace): return .error(409, "no_workspace", L("В MindNotes не открыто пространство."))
            case .failure(.badParent): return .error(400, "bad_parent", L("Сюда сохранять нельзя: страница не найдена, закрыта паролем или это база."))
            case .failure(.failed(let message)): return .error(500, "save_failed", message)
            }
        case .openPage(let id):
            guard shell.pages.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return .error(404, "no_page", L("Страница не найдена.")) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            shell.openPage(id)
            return .json(200, ["ok": true])
        default:
            return .error(404, "not_found", L("Нет такого метода API."))
        }
    }

    /// Привязка клиента: только с согласия пользователя, один вопрос за раз (правила — в `PluginPairing`).
    private func pair(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        let browser = L(LocalAPI.browserName(origin: request.origin, userAgent: request.headers["user-agent"]))
        return await pairing.pair(request, now: Date(),
            isActive: { id in self.plugin(id).map { _ in self.isActive(id) } },
            isWindowOpen: { self.isAutoPairOpen($0) },
            closeWindow: { self.autoPairUntil[$0] = nil },
            ask: { id in
                guard let plugin = self.plugin(id) else { return false }
                NSApp.activate(ignoringOtherApps: true)
                let ask = NSAlert()
                ask.messageText = String(format: L("Подключить «%@» в %@?"), plugin.manifest.name, browser)
                var text = L("Расширение сможет:") + "\n" + plugin.manifest.permissions.map { "• " + Self.title($0) }.joined(separator: "\n")
                if let origin = request.origin { text += "\n\n" + String(format: L("Источник запроса: %@"), origin) }
                ask.informativeText = text + "\n\n" + L("Если вы не нажимали «Подключить» в браузере, откажитесь.")
                ask.addButton(withTitle: L("Подключить"))
                ask.addButton(withTitle: L("Отказать"))
                return ask.runModal() == .alertFirstButtonReturn
            },
            issue: { id in
                // Пока шёл вопрос, плагин могли выключить или удалить.
                guard let plugin = self.plugin(id), self.isActive(id) else {
                    return .error(403, "plugin_disabled", L("Плагин выключен в MindNotes."))
                }
                let reply = self.issueToken(plugin: plugin, browser: browser, origin: request.origin)
                if reply.status == 200 { self.shell?.notice = String(format: L("%@ подключён к MindNotes."), browser) }
                return reply
            })
    }

    private func issueToken(plugin: Plugin, browser: String, origin: String?) -> LocalAPI.Response {
        guard let token = Self.newToken() else { return .error(500, "token", L("Не удалось создать ключ подключения.")) }
        let client = PluginClient(id: UUID(), plugin: plugin.id, name: browser, tokenHash: Self.hash(token), createdAt: SystemClock().nowMillis(),
                                  origin: origin)
        clients = PluginClient.adding(client, to: clients)
        saveClients()
        return .json(200, ["token": token, "client": client.id.uuidString.lowercased(), "permissions": plugin.manifest.permissions.map(\.rawValue)])
    }

    // MARK: Тексты

    static func title(_ permission: PluginPermission) -> String {
        switch permission {
        case .pagesList: return L("видеть названия страниц и папок, куда можно сохранять (кроме закрытых паролем)")
        case .pagesCreate: return L("создавать новые страницы")
        case .pagesOpen: return L("показывать страницу в MindNotes")
        case .assetsCreate: return L("добавлять картинки во вложения")
        case .tagsWrite: return L("ставить теги на созданные страницы")
        }
    }

    static func describe(_ problem: PluginManifest.Problem) -> String {
        switch problem {
        case .unreadable: return L("manifest.json не читается")
        case .notPlugin: return L("это не плагин")
        case .newerAPI(let v): return String(format: L("нужна более новая версия MindNotes (API %d)"), v)
        case .unknownPermissions(let list): return String(format: L("нужна более новая версия MindNotes (разрешения: %@)"), list.joined(separator: ", "))
        case .badComponent(let name): return String(format: L("неверный путь компонента «%@»"), name)
        case .newerApp(let v): return String(format: L("нужна MindNotes %@ или новее"), v)
        }
    }

    static func describe(_ problem: WebClip.Problem) -> String {
        switch problem {
        case .unreadable: return L("Вырезка не читается.")
        case .badField(let field): return String(format: L("Неверное поле вырезки: %@."), field)
        case .tooLarge(let field): return String(format: L("Слишком большая вырезка: %@."), field)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// Плагины в «Настройки» → «Расширения»: включение, разрешения, компоненты, подключения.
struct PluginsSettings: View {
    @ObservedObject var host = PluginHost.shared
    @ObservedObject var registry = ExtensionRegistry.shared

    var body: some View {
        let plugins = host.plugins
        if !plugins.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(plugins) { plugin in card(plugin) }
                if host.serverRunning {
                    Text(String(format: L("Локальный API работает: %@:%d, только на этом Mac."), LocalAPI.host, Int(LocalAPI.port)))
                        .font(.system(size: 11)).foregroundColor(Tokens.muted)
                } else if let problem = host.serverProblem {
                    HStack {
                        Text(String(format: L("Локальный API не запустился: %@"), problem)).font(.system(size: 11)).foregroundColor(Tokens.danger)
                        Button("Повторить") { host.retryServer() }.buttonStyle(NotesButtonStyle(kind: .plain))
                    }
                }
            }
        }
    }

    private func card(_ plugin: PluginHost.Plugin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.manifest.name).font(.system(size: 13, weight: .semibold))
                    Text("\(L("Плагин")) · \(plugin.manifest.version)\(plugin.manifest.author.map { " · " + $0 } ?? "")")
                        .font(.system(size: 11)).foregroundColor(Tokens.muted)
                }
                Spacer()
                if let problem = plugin.problem {
                    Text(problem).font(.system(size: 11)).foregroundColor(Tokens.danger)
                } else {
                    Toggle("", isOn: Binding(get: { host.isEnabled(plugin.id) }, set: { host.setEnabled(plugin.id, $0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            if let summary = plugin.manifest.summary { Text(summary).font(.system(size: 12)).foregroundColor(Tokens.muted) }
            PluginUpdateRow(plugin: plugin) // кнопка проверки видна всегда
            VStack(alignment: .leading, spacing: 2) {
                ForEach(plugin.manifest.permissions, id: \.self) { p in
                    Text("• " + PluginHost.title(p)).font(.system(size: 11)).foregroundColor(Tokens.muted)
                }
            }
            HStack {
                if host.installerURL != nil, plugin.manifest.components["chrome"] != nil {
                    Button("Установить в браузеры…") { host.openAutoPair(plugin.id); host.openInstaller() }.buttonStyle(NotesButtonStyle())
                } else if let chrome = host.component("chrome", of: plugin) {
                    Button("Для Chrome…") { host.openAutoPair(plugin.id); ChromeInstallGuide.show(folder: chrome) }.buttonStyle(NotesButtonStyle(kind: .plain))
                }
                if host.isActive(plugin.id) {
                    if host.isAutoPairOpen(plugin.id) {
                        Text("Браузер спросит разрешение на подключение").font(.system(size: 11)).foregroundColor(Tokens.muted)
                    } else {
                        Button("Подключить браузеры") { host.openAutoPair(plugin.id) }.buttonStyle(NotesButtonStyle(kind: .plain))
                    }
                }
                Spacer()
                Button("Удалить") { host.uninstall(plugin) }.buttonStyle(NotesButtonStyle(kind: .plain))
            }
            let clients = host.clients.filter { $0.plugin == plugin.id }
            if !clients.isEmpty {
                Text("Подключено").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                ForEach(clients) { client in
                    HStack {
                        Text(client.name).font(.system(size: 12))
                        Text(client.lastUsedAt.map { String(format: L("последний раз %@"), Self.date($0)) } ?? L("ещё не использовалось"))
                            .font(.system(size: 11)).foregroundColor(Tokens.muted)
                        Spacer()
                        Button("Отключить") { host.revoke(client) }.buttonStyle(NotesButtonStyle(kind: .plain))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.soft.opacity(0.5)))
    }

    private static func date(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

/// Chrome не ставит расширения из чужих программ: папку нужно загрузить вручную в режиме разработчика.
enum ChromeInstallGuide {
    @MainActor static func show(folder: URL) {
        let a = NSAlert()
        a.messageText = L("Расширение для Chrome")
        a.informativeText = L("1. Откройте в Chrome адрес chrome://extensions и включите «Режим разработчика».\n2. Нажмите «Загрузить распакованное» и выберите показанную папку.\n3. Закрепите значок MindNotes на панели и нажмите «Подключить».\n\nТак же ставится в Edge, Arc, Brave, Opera и Яндекс Браузер.")
        a.addButton(withTitle: L("Показать папку"))
        a.addButton(withTitle: L("Скопировать адрес"))
        a.addButton(withTitle: L("Закрыть"))
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([folder])
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("chrome://extensions", forType: .string)
        default: break
        }
    }
}

/// Обновления плагина в его карточке (ADR-0019, п. 9): кнопка проверки видна всегда, рядом — «Обновлять
/// автоматически» и время последней проверки; найденное обновление — с кнопкой или ставится само.
struct PluginUpdateRow: View {
    @ObservedObject var updater = PluginUpdater.shared
    let plugin: PluginHost.Plugin

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if plugin.manifest.updateSource == nil {
                Text("Плагин не сообщает, где искать его обновления: обновляйте его вручную.").font(.system(size: 11)).foregroundColor(Tokens.muted)
            } else {
                status
            }
            HStack(spacing: 10) {
                Button("Проверить обновления") { Task { await updater.check(silent: false) } }
                    .buttonStyle(NotesButtonStyle(kind: .plain))
                    .disabled(busy || plugin.manifest.updateSource == nil)
                Toggle("Обновлять автоматически", isOn: Binding(get: { updater.isAuto(plugin.id) }, set: { updater.setAuto(plugin.id, $0) }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
            }
        }
    }

    private var busy: Bool {
        switch updater.state(plugin.id) {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var lastChecked: String {
        guard let date = updater.lastCheck[plugin.id] else { return L("ещё не проверялось") }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return String(format: L("последняя проверка: %@"), f.string(from: date))
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch updater.state(plugin.id) {
            case .available(let release, let trusted):
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("Доступна версия %@"), release.version.description)).font(.system(size: 12, weight: .semibold))
                    if !trusted {
                        Text("Новой версии нужны новые разрешения — MindNotes покажет их перед установкой.")
                            .font(.system(size: 11)).foregroundColor(Tokens.muted)
                    }
                }
                Spacer()
                Button("Обновить") { updater.install(release, plugin: plugin.id) }.buttonStyle(NotesButtonStyle())
            case .needsApp(let release):
                Text(String(format: L("Версии %@ нужна MindNotes %@ или новее — сначала обновите приложение."),
                            release.version.description, release.minApp?.description ?? "?"))
                    .font(.system(size: 11)).foregroundColor(Tokens.muted)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Проверка обновлений…").font(.system(size: 11)).foregroundColor(Tokens.muted)
            case .downloading, .installing:
                ProgressView().controlSize(.small)
                Text("Загрузка и проверка обновления…").font(.system(size: 11)).foregroundColor(Tokens.muted)
            case .failed(let message):
                Text(message).font(.system(size: 11)).foregroundColor(Tokens.danger)
            case .upToDate:
                Text(L("Установлена последняя версия") + " · " + lastChecked).font(.system(size: 11)).foregroundColor(Tokens.muted)
            case .idle:
                Text(lastChecked.prefix(1).uppercased() + lastChecked.dropFirst()).font(.system(size: 11)).foregroundColor(Tokens.muted)
            }
        }
    }
}
