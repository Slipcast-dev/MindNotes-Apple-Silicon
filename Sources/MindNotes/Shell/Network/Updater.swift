import AppKit
import CryptoKit
import SwiftUI

/// Обновления (ADR-0014): проверка выпусков на GitHub, загрузка образа, сверка SHA-256, замена приложения и перезапуск.
/// Ничего не скачивается без согласия пользователя; проверочная копия с другим идентификатором обновлений не ищет.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let latestURL = URL(string: "https://api.github.com/repos/Slipcast-dev/MindNotes-Apple-Silicon/releases/latest")!
    private static let modeKey = "updateMode", lastCheckKey = "updateLastCheck"

    @Published private(set) var state: State = .idle
    @Published var showsSheet = false
    @Published var mode: UpdateMode = UpdateMode(rawValue: UserDefaults.standard.string(forKey: Updater.modeKey) ?? "") ?? .automatic {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .automatic { scheduleBackground() } else { timer?.invalidate() }
        }
    }
    private var timer: Timer?

    var currentVersion: AppVersion? {
        AppVersion((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")
    }

    /// Обновлять можно только настоящую сборку: копия для проверок и бинарник вне пакета не трогаются.
    private var canUpdate: Bool {
        AppDataScope.isOfficial(bundleID: Bundle.main.bundleIdentifier, officialID: AppEdition.bundleID) && Bundle.main.bundleURL.pathExtension == "app"
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "MindNotes updater", "Accept": "application/vnd.github+json"]
        return URLSession(configuration: config)
    }()

    /// Запуск: в автоматическом режиме проверка сейчас (если не было сегодня) и раз в сутки.
    func start() {
        guard canUpdate, mode == .automatic else { return }
        scheduleBackground()
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if Date().timeIntervalSince1970 - last > UpdateMode.checkInterval { Task { await check(silent: true) } }
    }

    private func scheduleBackground() {
        timer?.invalidate()
        guard canUpdate else { return }
        timer = Timer.scheduledTimer(withTimeInterval: UpdateMode.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(silent: true) }
        }
    }

    /// `silent` — фоновая проверка: окно показывается, только если есть новая версия.
    func check(silent: Bool) async {
        guard canUpdate else {
            if !silent { state = .failed(L("Обновления доступны только в установленном приложении MindNotes.")); showsSheet = true }
            return
        }
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        if !silent { showsSheet = true }
        do {
            let (data, response) = try await Self.session.data(from: Self.latestURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let release = ReleaseInfo.parse(data) else { throw URLError(.badServerResponse) }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            if let current = currentVersion, current < release.version {
                state = .available(release)
                showsSheet = true
            } else {
                state = .upToDate
            }
        } catch {
            state = silent ? .idle : .failed(L("Не удалось проверить обновления: нет связи с GitHub."))
        }
    }

    func later() {
        showsSheet = false
        if case .available = state { return }
        state = .idle
    }

    /// «Скачать и установить»: образ, сверка суммы, копия рядом со старой программой, затем перезапуск.
    func install(_ release: ReleaseInfo) {
        Task {
            do {
                state = .downloading(0)
                let image = try await download(release.image)
                let sums = try await Self.session.data(from: release.checksums).0
                guard let expected = ReleaseInfo.checksums(String(decoding: sums, as: UTF8.self))[release.image.lastPathComponent] else {
                    throw UpdateError(L("В выпуске нет контрольной суммы образа."))
                }
                state = .installing
                let actual = try await Task.detached { try Self.sha256(of: image) }.value
                guard actual == expected else { throw UpdateError(L("Образ повреждён: контрольная сумма не совпала. Установка отменена.")) }
                let staged = try await Task.detached { try Self.stage(image: image) }.value
                try Self.relaunch(replacing: Bundle.main.bundleURL, with: staged)
                NSApp.terminate(nil) // Пространство записывается обычным выходом, затем сценарий заменяет программу.
            } catch {
                state = .failed((error as? UpdateError)?.message ?? L("Обновление не установилось: ") + error.localizedDescription)
            }
        }
    }

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    private func download(_ url: URL) async throws -> URL {
        let (bytes, response) = try await Self.session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let total = max(1, http.expectedContentLength)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MindNotes-update-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                state = .downloading(min(1, Double(received) / Double(total)))
            }
            if received > 2 << 30 { throw UpdateError(L("Образ слишком большой.")) }
        }
        try handle.write(contentsOf: buffer)
        state = .downloading(1)
        return file
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Образ монтируется только для чтения, программа копируется рядом с установленной; образ отключается.
    nonisolated private static func stage(image: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("MindNotes-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = mount.appendingPathComponent("MindNotes.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError(L("В образе нет MindNotes.app.")) }
        let target = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: target.path) else {
            throw UpdateError(L("Нет прав на запись в папку программы. Скачайте образ со страницы выпуска и установите вручную."))
        }
        let staged = target.appendingPathComponent(".MindNotes-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
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

    /// Сценарий ждёт выхода приложения, заменяет пакет и запускает новую версию.
    private static func relaunch(replacing current: URL, with staged: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf \(q(current.path)) && mv \(q(staged.path)) \(q(current.path))
        xattr -dr com.apple.quarantine \(q(current.path)) 2>/dev/null
        open \(q(current.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

/// Окно обновления в стиле приложения.
struct UpdateSheet: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandLogo()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(String(format: L("Установлена версия %@"), updater.currentVersion?.description ?? "—"))
                        .font(.system(size: 12)).foregroundColor(Tokens.muted)
                }
            }
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Tokens.paper)
    }

    private var title: String {
        switch updater.state {
        case .available(let r): return String(format: L("Доступна версия %@"), r.version.description)
        case .downloading, .installing: return L("Идёт обновление…")
        case .checking: return L("Проверка обновлений…")
        case .upToDate: return L("Установлена последняя версия")
        case .failed: return L("Обновление не удалось")
        case .idle: return L("Обновления")
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .available(let r):
            ScrollView {
                Text(r.notes.isEmpty ? L("Описание выпуска на странице GitHub.") : r.notes)
                    .font(.system(size: 12)).foregroundColor(Tokens.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tokens.line))
            Text("Перед установкой пространство записывается и делается снимок; приложение перезапустится само.")
                .font(.system(size: 12)).foregroundColor(Tokens.muted)
        case .downloading(let p):
            ProgressView(value: p) { Text("Загрузка обновления").font(.system(size: 12)) }.tint(Tokens.accent)
        case .installing:
            ProgressView { Text("Проверка и установка. Не выключайте Mac.").font(.system(size: 12)) }.tint(Tokens.accent)
        case .checking:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Text(message).font(.system(size: 13)).foregroundColor(Tokens.danger)
        case .upToDate, .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.state {
        case .available(let r):
            Button("Позже") { updater.later() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Скачать и установить") { updater.install(r) }.buttonStyle(NotesButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        case .downloading, .installing:
            EmptyView()
        default:
            Button("Закрыть") { updater.later() }.buttonStyle(NotesButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        }
    }
}
