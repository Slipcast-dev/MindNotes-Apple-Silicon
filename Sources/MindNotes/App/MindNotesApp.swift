import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Сборка зависимостей принадлежит делегату: завершение и интерфейс видят один объект.
    /// Свойства создаются по порядку: перенос с прежнего имени должен быть раньше первого чтения настроек.
    private let migrated: Void = AppEdition.migrateFromPreviousName()
    let shell = ShellModel()
    let preferences = AppPreferences()
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        SheetOutsideClick.install()
        TitlebarDoubleClick.install()
        shell.observeLockEvents() // Сон экрана закрывает пароли страниц (ADR-0017).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Расширения читаются до оформления: своя тема и иконка нужны с первого кадра (ADR-0015).
        // Хост плагинов узнаёт оболочку раньше: перечитывание реестра запускает локальный API (ADR-0019).
        PluginHost.shared.shell = shell
        ExtensionRegistry.shared.reload()
        Tokens.customColors = ExtensionRegistry.shared.theme(preferences.customThemeID)
        preferences.applyIcon()
        preferences.apply()
        shell.loadKnownWorkspaces()
        shell.restoreLastWorkspace()
        updater.prepareToQuit = { [shell] reply in shell.prepareToTerminate(reply: reply) }
        updater.start() // Фоновая проверка обновлений в автоматическом режиме (ADR-0014).
        PluginUpdater.shared.start(mode: updater.mode) // Обновления плагинов — в том же режиме (ADR-0019).
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in paths where FileManager.default.fileExists(atPath: path) { open(URL(fileURLWithPath: path)) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shell.isOpen else { return .terminateNow }
        // Запись пространства асинхронна: приложение ждёт её подтверждения.
        shell.prepareToTerminate { NSApp.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    /// Файл из Finder только показывается: импорт — отдельное действие (FR-01). Пакет плагина предлагается установить.
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        for url in urls { open(url) }
    }

    private func open(_ url: URL) {
        if url.pathExtension.lowercased() == PluginManifest.packageExtension {
            // Вопрос об установке — после того как окно появилось.
            DispatchQueue.main.async { PluginHost.shared.install(from: url) }
        } else {
            shell.previewFile(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@main
struct MindNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Свои сочетания клавиш: меню перестраивается при их изменении.
    @ObservedObject private var shortcuts = ShortcutSettings.shared

    init() {
        AppEdition.migrateFromPreviousName()
        AppLanguage.applyFirstRunDefault()
    }

    var body: some Scene {
        Window(AppEdition.displayName, id: "main") {
            RootView()
                .environmentObject(delegate.shell)
                .environmentObject(delegate.preferences)
                .environmentObject(delegate.updater)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            FormatCommands(shortcuts: shortcuts)
            CommandMenu(L("Переход")) {
                // Меню не следит за состоянием оболочки: выключенный при запуске пункт так и оставался бы выключенным,
                // и ⌘K не работал. Проверка — внутри действия.
                Button("Поиск…") { if delegate.shell.isOpen { delegate.shell.showsSearch = true } }
                    .appShortcut(shortcuts.shortcut("nav.search"))
                Button("Назад") { delegate.shell.goBack() }
                    .appShortcut(shortcuts.shortcut("nav.back"))
                Button("Вперёд") { delegate.shell.goForward() }
                    .appShortcut(shortcuts.shortcut("nav.forward"))
                Button("Боковая панель") { delegate.shell.toggleSidebar() }
                    .appShortcut(shortcuts.shortcut("nav.sidebar"))
                Divider()
                Button("Главная") { delegate.shell.goHome() }
                    .appShortcut(shortcuts.shortcut("nav.home"))
                Button("Чат с ИИ") { if delegate.shell.isOpen { AIChatModel.shared.toggle() } }
                    .appShortcut(shortcuts.shortcut("ai.chat"))
            }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { Task { await delegate.updater.check(silent: false) } }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { delegate.shell.goSettings() }
                    .appShortcut(shortcuts.shortcut("app.settings"))
            }
            CommandGroup(replacing: .newItem) {
                Button("Новая страница") { if delegate.shell.isOpen { delegate.shell.createPage() } }
                    .appShortcut(shortcuts.shortcut("file.newPage"))
                Button("Новая папка") { if delegate.shell.isOpen { delegate.shell.createFolder() } }
                    .appShortcut(shortcuts.shortcut("file.newFolder"))
                Divider()
                Button("Открыть файл…") { delegate.shell.presentOpenFile() }
                    .appShortcut(shortcuts.shortcut("file.open"))
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

/// Двойной щелчок по верхней полосе окна разворачивает его (или сворачивает — по настройке macOS).
/// Подпись и распорка панели SwiftUI забирают щелчок себе, поэтому системное поведение здесь не срабатывало.
enum TitlebarDoubleClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { handle($0) }
    }

    static func handle(_ event: NSEvent) -> NSEvent? {
        guard event.clickCount == 2, let window = event.window, window.attachedSheet == nil,
              window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen) else { return event }
        let point = event.locationInWindow
        guard TitlebarGesture.isTitlebar(x: point.x, y: point.y, windowWidth: window.frame.width, contentTop: window.contentLayoutRect.maxY) else { return event }
        // Кнопки окна (закрыть, свернуть, развернуть) работают как обычно.
        if let frame = window.contentView?.superview, var hit = frame.hitTest(frame.convert(point, from: nil)) as NSView? {
            while true {
                if hit is NSControl { return event }
                guard let parent = hit.superview else { break }
                hit = parent
            }
        }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        switch TitlebarGesture.action(preference: global["AppleActionOnDoubleClick"] as? String,
                                      legacyMinimize: (global["AppleMiniaturizeOnDoubleClick"] as? Bool) ?? false) {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: return event
        }
        return nil // Щелчок обработан: система не выполнит его второй раз.
    }
}

