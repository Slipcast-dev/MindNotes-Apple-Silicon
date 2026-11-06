import AppKit
import CryptoKit
import SwiftUI

/// Checks GitHub for a newer release, downloads its disk image inside the app and replaces the installed copy.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The sheet over the main window; opened by the check at launch when a new version is out.
    @Published var sheetVisible = false
    private var task: Task<Void, Never>?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var archTag: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private var assetSuffix: String { "-\(archTag).dmg" }

    /// `silent`: the check at launch. It says nothing when there is nothing new or the network is down.
    func check(silent: Bool) async {
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        phase = .checking
        var request = URLRequest(url: UpdateCheck.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Grizzly/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            if let release = try UpdateCheck.parse(data, assetSuffix: assetSuffix, patchFrom: (currentVersion, archTag)),
               UpdateCheck.isNewer(release.version, than: currentVersion) {
                phase = .available(release)
                if silent { sheetVisible = true }
            } else {
                phase = .upToDate
            }
        } catch {
            phase = silent ? .idle : .failed(L("Не удалось проверить обновления. Проверьте подключение к интернету."))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func install(_ release: ReleaseInfo) {
        guard case .available = phase else { return }
        phase = .downloading(0)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var staged: URL?
                // A patch carries only what changed since the installed version. Whatever goes wrong with it
                // (not published, does not fit, damaged), the full disk image below is the way out.
                if let patch = release.patch, let expected = patch.sha256 {
                    do { staged = try await self.installFromPatch(patch, expected: expected, release: release) }
                    catch is CancellationError { throw CancellationError() }
                    catch { staged = nil; self.phase = .downloading(0) }
                }
                if staged == nil {
                    let dmg = try await self.download(release.assetURL, name: release.assetName, sha256: release.sha256)
                    self.phase = .installing
                    staged = try await Task.detached { try Self.stage(dmg: dmg, expected: release.version) }.value
                }
                try self.replaceAndRelaunch(with: staged!)
            } catch is CancellationError {
                self.phase = .idle
            } catch let error as UpdateError {
                self.phase = .failed(error.message)
            } catch {
                self.phase = .failed(L("Не удалось установить обновление.") + " (\(error.localizedDescription))")
            }
        }
    }

    /// Downloads the patch and builds the new application from the installed one.
    private func installFromPatch(_ patch: PatchAsset, expected: String, release: ReleaseInfo) async throws -> URL {
        let file = try await download(patch.url, name: patch.name, sha256: expected)
        phase = .installing
        let installed = Bundle.main.bundleURL
        let from = currentVersion, to = release.version
        let work = file.deletingLastPathComponent()
        return try await Task.detached { () -> URL in
            let staged = try AppPatch.apply(patch: file, to: installed, from: from, to: to, bundleID: "app.grizzly.Grizzly", work: work)
            let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == "app.grizzly.Grizzly",
                  UpdateCheck.normalized(info?["CFBundleShortVersionString"] as? String ?? "") == to else {
                throw PatchError(message: "version")
            }
            _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], timeout: 30)
            return staged
        }.value
    }

    // MARK: Download

    private struct UpdateError: Error { let message: String }

    private static let maxDownload: Int64 = 500 * 1024 * 1024

    /// Downloads a release file (disk image or patch). A dropped connection is retried and continues where it stopped
    /// (HTTP Range); the SHA-256 from the release notes is checked over the finished file.
    private func download(_ assetURL: URL, name: String, sha256 expectedHash: String?) async throws -> URL {
        // A release without a published SHA-256 is never installed.
        guard let expected = expectedHash else { throw UpdateError(message: L("Не удалось скачать обновление.")) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grizzly-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent((name as NSString).lastPathComponent)
        FileManager.default.createFile(atPath: file.path, contents: nil)

        var received: Int64 = 0
        var total: Int64 = 0
        var lastShown = 0.0
        var lastError: Error?
        var finished = false

        for attempt in 0..<5 where !finished {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            do {
                var request = URLRequest(url: assetURL, timeoutInterval: 30)
                request.setValue("Grizzly/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Redirects must still end on a trusted GitHub host.
                guard status == 200 || status == 206, let finalURL = response.url, UpdateCheck.isTrustedDownload(finalURL) else {
                    throw UpdateError(message: L("Не удалось скачать обновление."))
                }
                let out = try FileHandle(forWritingTo: file)
                defer { try? out.close() }
                if status == 206 {
                    try out.seekToEnd()
                } else {
                    // The server sent the whole file again.
                    try out.truncate(atOffset: 0)
                    received = 0
                }
                let length = max(response.expectedContentLength, 0)
                total = received + length
                if total > Self.maxDownload { throw UpdateError(message: L("Не удалось скачать обновление.")) }

                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 1 << 16 {
                        try out.write(contentsOf: chunk)
                        received += Int64(chunk.count)
                        chunk.removeAll(keepingCapacity: true)
                        try Task.checkCancellation()
                        if total > 0, Double(received) / Double(total) - lastShown > 0.01 {
                            lastShown = Double(received) / Double(total)
                            phase = .downloading(lastShown)
                        }
                    }
                }
                if !chunk.isEmpty { try out.write(contentsOf: chunk); received += Int64(chunk.count) }
                if length > 0 && received != total { throw URLError(.networkConnectionLost) }
                finished = true
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as UpdateError {
                throw error
            } catch {
                lastError = error
            }
        }
        guard finished else {
            try? FileManager.default.removeItem(at: dir)
            let why = lastError?.localizedDescription ?? ""
            throw UpdateError(message: L("Не удалось скачать обновление. Проверьте подключение к интернету.") + (why.isEmpty ? "" : " (\(why))"))
        }

        let actual = try Self.sha256(of: file)
        guard actual == expected else {
            try? FileManager.default.removeItem(at: dir)
            throw UpdateError(message: L("Контрольная сумма файла не совпала. Обновление не установлено."))
        }
        return file
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Install

    /// Opens the disk image, copies Grizzly.app out of it and checks that it is the app and version announced.
    nonisolated private static func stage(dmg: URL, expected: String) throws -> URL {
        let work = dmg.deletingLastPathComponent()
        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-mountpoint", mount.path, dmg.path]) else {
            throw UpdateError(message: L("Не удалось открыть образ диска с обновлением."))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let source = mount.appendingPathComponent("Grizzly.app")
        let staged = work.appendingPathComponent("Grizzly.app")
        guard FileManager.default.fileExists(atPath: source.path),
              run("/usr/bin/ditto", [source.path, staged.path]) else {
            throw UpdateError(message: L("В образе диска нет Grizzly.app."))
        }
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "app.grizzly.Grizzly",
              UpdateCheck.normalized(info?["CFBundleShortVersionString"] as? String ?? "") == expected else {
            throw UpdateError(message: L("Скачанное приложение не совпало с анонсированной версией."))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Runs a tool and waits for it, but never forever: a stuck helper must not leave the update on "Installing…".
    nonisolated fileprivate static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return false }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return false
        }
        return p.terminationStatus == 0
    }

    /// Quits Grizzly (asking about unsaved edits first); a helper script swaps the bundle once the app has exited and opens it again.
    private func replaceAndRelaunch(with staged: URL) throws {
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            // No write access to the Applications folder: hand over the new app to install by hand.
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            throw UpdateError(message: L("Нет прав на замену приложения. Новая версия показана в Finder: перетащите её в «Программы»."))
        }
        let state = AppState.shared
        guard state.confirmDiscard(state.documents.map(\.id)) else {
            phase = .idle
            return
        }
        // Remember tabs, mode and scroll position: the new copy puts them back when it starts.
        state.saveSessionForRestart()
        let script = """
        exec >>"${TMPDIR:-/tmp}/grizzly-update.log" 2>&1
        for i in $(seq 1 300); do kill -0 "$1" 2>/dev/null || break; sleep 0.2; done
        kill -0 "$1" 2>/dev/null && exit 1
        rm -rf "$3.update" "$3.old"
        ditto "$2" "$3.update" || exit 1
        mv "$3" "$3.old" || exit 1
        if mv "$3.update" "$3"; then rm -rf "$3.old"; else mv "$3.old" "$3"; fi
        open "$3"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), staged.path, destination.path]
        try helper.run()
        // The edits were just confirmed; quitting must not ask again.
        state.drafts.keys.forEach { state.discardDraft($0) }
        sheetVisible = false
        state.library.flush()
        NSApp.terminate(nil)
        // AppKit can decline to quit while a sheet or a panel is up (this is what left the update on "Installing…").
        // Everything is saved and confirmed by now, so leave anyway: the helper above is waiting for this process to end.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }
}

/// The update status with its buttons: used in Settings and in the sheet shown after the check at launch.
struct UpdateView: View {
    @ObservedObject var updater: UpdateManager
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch updater.phase {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Проверяем обновления…") }
            case .upToDate:
                Label("У вас установлена последняя версия.", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .available(let release):
                Label("Вышла новая версия \(release.version)", systemImage: "arrow.down.circle.fill")
                    .font(AppFont.headline)
                    .foregroundColor(theme.accent)
                Text("Установлена версия \(updater.currentVersion).").font(AppFont.callout).foregroundColor(.secondary)
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes).font(AppFont.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                HStack {
                    Button("Скачать и установить") { updater.install(release) }.buttonStyle(.hoverFilled)
                    Button("Позже") { updater.sheetVisible = false }.buttonStyle(.hoverText)
                }
            case .downloading(let progress):
                Text("Загрузка обновления… \(Int(progress * 100))%")
                ProgressView(value: progress)
                Button("Отмена") { updater.cancel() }.buttonStyle(.hoverText)
            case .installing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Устанавливаем… Grizzly перезапустится.") }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
        }
    }
}

/// Shown over the main window when the check at launch finds a newer version.
struct UpdateSheet: View {
    @ObservedObject var updater: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpdateView(updater: updater)
            HStack {
                Spacer()
                Button("Закрыть") { updater.sheetVisible = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
