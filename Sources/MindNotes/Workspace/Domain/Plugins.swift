import Foundation

/// Плагины (ADR-0019): код плагина работает вне приложения (браузер, отдельная программа) и обращается к пространству
/// только через локальный API в пределах разрешений, подтверждённых при установке.
enum PluginPermission: String, CaseIterable, Equatable, Codable {
    case pagesList = "pages.list"
    case pagesCreate = "pages.create"
    case pagesOpen = "pages.open"
    case assetsCreate = "assets.create"
    case tagsWrite = "tags.write"
    /// Чтение текста страниц в Markdown и их вложений (кроме закрытых паролем): синхронизация, резервные копии.
    case pagesRead = "pages.read"
    /// Перенос правок в текстовые блоки страниц (кроме закрытых паролем); перед записью — версия в истории.
    case pagesWrite = "pages.write"
}

struct PluginManifest: Equatable {
    /// Версия локального API, которую понимает это приложение. Растёт только при несовместимых изменениях.
    static let apiVersion = 1
    static let packageExtension = "mnplugin"

    var id: String
    var name: String
    var version: String
    var api: Int
    var summary: String?
    var author: String?
    var permissions: [PluginPermission]
    /// Разрешения более новых версий: плагин с ними не включается.
    var unknownPermissions: [String]
    /// Компоненты, которые ставятся вне приложения: имя → путь внутри пакета.
    var components: [String: String]
    var minApp: AppVersion?
    /// Префикс тегов выпусков плагина (`webclipper-v`): по нему ищутся обновления.
    var updates: String?
    /// Репозиторий выпусков плагина на GitHub (`владелец/имя`), если он живёт отдельно от приложения (ADR-0019, п. 10).
    /// Нет поля — выпуски ищутся в репозитории приложения.
    var repository: String?

    static func == (a: PluginManifest, b: PluginManifest) -> Bool {
        a.id == b.id && a.version == b.version && a.permissions == b.permissions && a.components == b.components
    }

    enum Problem: Error, Equatable {
        case unreadable
        case notPlugin
        case newerAPI(Int)
        case unknownPermissions([String])
        case badComponent(String)
        case newerApp(String)
    }

    /// Описание плагина из manifest.json. Общие поля (id, name) проверяет `ExtensionManifest.parse`.
    static func parse(_ data: Data) -> Result<PluginManifest, Problem> {
        guard let base = ExtensionManifest.parse(data), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        guard case .plugin = base.kind else { return .failure(.notPlugin) }
        let api = (o["api"] as? Int) ?? 1
        var known: [PluginPermission] = [], unknown: [String] = []
        for raw in (o["permissions"] as? [String]) ?? [] {
            if let p = PluginPermission(rawValue: raw) { if !known.contains(p) { known.append(p) } } else { unknown.append(raw) }
        }
        var components: [String: String] = [:]
        for (key, value) in (o["components"] as? [String: Any]) ?? [:] {
            guard let path = value as? String, isSafeRelativePath(path),
                  key.count <= 40, key.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else { return .failure(.badComponent(key)) }
            components[key] = path
        }
        var updates: String?
        if let prefix = o["updates"] as? String {
            guard isSafeTagPrefix(prefix) else { return .failure(.badComponent("updates")) }
            updates = prefix
        }
        var repository: String?
        if let repo = o["repository"] as? String {
            guard isValidRepository(repo) else { return .failure(.badComponent("repository")) }
            repository = repo
        }
        let manifest = PluginManifest(id: base.id, name: base.name, version: base.version, api: api,
                                      summary: (o["description"] as? String).map { String($0.prefix(300)) },
                                      author: (o["author"] as? String).map { String($0.prefix(80)) },
                                      permissions: known, unknownPermissions: unknown, components: components, minApp: base.minApp,
                                      updates: updates, repository: repository)
        return .success(manifest)
    }

    /// Причина, по которой плагин нельзя включить в этой версии приложения; nil — можно.
    func problem(app: AppVersion?) -> Problem? {
        if api > Self.apiVersion { return .newerAPI(api) }
        if !unknownPermissions.isEmpty { return .unknownPermissions(unknownPermissions) }
        if let minApp, let app, app < minApp { return .newerApp(minApp.description) }
        return nil
    }

