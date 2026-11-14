import AppKit
import CryptoKit
import Foundation

/// Обновления плагинов (ADR-0019, пп. 7 и 9): выпуски `<префикс><версия>` в репозитории приложения на GitHub.
/// Своё расписание, независимое от обновлений приложения: при запуске и раз в сутки. Образ сверяется по SHA-256
/// из того же выпуска. Если новая версия просит не больше разрешений, чем подтверждено, и у плагина включено
/// «Обновлять автоматически», обновление ставится само; новые разрешения — только по кнопке и с вопросом.
@MainActor
final class PluginUpdater: ObservableObject {
    static let shared = PluginUpdater()
    /// Репозиторий приложения: здесь ищутся выпуски плагинов без своего поля `repository`.
    static let appRepository = "Slipcast-dev/MindNotes-Apple-Silicon"
    /// Издатель приложения: его репозиториям нативные программы плагинов доверяются без отдельного вопроса.
    static var trustedOwner: String { appRepository.split(separator: "/").first.map(String.init) ?? "" }
    static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "pluginUpdateChecks", autoKey = "pluginAutoUpdate"

    enum State: Equatable {
        case idle, checking, upToDate
        /// `trusted` — те же или меньше разрешений: можно ставить без вопроса.
        case available(PluginRelease, trusted: Bool)
        /// Новый выпуск есть, но ему нужна более новая MindNotes.
        case needsApp(PluginRelease)
        case downloading, installing
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var lastCheck: [String: Date] = [:]
    @Published private(set) var auto: [String: Bool] = [:]
    private var timer: Timer?

    private init() {
        let saved = (UserDefaults.standard.dictionary(forKey: Self.lastCheckKey) as? [String: Double]) ?? [:]
        lastCheck = saved.mapValues { Date(timeIntervalSince1970: $0) }
        auto = (UserDefaults.standard.dictionary(forKey: Self.autoKey) as? [String: Bool]) ?? [:]
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        config.httpAdditionalHeaders = ["User-Agent": "MindNotes plugin updater"]
        return URLSession(configuration: config)
    }()

