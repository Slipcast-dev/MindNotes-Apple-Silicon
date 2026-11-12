import AppKit
import Foundation

/// Установка Web Clipper по шагам: плагин в MindNotes, затем каждый найденный браузер.
/// Подключение браузера к MindNotes настраивается само: после установки плагина MindNotes 10 минут
/// принимает расширение без вопроса (ADR-0019), а расширение раз в минуту пробует подключиться.
@MainActor
final class InstallerModel: ObservableObject {
    @Published var browsers: [Browser] = Browser.installed()
    @Published var mindNotesURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.mindNotesBundleID)
    /// MindNotes есть, но старая: плагины не поддерживает.
    var mindNotesOutdated: Bool { mindNotesURL.map { !Paths.supportsPlugins($0) } ?? false }
    var canInstall: Bool { mindNotesURL != nil && !mindNotesOutdated }
    @Published var pluginReady = false
    @Published var safariEnabled = false
    @Published var chromeInstalled: Set<String> = []
    /// Браузер, для которого сейчас показана подсказка «перетащите папку».
    @Published var guiding: Browser?
    @Published var running = false
    @Published var message: String?

    private var timer: Timer?

    var allDone: Bool {
        pluginReady && browsers.allSatisfy { $0.isSafari ? safariEnabled : chromeInstalled.contains($0.id) }
    }

    func start(auto: Bool) {
        if auto { prepareChromeFolder() }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshNow() } }
        // Первый запуск — сразу ставим всё: пользователь для этого и открыл установщик.
        if auto, !UserDefaults.standard.bool(forKey: "autoStarted") {
            UserDefaults.standard.set(true, forKey: "autoStarted")
            Task { await installAll() }
        }
    }

    func refreshNow() {
        mindNotesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.mindNotesBundleID)
        pluginReady = Paths.version(of: Paths.installedPlugin.appendingPathComponent("manifest.json")) == Paths.payloadVersion
        let connected = Browser.connectedClientNames()
        chromeInstalled = Set(browsers.filter { !$0.isSafari && (connected.contains($0.clientName) || $0.hasChromeExtension()) }.map(\.id))
        if let guiding, chromeInstalled.contains(guiding.id) { self.guiding = nil }
        Task {
            let enabled = await SafariExtension.isEnabled()
            safariEnabled = enabled || connected.contains("Safari")
        }
    }

    /// Расширение для Chromium лежит в постоянной папке; при новой версии файлы заменяются, браузер подхватит их сам.
    func prepareChromeFolder() {
        let fm = FileManager.default
        let source = Paths.payload.appendingPathComponent("browser/chrome", isDirectory: true)
        let target = Paths.chromeExtension
        if !Self.differs(source, target) { return }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        } catch {
            message = tr("Не удалось подготовить расширение: ", "Could not prepare the extension: ") + error.localizedDescription
        }
    }

    /// Папки различаются составом или содержимым файлов (сравнение по байтам: расширение маленькое).
    static func differs(_ a: URL, _ b: URL) -> Bool {
        func files(_ root: URL) -> [String: Data] {
            var out: [String: Data] = [:]
            let base = root.standardizedFileURL.path + "/"
            for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) ?? FileManager.DirectoryEnumerator() {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, url.lastPathComponent != ".DS_Store" else { continue }
                out[url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")] = try? Data(contentsOf: url)
            }
            return out
        }
        return files(a) != files(b)
    }

    // MARK: Шаги

    /// MindNotes показывает разрешения плагина и ставит его; повторное открытие той же версии только
    /// открывает окно автоподключения браузеров — без вопросов.
    func addToMindNotes(activate: Bool = true) {
        guard let app = mindNotesURL, canInstall else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        NSWorkspace.shared.open([Paths.payload], withApplicationAt: app, configuration: config)
    }

    func installSafari() async {
        addToMindNotes(activate: false)
        if !(await SafariExtension.openSettings()) {
            message = tr("Safari не нашёл расширение. Включите в Safari «Настройки» → «Дополнения» → «Показывать функции для веб-разработчиков», затем «Разработка» → «Разрешить неподписанные расширения» и нажмите ещё раз.",
                         "Safari did not find the extension. In Safari turn on Settings → Advanced → Show features for web developers, then Develop → Allow Unsigned Extensions, and try again.")
        }
    }

    func installChromium(_ browser: Browser) {
        prepareChromeFolder()
        addToMindNotes(activate: false)
        guiding = browser
        browser.openExtensionsPage()
    }

    func installAll() async {
        guard canInstall, !running else { return }
        running = true
        defer { running = false }
        message = nil
        if !pluginReady {
            addToMindNotes()
            guard await wait(seconds: 180, { self.pluginReady }) else { return }
        }
        if browsers.contains(where: \.isSafari), !safariEnabled {
            await installSafari()
            _ = await wait(seconds: 180, { self.safariEnabled })
        }
        for browser in browsers where !browser.isSafari && !chromeInstalled.contains(browser.id) {
            installChromium(browser)
            guard await wait(seconds: 600, { self.chromeInstalled.contains(browser.id) || self.guiding?.id != browser.id }) else { return }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func wait(seconds: Double, _ done: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            refreshNow()
            if done() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Состояние без действий: что найдено и что уже стоит.
    static func report() async -> String {
        var lines = ["payload \(Paths.payloadVersion), safari appex: \(FileManager.default.fileExists(atPath: Bundle.main.builtInPlugInsURL!.appendingPathComponent("MindNotes Web Clipper Extension.appex").path))"]
        let mindNotes = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.mindNotesBundleID)
        lines.append("MindNotes: \(mindNotes?.path ?? "нет"), plugins supported: \(mindNotes.map(Paths.supportsPlugins) ?? false), plugin: \(Paths.version(of: Paths.installedPlugin.appendingPathComponent("manifest.json")) ?? "нет")")
        for b in Browser.installed() {
            let state = b.isSafari ? "enabled=\(await SafariExtension.isEnabled())" : "extension=\(b.hasChromeExtension())"
                + " connected=\(Browser.connectedClientNames().contains(b.clientName))"
            lines.append("\(b.name) [\(b.bundleID)] \(b.appURL.path) \(state)")
        }
        return lines.joined(separator: "\n")
    }

    func copyChromePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Paths.chromeExtension.path, forType: .string)
    }
}

/// Установщик должен жить в «Программах»: Safari берёт расширение из программы, а браузеры — из постоянной папки.
enum Relocation {
    static func moveToApplicationsIfNeeded() -> Bool {
        let fm = FileManager.default
        let here = Bundle.main.bundleURL.standardizedFileURL
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let parent = here.deletingLastPathComponent().path
        guard parent != system.path, parent != user.path else { return false }
        let target = user.appendingPathComponent(here.lastPathComponent)
        do {
            try fm.createDirectory(at: user, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.copyItem(at: here, to: target)
        } catch { return false }
        LSRegisterURL(target as CFURL, true)
        // Исходная копия (папка сборки, «Загрузки») не должна давать второе расширение в Safari.
        let forget = Process()
        forget.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        forget.arguments = ["-u", here.path]
        try? forget.run()
        forget.waitUntilExit()
        // Второй экземпляр запрещён (LSMultipleInstancesProhibited): копия запускается, когда эта уже вышла.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", target.path]
        try? relaunch.run()
        NSApp.terminate(nil)
        return true
    }
}
