import SwiftUI

struct TabBar: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.tabsOpacity) private var surface

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(state.documents) { doc in TabItem(doc: doc) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .frame(height: 34)
        .background(theme.codeBackground.opacity(0.7 * surface))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabItem: View {
    let doc: Document
    @EnvironmentObject private var state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.tabsOpacity) private var surface
    @State private var hovering = false

    private var isLeft: Bool { state.selection == doc.id }
    private var isRight: Bool { state.isSplit && state.rightSelection == doc.id }
    private var isFocused: Bool { state.current?.id == doc.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: doc.type.symbol)
                .font(AppFont.caption)
                .foregroundColor(theme.secondary)
            Text(doc.name)
                .font(AppFont.callout)
                .lineLimit(1)
                .foregroundColor(isFocused || isLeft || isRight ? theme.text : theme.secondary)
            if state.isDirty(doc.id) {
                Circle().fill(theme.warning).frame(width: 7, height: 7)
                    .help("Есть несохранённые изменения.")
            }
            if isRight {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(AppFont.caption2)
                    .foregroundColor(theme.accent)
                    .help("Показан в правой панели")
            }
            Button { state.close(doc.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(HoverButtonStyle(size: .compact))
            .frame(width: 20)
            .opacity(hovering || isFocused ? 1 : 0)
            .help("Закрыть вкладку")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            TopRoundedShape(topLeading: 7, topTrailing: 7).fill(fill)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            state.selectTab(doc.id, inRight: NSEvent.modifierFlags.contains(.option))
        }
        .contextMenu {
            Button("Открыть справа") { state.selectTab(doc.id, inRight: true) }
            Divider()
            Button("Закрыть") { state.close(doc.id) }
            Button("Закрыть остальные") { state.closeOthers(keeping: doc.id) }
                .disabled(state.documents.count < 2)
        }
    }

    private var fill: Color {
        if isFocused { return theme.background.opacity(surface) }
        if isLeft || isRight { return theme.background.opacity(0.55 * surface) }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }
}

/// Rounded top corners only (UnevenRoundedRectangle needs macOS 14).
private struct TopRoundedShape: Shape {
    var topLeading: CGFloat
    var topTrailing: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeading))
        p.addArc(center: CGPoint(x: rect.minX + topLeading, y: rect.minY + topLeading),
                 radius: topLeading, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - topTrailing, y: rect.minY + topTrailing),
                 radius: topTrailing, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
