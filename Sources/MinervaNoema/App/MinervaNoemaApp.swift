import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Сборка зависимостей принадлежит делегату: завершение и интерфейс видят один объект.
    /// Свойства создаются по порядку: перенос с прежнего имени должен быть раньше первого чтения настроек.
    private let migrated: Void = AppEdition.migrateFromPreviousName()
    let shell = ShellModel()
    let preferences = AppPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        SheetOutsideClick.install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        preferences.apply()
        shell.loadKnownWorkspaces()
        shell.restoreLastWorkspace()
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in paths where FileManager.default.fileExists(atPath: path) { shell.previewFile(URL(fileURLWithPath: path)) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shell.isOpen else { return .terminateNow }
        // Запись пространства асинхронна: приложение ждёт её подтверждения.
        shell.prepareToTerminate { NSApp.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    /// Файл из Finder только показывается: импорт — отдельное действие (FR-01).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { shell.previewFile(url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@main
struct MinervaNoemaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        AppEdition.migrateFromPreviousName()
        AppLanguage.applyFirstRunDefault()
    }

    var body: some Scene {
        Window(AppEdition.displayName, id: "main") {
            RootView()
                .environmentObject(delegate.shell)
                .environmentObject(delegate.preferences)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            FormatCommands()
            CommandMenu(L("Переход")) {
                // Меню не следит за состоянием оболочки: выключенный при запуске пункт так и оставался бы выключенным,
                // и ⌘K не работал. Проверка — внутри действия.
                Button("Поиск…") { if delegate.shell.isOpen { delegate.shell.showsSearch = true } }
                    .keyboardShortcut("k")
                Button("Назад") { delegate.shell.goBack() }
                    .keyboardShortcut("[")
                Button("Вперёд") { delegate.shell.goForward() }
                    .keyboardShortcut("]")
                Divider()
                Button("Главная") { delegate.shell.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { delegate.shell.goSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Новая страница") { if delegate.shell.isOpen { delegate.shell.createPage() } }
                    .keyboardShortcut("n")
                Button("Новая папка") { if delegate.shell.isOpen { delegate.shell.createFolder() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Открыть файл…") { delegate.shell.presentOpenFile() }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Запоминает размер и положение окна между запусками.
struct WindowFrameSaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.setFrameAutosaveName(name) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Щелчок по окну, над которым открыт лист (поиск, перемещение, история…), закрывает лист так же, как Esc.
enum SheetOutsideClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { handle($0) }
    }

    /// Отдельно от монитора, чтобы проверить без цикла событий.
    static func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let sheet = window.attachedSheet, sheet !== window else { return event }
        // Esc — то же действие, что уже закрывает лист с клавиатуры: правила закрытия у каждого листа свои.
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: event.timestamp,
                                         windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            sheet.makeKey()
            sheet.sendEvent(escape)
        }
        return nil
    }
}
