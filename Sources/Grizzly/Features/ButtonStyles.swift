import SwiftUI

/// One look for every custom button: a soft tint of the theme's accent color on hover, a stronger one with a small
/// "press" shrink while the mouse is down. `base` is the idle fill (0 = no background at rest).
struct HoverButtonStyle: ButtonStyle {
    enum Size { case compact, icon, row }
    var size: Size = .icon
    var base: Double = 0
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, size: size, base: base, selected: selected)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let size: Size
        let base: Double
        let selected: Bool
        @State private var hovering = false
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed
            let fill: Color = selected ? theme.accent
                : pressed ? theme.accent.opacity(0.30)
                : hovering ? theme.accent.opacity(0.16)
                : Color.primary.opacity(base)
            let active = enabled && (hovering || pressed) && !selected

            configuration.label
                .foregroundColor(selected ? .white : (active ? theme.accent : .primary))
                .padding(.horizontal, size == .compact ? 8 : 0)
                .frame(minWidth: size == .compact ? 0 : 30, maxWidth: size == .row ? .infinity : nil)
                .frame(height: size == .compact ? 26 : (size == .icon ? 28 : 30))
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .scaleEffect(pressed ? 0.95 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: pressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
    static var hoverText: HoverButtonStyle { HoverButtonStyle(size: .compact) }
    static var hoverFilled: HoverButtonStyle { HoverButtonStyle(size: .compact, base: 0.08) }
}
