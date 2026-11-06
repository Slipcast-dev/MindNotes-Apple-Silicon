import AppKit
import SwiftUI

/// Цвета и размеры из макетов. Динамические NSColor, чтобы ими пользовался и AppKit-редактор.
enum Tokens {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let paperNS = dynamic(0xFDFCF8, 0x252D25)
    static let inkNS = dynamic(0x252B22, 0xEDF0E7)
    static let mutedNS = dynamic(0x666D60, 0xB6C0B0)
    static let accentNS = dynamic(0x395740, 0xABD1A1)
    static let lineNS = dynamic(0xE3E5D9, 0x3B463A)
    static let softNS = dynamic(0xE6ECDF, 0x364735)

    static let paper = Color(paperNS)
    static let side = Color(dynamic(0xF4F4ED, 0x202720))
    static let ink = Color(inkNS)
    static let muted = Color(mutedNS)
    static let line = Color(lineNS)
    static let accent = Color(accentNS)
    static let soft = Color(softNS)
    static let card = Color(dynamic(0xFFFEFB, 0x2D372D))
    static let primary = Color(rgb(0x3C5A40))
    static let logo = Color(rgb(0x3D5941))
    static let danger = Color(dynamic(0xAD463C, 0xE8988F))

    static let chipGold = (bg: Color(dynamic(0xF4E6CA, 0x4F4326)), fg: Color(dynamic(0x694922, 0xF0DDB5)))
    static let chipGreen = (bg: Color(dynamic(0xDCEAD7, 0x34503A)), fg: Color(dynamic(0x36583B, 0xCFE8C8)))

    static let sidebarWidth: CGFloat = 240
    static let crumbHeight: CGFloat = 54
    static let editorWidth: CGFloat = 735
    static let contentPadding: CGFloat = 44

    static func titleFont(_ size: CGFloat = 44) -> Font { .custom("Georgia", size: size) }
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
            .tracking(-1.5)
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
