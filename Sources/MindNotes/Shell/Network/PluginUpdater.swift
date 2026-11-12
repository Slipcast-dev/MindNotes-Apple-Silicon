import AppKit
import CryptoKit
import Foundation

/// Обновления плагинов (ADR-0019): выпуски `<префикс><версия>` в репозитории приложения на GitHub.
/// Как обновления приложения (ADR-0014): только с согласия, образ сверяется по SHA-256 из того же выпуска,
/// затем запускается новый установщик плагина — он обновит плагин в MindNotes (с вопросом) и расширения в браузерах.
@MainActor
final class PluginUpdater: ObservableObject {
    static let shared = PluginUpdater()
    static let releasesURL = URL(string: "https://api.github.com/repos/Slipcast-dev/MindNotes-Apple-Silicon/releases?per_page=50")!
    private static let lastCheckKey = "pluginUpdateLastCheck"

    enum State: Equatable {
        case idle, checking, upToDate
        case available(PluginRelease)
        /// Новый выпуск есть, но ему нужна более новая MindNotes.
        case needsApp(PluginRelease)
        case downloading, installing
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    private var timer: Timer?

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

    /// Запуск: в автоматическом режиме обновлений — проверка раз в сутки, как у приложения.
    func start(mode: UpdateMode) {
        timer?.invalidate()
        guard canCheck, mode == .automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: UpdateMode.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(silent: true) }
        }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if Date().timeIntervalSince1970 - last > UpdateMode.checkInterval { Task { await check(silent: true) } }
    }

    /// Один запрос списка выпусков на все плагины, у которых указан источник обновлений.
    func check(silent: Bool) async {
        let plugins = PluginHost.shared.plugins.filter { $0.manifest.updates != nil }
        guard !plugins.isEmpty else { return }
        guard canCheck else {
            if !silent { for p in plugins { states[p.id] = .failed(L("Обновления доступны только в установленном приложении MindNotes.")) } }
            return
        }
        for p in plugins where !isBusy(p.id) { states[p.id] = .checking }
        do {
            let (data, response) = try await Self.session.data(from: Self.releasesURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            for p in plugins where !isBusy(p.id) {
                guard let prefix = p.manifest.updates, let release = PluginRelease.newest(in: data, prefix: prefix),
                      let installed = AppVersion(p.manifest.version), installed < release.version else {
                    states[p.id] = .upToDate
                    continue
                }
                if let need = release.minApp, let app = appVersion, app < need { states[p.id] = .needsApp(release) }
                else { states[p.id] = .available(release) }
            }
        } catch {
            for p in plugins where !isBusy(p.id) { states[p.id] = silent ? .idle : .failed(L("Не удалось проверить обновления: нет связи с GitHub.")) }
        }
    }

    private func isBusy(_ id: String) -> Bool {
        switch state(id) {
        case .downloading, .installing: return true
        default: return false
        }
    }

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    /// Скачать образ, сверить сумму, положить установщик на место прежнего и запустить его.
    func install(_ release: PluginRelease, plugin id: String) {
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
                let target = PluginHost.shared.installerURL
                let installer = try await Task.detached { try Self.stage(image: image, replacing: target) }.value
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try await NSWorkspace.shared.openApplication(at: installer, configuration: config)
                states[id] = .upToDate
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

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Образ монтируется только для чтения; программа из него заменяет прежний установщик
    /// (прежний — в корзину) или ложится в ~/Applications, если установщика ещё не было.
    nonisolated private static func stage(image: URL, replacing current: URL?) throws -> URL {
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
        let staged = folder.appendingPathComponent(".\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
        try fm.moveItem(at: staged, to: target)
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
        return target
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError(L("Не удалось подготовить обновление (\((tool as NSString).lastPathComponent)).")) }
        return p.terminationStatus
    }
}