    /// Проверять можно только в настоящей сборке, как и обновления приложения.
    private var canCheck: Bool {
        AppDataScope.isOfficial(bundleID: Bundle.main.bundleIdentifier, officialID: AppEdition.bundleID) && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var appVersion: AppVersion? {
        AppVersion((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")
    }

    func state(_ id: String) -> State { states[id] ?? .idle }

    /// «Обновлять автоматически» — у каждого плагина своё; по умолчанию включено.
    func isAuto(_ id: String) -> Bool { auto[id] ?? true }

    func setAuto(_ id: String, _ on: Bool) {
        auto[id] = on
        UserDefaults.standard.set(auto, forKey: Self.autoKey)
        if on, case .available(let release, true) = state(id), PluginHost.shared.plugin(id)?.manifest.nativeUpdateNeedsConsent(trustedOwner: Self.trustedOwner) == false {
            install(release, plugin: id)
        }
    }

    /// Расписание плагинов не зависит от режима обновлений приложения: проверка при запуске и раз в сутки.
    func start() {
        timer?.invalidate()
        guard canCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        Task { await checkIfDue() }
    }

    private func checkIfDue() async {
        let ids = PluginHost.shared.plugins.filter { $0.manifest.updateSource != nil }.map(\.id)
        let oldest = ids.map { lastCheck[$0] ?? .distantPast }.min() ?? .distantFuture
        if Date().timeIntervalSince(oldest) >= Self.interval { await check(silent: true) }
    }

    /// Один запрос списка выпусков на каждый репозиторий: плагины без поля `repository` — из репозитория приложения,
    /// остальные — из своего (ADR-0019, п. 10). Ошибка одного репозитория не мешает остальным.
    func check(silent: Bool) async {
        let plugins = PluginHost.shared.plugins.filter { $0.manifest.updateSource != nil }
        guard !plugins.isEmpty else { return }
        guard canCheck else {
            if !silent { for p in plugins { states[p.id] = .failed(L("Обновления доступны только в установленном приложении MindNotes.")) } }
            return
        }
        for p in plugins where !isBusy(p.id) { states[p.id] = .checking }
        var lists: [URL: Data?] = [:]
        for p in plugins where !isBusy(p.id) {
            guard let url = p.manifest.releasesURL(fallback: Self.appRepository) else { states[p.id] = .idle; continue }
            if lists[url] == nil {
                do {
                    let (body, response) = try await Self.session.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    lists[url] = .some(body)
                } catch {
                    lists[url] = .some(nil)
                }
            }
            guard let data = lists[url] ?? nil else {
                states[p.id] = silent ? .idle : .failed(L("Не удалось проверить обновления: нет связи с GitHub."))
                continue
            }
            lastCheck[p.id] = Date()
            guard let prefix = p.manifest.updateSource, let release = PluginRelease.newest(in: data, prefix: prefix),
                  let installed = AppVersion(p.manifest.version), installed < release.version else {
                states[p.id] = .upToDate
                continue
            }
            if let need = release.minApp, let app = appVersion, app < need { states[p.id] = .needsApp(release); continue }
            let trusted = await isTrusted(release, installed: p.manifest)
            states[p.id] = .available(release, trusted: trusted)
            // Само ставится только обновление от издателя приложения: выпуск стороннего издателя запускает
            // чужую нативную программу и требует согласия (кнопка в карточке плагина).
            if trusted, isAuto(p.id), !p.manifest.nativeUpdateNeedsConsent(trustedOwner: Self.trustedOwner) { install(release, plugin: p.id) }
        }
        UserDefaults.standard.set(lastCheck.mapValues(\.timeIntervalSince1970), forKey: Self.lastCheckKey)
    }

    /// Разрешения новой версии — из `plugin-manifest.json` выпуска, сверенного по SHA256SUMS. Нет файла или
    /// сумма не сошлась — обновление не считается доверенным и ставится только с вопросом.
    private func isTrusted(_ release: PluginRelease, installed: PluginManifest) async -> Bool {
        guard let url = release.manifest,
              let manifestFile = try? await fetch(url, limit: 64 << 10) else { return false }
        defer { try? FileManager.default.removeItem(at: manifestFile) }
        guard let sumsFile = try? await fetch(release.checksums, limit: 1 << 20) else { return false }
        defer { try? FileManager.default.removeItem(at: sumsFile) }
        guard let data = try? Data(contentsOf: manifestFile), let sums = try? Data(contentsOf: sumsFile),
              ReleaseInfo.checksums(String(decoding: sums, as: UTF8.self))["plugin-manifest.json"] == Self.hex(SHA256.hash(data: data)),
              case .success(let manifest) = PluginManifest.parse(data) else { return false }
        return manifest.isTrustedUpdate(of: installed, app: appVersion)
    }

    private func isBusy(_ id: String) -> Bool {
        switch state(id) {
        case .downloading, .installing: return true
        default: return false
        }
    }

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    /// Скачать образ, сверить сумму, заменить установщик, обновить плагин в MindNotes (без вопроса — только для
    /// доверенного обновления) и дать установщику обновить расширения в браузерах (`--update`, без окна).
    func install(_ release: PluginRelease, plugin id: String) {
        guard !isBusy(id) else { return }
        Task {
            do {
                states[id] = .downloading
                let image = try await fetch(release.image, limit: 512 << 20)
                defer { try? FileManager.default.removeItem(at: image) }
                let sumsFile = try await fetch(release.checksums, limit: 1 << 20)
                defer { try? FileManager.default.removeItem(at: sumsFile) }
                guard let expected = ReleaseInfo.checksums(String(decoding: try Data(contentsOf: sumsFile), as: UTF8.self))[release.image.lastPathComponent] else {
                    throw UpdateError(L("В выпуске нет контрольной суммы образа."))
                }
                states[id] = .installing
                let actual = try await Task.detached { try Self.sha256(of: image) }.value
                guard actual == expected else { throw UpdateError(L("Образ повреждён: контрольная сумма не совпала. Установка отменена.")) }
                // Сторонний издатель: программа из образа будет запущена с правами пользователя — только с согласия,
                // до замены и запуска. Установщик Web Clipper такой выпуск не заменяет.
                let thirdParty = PluginHost.shared.plugin(id)?.manifest.nativeUpdateNeedsConsent(trustedOwner: Self.trustedOwner) ?? true
                if thirdParty {
                    let repo = PluginHost.shared.plugin(id)?.manifest.repository ?? "?"
                    guard Self.confirmNative(plugin: PluginHost.shared.plugin(id)?.manifest.name ?? id, repository: repo) else {
                        states[id] = .available(release, trusted: false)
                        return
                    }
                }
                // Программа плагина ищется по её bundle ID из описания (ADR-0019, п. 14), не только у Web Clipper.
                let manifest = PluginHost.shared.plugin(id)?.manifest
                let installerID = manifest.flatMap { PluginHost.shared.installerID(for: $0) }
                let target = thirdParty ? nil : manifest.flatMap { PluginHost.shared.installerURL(for: $0) }
                let expectedID = thirdParty ? nil : installerID
                let installer = try await Task.detached { try Self.stage(image: image, replacing: target, expectedBundleID: expectedID) }.value
                guard let package = try FileManager.default.contentsOfDirectory(at: installer.appendingPathComponent("Contents/Resources"), includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == PluginManifest.packageExtension }) else { throw UpdateError(L("В образе нет программы-установщика.")) }
                // Доверенное — без вопроса; иначе MindNotes покажет новые разрешения и спросит.
                guard PluginHost.shared.installUpdate(from: package) else {
                    states[id] = .available(release, trusted: false)
                    return
                }
                if let tool = Bundle(url: installer)?.executableURL?.path {
                    try await Task.detached { try Self.run(tool, ["--update"], timeout: 60) }.value
                }
                states[id] = .upToDate
                lastCheck[id] = Date()
                PluginHost.shared.shell?.notice = String(format: L("Плагин обновлён до версии %@."), release.version.description)
            } catch {
                states[id] = .failed((error as? UpdateError)?.message ?? L("Обновление не установилось: ") + error.localizedDescription)
            }
        }
    }

    private func fetch(_ url: URL, limit: Int64) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("MindNotes-plugin-\(UUID().uuidString)-\(url.lastPathComponent)")
        let (temp, response) = try await Self.session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let size = (try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= limit else { throw UpdateError(L("Образ слишком большой.")) }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    nonisolated private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    /// Образ монтируется только для чтения; программа из него заменяет прежний установщик
    /// (прежний — в корзину) или ложится в ~/Applications, если установщика ещё не было.
    /// Вопрос перед установкой и запуском программы из выпуска стороннего репозитория.
    private static func confirmNative(plugin name: String, repository: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.messageText = String(format: L("Запустить программу обновления плагина «%@»?"), name)
        ask.informativeText = String(format: L("Обновление скачано из репозитория %@, а не от издателя MindNotes. В нём программа-установщик: она будет запущена с вашими правами, и разрешения плагина её не ограничивают. Продолжайте, только если доверяете издателю."), repository)
        ask.alertStyle = .warning
        ask.addButton(withTitle: L("Установить и запустить"))
        ask.addButton(withTitle: L("Отмена"))
        return ask.runModal() == .alertFirstButtonReturn
    }

    /// `expectedBundleID` — какой bundle ID обязан быть у программы; на месте установки заменяется только
    /// та же программа (`PluginInstallerPolicy`), иначе установка отменяется до любых изменений.
    nonisolated private static func stage(image: URL, replacing current: URL?, expectedBundleID: String?) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("MindNotes-plugin-mount-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let apps = (try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw UpdateError(L("В образе нет программы-установщика.")) }
        let folder = current?.deletingLastPathComponent() ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: folder.path) else {
            throw UpdateError(L("Нет прав на запись в папку программы. Скачайте образ со страницы выпуска и установите вручную."))
        }
        let target = current ?? folder.appendingPathComponent(app.lastPathComponent)
        let existing = fm.fileExists(atPath: target.path) ? (Bundle(url: target)?.bundleIdentifier ?? "") : nil
        guard PluginInstallerPolicy.mayReplace(existing: existing, new: Bundle(url: app)?.bundleIdentifier, expected: expectedBundleID) else {
            throw UpdateError(L("Программа в образе не совпадает с установленной. Обновление отменено."))
        }
        let staged = folder.appendingPathComponent(".\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
        try fm.moveItem(at: staged, to: target)
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
        return target
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 120) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); throw UpdateError(L("Не удалось подготовить обновление (\((tool as NSString).lastPathComponent)).")) }
        guard p.terminationStatus == 0 else { throw UpdateError(L("Не удалось подготовить обновление (\((tool as NSString).lastPathComponent)).")) }
        return p.terminationStatus
    }
}