    /// Где искать обновления: поле `updates`, а если его нет — префикс по правилу `<последняя часть id>-v`
    /// (`minerva.webclipper` → `webclipper-v`). Так плагин из ранней сборки без поля тоже находит свои выпуски.
    var updateSource: String? {
        if let updates { return updates }
        guard let last = id.split(separator: ".").last else { return nil }
        let prefix = last.lowercased() + "-v"
        return Self.isSafeTagPrefix(prefix) ? prefix : nil
    }

    /// Обновление без вопроса пользователю (ADR-0019, п. 9): тот же плагин, версия новее, понятен этой MindNotes
    /// и просит не больше разрешений, чем уже подтверждено. Новые разрешения — только с согласия.
    func isTrustedUpdate(of installed: PluginManifest, app: AppVersion?) -> Bool {
        guard id == installed.id, problem(app: app) == nil,
              let new = AppVersion(version), let old = AppVersion(installed.version), old < new else { return false }
        return Set(permissions).isSubset(of: Set(installed.permissions))
    }

    /// Выпуск плагина содержит нативную программу-установщик, а её разрешения API не ограничивают: это обычная
    /// программа с правами пользователя. Без вопроса её можно ставить и запускать только от того же издателя,
    /// что и само приложение: выпуски в репозиториях владельца `trustedOwner` (репозиторий приложения или, как
    /// у Web Clipper, отдельный репозиторий того же владельца). Остальные — после отдельного явного согласия.
    func nativeUpdateNeedsConsent(trustedOwner: String) -> Bool {
        guard let repository else { return false }
        let owner = repository.split(separator: "/").first.map(String.init) ?? ""
        return owner.lowercased() != trustedOwner.lowercased()  // имена владельцев GitHub не различают регистр
    }

    /// Обновление, которое ставится само, без вопроса: доверенное по разрешениям и от издателя приложения —
    /// и у установленной версии, и у новой.
    func isAutomaticUpdate(of installed: PluginManifest, app: AppVersion?, trustedOwner: String) -> Bool {
        !installed.nativeUpdateNeedsConsent(trustedOwner: trustedOwner) && !nativeUpdateNeedsConsent(trustedOwner: trustedOwner)
            && isTrustedUpdate(of: installed, app: app)
    }

    /// Репозиторий выпусков: `владелец/имя` по правилам GitHub — владелец до 39 символов (латиница, цифры, дефис,
    /// не с дефиса), имя до 100 (ещё `.` и `_`, не `.`/`..`). Ни схем, ни хостов, ни путей: адрес строит само
    /// приложение и только на api.github.com.
    static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let owner = parts[0], name = parts[1]
        let ownerOK = (1...39).contains(owner.count) && owner.first != "-"
            && owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let nameOK = (1...100).contains(name.count) && name != "." && name != ".."
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
        return ownerOK && nameOK
    }

    /// Плагины, переехавшие в свои репозитории (договор `contracts/plugin-api.json`). Нужно для копий, установленных
    /// до переезда: в их описании ещё нет `repository`, а выпуски уже ищутся там.
    static let knownRepositories = ["minerva.webclipper": "Slipcast-dev/MindNotes-WebClipper"]

    /// Откуда брать выпуски: поле `repository`, известный репозиторий плагина или репозиторий приложения (`fallback`).
    func releaseRepository(fallback: String) -> String {
        repository ?? Self.knownRepositories[id] ?? fallback
    }

    /// Список выпусков плагина (см. `releaseRepository`).
    func releasesURL(fallback: String) -> URL? {
        let repo = releaseRepository(fallback: fallback)
        guard Self.isValidRepository(repo) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=50")
    }

    /// Префикс тега: строчные латинские буквы, цифры и дефис, оканчивается на `-v` — не совпадёт с тегами приложения `v1.2.3`.
    static func isSafeTagPrefix(_ prefix: String) -> Bool {
        (3...40).contains(prefix.count) && prefix.hasSuffix("-v")
            && prefix.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    /// Путь внутри пакета: без абсолютного начала, `..` и пустых частей.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 300, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
}

/// Привязанный клиент плагина (браузер, программа). Токен не хранится: только его SHA-256.
struct PluginClient: Codable, Equatable, Identifiable {
    var id: UUID
    var plugin: String
    var name: String
    var tokenHash: String
    var createdAt: Int64
    var lastUsedAt: Int64?
    /// Источник запроса привязки (`chrome-extension://…`): одно расширение — одно подключение.
    var origin: String?

