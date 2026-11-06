import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Сборка зависимостей принадлежит делегату: завершение и интерфейс видят один объект.
    let shell = ShellModel()
    let preferences = AppPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
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
struct GrizzlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() { AppLanguage.applyFirstRunDefault() }

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
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { delegate.shell.goSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Новая страница") { delegate.shell.createPage() }
                    .keyboardShortcut("n")
                    .disabled(!delegate.shell.isOpen)
                Button("Новая папка") { delegate.shell.createFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!delegate.shell.isOpen)
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
