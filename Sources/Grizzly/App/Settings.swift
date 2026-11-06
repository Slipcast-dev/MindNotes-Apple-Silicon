import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .light: return L("Светлая")
        case .dark: return L("Тёмная")
        }
    }
}

/// Interface language. `auto` follows the system: Russian on a Russian system, English otherwise.
enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, ru, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Как в системе")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// The choice in effect, read from the app's own defaults domain (before the first change it is `auto`).
    static var saved: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .auto
    }

    /// macOS picks the bundle language from `AppleLanguages` at launch, so the choice takes effect after a restart.
    func apply() {
        let d = UserDefaults.standard
        d.set(rawValue, forKey: "language")
        if self == .auto { d.removeObject(forKey: "AppleLanguages") } else { d.set([rawValue], forKey: "AppleLanguages") }
    }
}

/// User preferences, saved to UserDefaults on every change.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    static let systemFont = "Системный"
    /// The system font, the fonts that come with Grizzly, then a few that every Mac has.
    static var fonts: [String] {
        [systemFont] + FontLibrary.bundledFamilies + ["Georgia", "Palatino", "Times New Roman", "Helvetica Neue", "Avenir Next", "Menlo"]
    }

    private let defaults = UserDefaults.standard

    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    @Published var themeID: String { didSet { defaults.set(themeID, forKey: "themeID"); applyAppearance() } }
    @Published var fontName: String { didSet { defaults.set(fontName, forKey: "fontName") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    /// Font and size of the application's own interface (not of the documents).
    @Published var uiFontName: String { didSet { defaults.set(uiFontName, forKey: "uiFontName") } }
    @Published var uiFontSize: Double { didSet { defaults.set(uiFontSize, forKey: "uiFontSize") } }
    /// Multiplier for the space around Markdown headings.
    @Published var headingSpacing: Double { didSet { defaults.set(headingSpacing, forKey: "headingSpacing") } }
    @Published var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: "showLineNumbers") } }
    /// The glass effect: the window is see-through and blurs what is behind it. `glassAmount` is how much (0...1).
    @Published var glassEnabled: Bool { didSet { defaults.set(glassEnabled, forKey: "glassEnabled") } }
    /// How much each part lets the desktop through (0...1): the document, the tab bar and the sidebar are set apart.
    @Published var glassAmount: Double { didSet { defaults.set(glassAmount, forKey: "glassAmount") } }
    @Published var glassTabs: Double { didSet { defaults.set(glassTabs, forKey: "glassTabs") } }
    @Published var glassSidebar: Double { didSet { defaults.set(glassSidebar, forKey: "glassSidebar") } }
    @Published var autoReload: Bool { didSet { defaults.set(autoReload, forKey: "autoReload") } }
    /// A check list item that gets ticked moves to the end of its list.
    @Published var moveDoneTasks: Bool { didSet { defaults.set(moveDoneTasks, forKey: "moveDoneTasks") } }
    /// Syntax coloring: a master switch plus a list of file types that are switched off individually.
    @Published var syntaxEnabled: Bool { didSet { defaults.set(syntaxEnabled, forKey: "syntaxEnabled") } }
    @Published var syntaxOff: Set<String> { didSet { defaults.set(syntaxOff.sorted(), forKey: "syntaxOff") } }
    /// Spelling and grammar checking (Russian and English) with underlined mistakes in Edit mode.
    @Published var spellCheck: Bool { didSet { defaults.set(spellCheck, forKey: "spellCheck") } }
    @Published var language: AppLanguage { didSet { language.apply() } }
    @Published private(set) var systemIsDark: Bool { didSet { applyAppearance() } }

    private init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        themeID = d.string(forKey: "themeID") ?? "xcode"
        fontName = d.string(forKey: "fontName") ?? Preferences.systemFont
        fontSize = d.object(forKey: "fontSize") as? Double ?? 15
        uiFontName = d.string(forKey: "uiFontName") ?? Preferences.systemFont
        uiFontSize = d.object(forKey: "uiFontSize") as? Double ?? AppFont.defaultSize
        headingSpacing = d.object(forKey: "headingSpacing") as? Double ?? 1
        showLineNumbers = d.object(forKey: "showLineNumbers") as? Bool ?? true
        glassEnabled = d.object(forKey: "glassEnabled") as? Bool ?? true
        glassAmount = d.object(forKey: "glassAmount") as? Double ?? 0.35
        glassTabs = d.object(forKey: "glassTabs") as? Double ?? (d.object(forKey: "glassAmount") as? Double ?? 0.35)
        glassSidebar = d.object(forKey: "glassSidebar") as? Double ?? 1
        autoReload = d.object(forKey: "autoReload") as? Bool ?? false
        moveDoneTasks = d.object(forKey: "moveDoneTasks") as? Bool ?? true
        syntaxEnabled = d.object(forKey: "syntaxEnabled") as? Bool ?? true
        syntaxOff = Set(d.stringArray(forKey: "syntaxOff") ?? [])
        spellCheck = d.object(forKey: "spellCheck") as? Bool ?? true
        language = AppLanguage.saved
        systemIsDark = Preferences.readSystemDark()

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            // The preference may not be written yet when the notification arrives: read it again a little later.
            for delay in [0.2, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.systemIsDark = Preferences.readSystemDark() }
            }
        }
    }

    private static func readSystemDark() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return style == "Dark"
    }

    /// Makes the whole app (sidebar, toolbar, Settings, panels), not only the document area, follow the chosen look.
    /// It is set explicitly, never left to the system, so that nothing stays in the previous scheme.
    func applyAppearance() {
        guard let app = NSApp else { return }
        let name: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
        guard app.appearance?.name != name else { return }
        app.appearance = NSAppearance(named: name)
        for window in app.windows { window.appearance = nil; window.invalidateShadow() }
    }

    /// Changes with the interface font; the views that use `AppFont` are rebuilt when it does.
    var uiFontKey: String { "\(uiFontName)|\(uiFontSize)" }

    /// Opacity of the backgrounds of documents and tabs: 1 without the glass effect.
    var surfaceOpacity: Double { glassEnabled ? 1 - 0.8 * glassAmount : 1 }
    /// The same for the tab bar.
    var tabsOpacity: Double { glassEnabled ? 1 - 0.8 * glassTabs : 1 }
    /// Opacity of the tint over the sidebar's own material: 0 (the plain system sidebar) when the slider is at 100%.
    var sidebarTint: Double { glassEnabled ? 1 - glassSidebar : 0 }

    var wantsDark: Bool {
        switch appearance {
        case .system: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    func highlights(_ type: FileType) -> Bool { syntaxEnabled && !syntaxOff.contains(type.rawValue) }

    func setHighlight(_ type: FileType, _ on: Bool) {
        if on { syntaxOff.remove(type.rawValue) } else { syntaxOff.insert(type.rawValue) }
    }

    var theme: Theme { ThemeSet.find(themeID).variant(dark: wantsDark) }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fontName == Preferences.systemFont ? .system(size: size, weight: weight)
            : Font(FontLibrary.font(family: fontName, size: size, bold: weight == .semibold || weight == .bold))
    }

    func resizeFont(by delta: Double) { fontSize = min(28, max(10, fontSize + delta)) }
}
