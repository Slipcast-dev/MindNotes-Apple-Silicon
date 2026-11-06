import AppKit
import SwiftUI

struct ThemePalette {
    var paper, side, ink, muted, line, accent, soft, card, primary, logo, danger: UInt32
}

/// Темы приложения: у каждой светлый и тёмный вариант.
enum AppTheme: String, CaseIterable, Identifiable {
    case grizzly, notion
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grizzly: return L("Лесная")
        case .notion: return L("Чёрно-белая")
        }
    }

    var subtitle: String {
        switch self {
        case .grizzly: return L("Зелёная, с заголовками Georgia")
        case .notion: return L("Как в Notion: чёрный на белом, без акцентов")
        }
    }

    func palette(dark: Bool) -> ThemePalette {
        switch (self, dark) {
        case (.grizzly, false):
            return ThemePalette(paper: 0xFDFCF8, side: 0xF4F4ED, ink: 0x252B22, muted: 0x666D60, line: 0xE3E5D9, accent: 0x395740,
                                soft: 0xE6ECDF, card: 0xFFFEFB, primary: 0x3C5A40, logo: 0x3D5941, danger: 0xAD463C)
        case (.grizzly, true):
            return ThemePalette(paper: 0x252D25, side: 0x202720, ink: 0xEDF0E7, muted: 0xB6C0B0, line: 0x3B463A, accent: 0xABD1A1,
                                soft: 0x364735, card: 0x2D372D, primary: 0x3C5A40, logo: 0x3D5941, danger: 0xE8988F)
        case (.notion, false):
            return ThemePalette(paper: 0xFFFFFF, side: 0xF7F7F5, ink: 0x37352F, muted: 0x787774, line: 0xE9E9E7, accent: 0x37352F,
                                soft: 0xEFEFED, card: 0xFFFFFF, primary: 0x37352F, logo: 0x37352F, danger: 0xD44C47)
        case (.notion, true):
            return ThemePalette(paper: 0x191919, side: 0x202020, ink: 0xE3E2E0, muted: 0x9B9B9B, line: 0x2F2F2F, accent: 0xE3E2E0,
                                soft: 0x2C2C2C, card: 0x252525, primary: 0x4A4A4A, logo: 0x4A4A4A, danger: 0xE8988F)
        }
    }

    /// Обложка по умолчанию.
    var defaultCover: String { self == .notion ? "mono" : "forest" }
}

/// Цвета и размеры из макетов. Динамические NSColor, чтобы ими пользовался и AppKit-редактор.
enum Tokens {
    /// Текущая тема. Меняется только через настройки, после чего дерево интерфейса перестраивается.
    static var theme: AppTheme = .grizzly

    private static func dynamic(_ value: KeyPath<ThemePalette, UInt32>) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(theme.palette(dark: isDark)[keyPath: value])
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let paperNS = dynamic(\.paper)
    static let inkNS = dynamic(\.ink)
    static let mutedNS = dynamic(\.muted)
    static let accentNS = dynamic(\.accent)
    static let lineNS = dynamic(\.line)
    static let softNS = dynamic(\.soft)

    static let paper = Color(paperNS)
    static let side = Color(dynamic(\.side))
    static let ink = Color(inkNS)
    static let muted = Color(mutedNS)
    static let line = Color(lineNS)
    static let accent = Color(accentNS)
    static let soft = Color(softNS)
    static let card = Color(dynamic(\.card))
    static let primary = Color(dynamic(\.primary))
    static let logo = Color(dynamic(\.logo))
    static let danger = Color(dynamic(\.danger))

    static let chipGold = (bg: Color(dynamic(0xF4E6CA, 0x4F4326)), fg: Color(dynamic(0x694922, 0xF0DDB5)))
    static let chipGreen = (bg: Color(dynamic(0xDCEAD7, 0x34503A)), fg: Color(dynamic(0x36583B, 0xCFE8C8)))

    static let sidebarWidth: CGFloat = 240
    static let crumbHeight: CGFloat = 54
    static let editorWidth: CGFloat = 735
    static let contentPadding: CGFloat = 44

    static func titleFont(_ size: CGFloat = 44) -> Font {
        theme == .notion ? .system(size: size * 0.9, weight: .bold) : .custom("Georgia", size: size)
    }

    /// Цвет из общей палитры тегов и логотипа.
    static func swatch(_ name: String?) -> (bg: Color, fg: Color)? {
        guard let name, let c = BlockTextStyle.colors.first(where: { $0.name == name }) else { return nil }
        return (Color(rgb(c.background)), Color(rgb(c.text)))
    }
}
/// Надзаголовок: мелкие прописные буквы с разрядкой.
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.65)
            .foregroundColor(Tokens.accent)
    }
}

struct ScreenTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.titleFont())
            .tracking(Tokens.theme == .notion ? -0.6 : -1.5)
            .foregroundColor(Tokens.ink)
    }
}

struct NotesButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, plain }
    var kind: Kind = .normal
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .fixedSize()
            .foregroundColor(kind == .primary ? .white : Tokens.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(background(configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind == .normal ? Tokens.line : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? Tokens.primary.opacity(0.85) : Tokens.primary
        case .normal: return hover || pressed ? Tokens.soft : Tokens.card
        case .plain: return hover || pressed ? Tokens.soft : .clear
        }
    }
}

struct Chip: View {
    let text: String
    var colors: (bg: Color, fg: Color) = (Tokens.soft, Tokens.ink)
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(colors.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(colors.bg))
    }
}
