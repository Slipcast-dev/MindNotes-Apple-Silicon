import AppKit
import SwiftUI

enum AppLanguage: String {
    case ru, en

    static var saved: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .ru }

    /// Русский — язык первого запуска (FR-16). macOS читает `AppleLanguages` при запуске, поэтому смена требует перезапуска.
    static func applyFirstRunDefault() {
        if UserDefaults.standard.string(forKey: "language") == nil { AppLanguage.ru.apply() }
    }

    func apply() {
        UserDefaults.standard.set(rawValue, forKey: "language")
        UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
    }
}

/// Настройки внешнего вида. Оформление приложения всегда задаётся явно.
final class AppPreferences: ObservableObject {
    @Published var isDark: Bool {
        didSet {
            UserDefaults.standard.set(isDark, forKey: "isDark")
            apply()
        }
    }

    init() {
        let stored = UserDefaults.standard.object(forKey: "isDark") as? Bool
        isDark = stored ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
    }

    func apply() {
        NSApp?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

/// Смена языка вступает в силу после перезапуска.
enum AppRestart {
    static func offer() {
        let alert = NSAlert()
        alert.messageText = L("Чтобы сменить язык, нужно перезапустить приложение.")
        alert.addButton(withTitle: L("Перезапустить"))
        alert.addButton(withTitle: L("Позже"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
