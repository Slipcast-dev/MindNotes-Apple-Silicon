import SwiftUI

/// The fonts of the application's own interface (sidebar, tabs, panels, settings). The family and the size come from
/// *Settings → Appearance*; the sizes below are the macOS defaults, scaled by the chosen body size.
enum AppFont {
    static let defaultSize = 13.0

    static var body: Font { make(13) }
    static var callout: Font { make(12) }
    static var caption: Font { make(10.5) }
    static var caption2: Font { make(10) }
    static var headline: Font { make(13, bold: true) }
    static var title3: Font { make(15) }
    static var title2: Font { make(17) }

    private static func make(_ base: CGFloat, bold: Bool = false) -> Font {
        let prefs = Preferences.shared
        let size = base * CGFloat(prefs.uiFontSize / defaultSize)
        if prefs.uiFontName == Preferences.systemFont { return .system(size: size, weight: bold ? .semibold : .regular) }
        return Font(FontLibrary.font(family: prefs.uiFontName, size: size, bold: bold))
    }
}