    /// Одно подключение на экземпляр расширения: новый ключ того же плагина и источника заменяет прежний.
    /// Расширение при установке подключается из нескольких мест сразу, и без этого список рос дублями.
    static func adding(_ client: PluginClient, to list: [PluginClient]) -> [PluginClient] {
        guard let origin = client.origin else { return list + [client] }
        return list.filter { !($0.plugin == client.plugin && $0.origin == origin) } + [client]
    }

    /// Уборка старых дублей: из записей одного плагина и источника (без источника — одного имени)
    /// остаётся последняя использованная — её ключ и хранит расширение.
    static func deduplicated(_ list: [PluginClient]) -> [PluginClient] {
        func key(_ c: PluginClient) -> String { c.plugin + "\u{1}" + (c.origin ?? "name:" + c.name) }
        func recency(_ c: PluginClient) -> Int64 { max(c.lastUsedAt ?? 0, c.createdAt) }
        var best: [String: PluginClient] = [:]
        for c in list where best[key(c)].map({ recency(c) >= recency($0) }) ?? true { best[key(c)] = c }
        return list.filter { best[key($0)]?.id == $0.id }
    }
}

/// Выпуск плагина на GitHub (ADR-0019): тег `<префикс><версия>`, образ установщика `.dmg` и `SHA256SUMS.txt`.
struct PluginRelease: Equatable {
    var version: AppVersion
    var tag: String
    var notes: String
    var image: URL
    var checksums: URL
    /// `plugin-manifest.json` выпуска: по нему MindNotes сравнивает разрешения до скачивания образа.
    var manifest: URL?
    /// Самая старая MindNotes, с которой работает выпуск: строка `<!-- minApp: X -->` в описании.
    var minApp: AppVersion?

    static func == (a: PluginRelease, b: PluginRelease) -> Bool { a.tag == b.tag && a.image == b.image }

    /// Самый новый годный выпуск плагина из списка `GET /repos/…/releases`. Черновики, предварительные выпуски,
    /// чужие теги и выпуски без образа или сумм пропускаются; ссылки — только https на github.com.
    static func newest(in data: Data, prefix: String) -> PluginRelease? {
        guard PluginManifest.isSafeTagPrefix(prefix), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: PluginRelease?
        for object in list {
            guard let tag = object["tag_name"] as? String, tag.hasPrefix(prefix),
                  let version = AppVersion(String(tag.dropFirst(prefix.count))),
                  object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
                  let assets = object["assets"] as? [[String: Any]] else { continue }
            func asset(_ match: (String) -> Bool) -> URL? {
                for a in assets {
                    guard let name = a["name"] as? String, match(name), let raw = a["browser_download_url"] as? String,
                          let url = URL(string: raw), url.scheme == "https", url.host?.hasSuffix("github.com") == true else { continue }
                    return url
                }
                return nil
            }
            guard let image = asset({ $0.hasSuffix(".dmg") }), let sums = asset({ $0 == "SHA256SUMS.txt" }) else { continue }
            let body = (object["body"] as? String) ?? ""
            let release = PluginRelease(version: version, tag: tag, notes: String(body.prefix(4000)), image: image, checksums: sums,
                                        manifest: asset({ $0 == "plugin-manifest.json" }), minApp: minApp(in: body))
            if best.map({ $0.version < version }) ?? true { best = release }
        }
        return best
    }

    static func minApp(in body: String) -> AppVersion? {
        guard let start = body.range(of: "<!-- minApp:"), let end = body.range(of: "-->", range: start.upperBound..<body.endIndex) else { return nil }
        return AppVersion(body[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces))
    }
}

/// Куда можно положить программу-установщик из образа выпуска. Заменяется только та же программа
/// (тот же bundle ID): обновление одного плагина не может подменить установщик другого или чужое приложение.
enum PluginInstallerPolicy {
    /// - Parameters:
    ///   - existing: bundle ID того, что уже лежит на месте установки; nil — места никто не занимает,
    ///     пустая строка — там что-то без bundle ID.
    ///   - new: bundle ID программы из образа.
    ///   - expected: какой bundle ID обязан быть у программы (установщик Web Clipper); nil — любой.
    static func mayReplace(existing: String?, new: String?, expected: String?) -> Bool {
        guard let new, !new.isEmpty else { return false }
        if let expected, new != expected { return false }
        if let existing { return existing == new }
        return true
    }
}
