import SwiftUI

struct FindBar: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(theme.secondary)

            TextField("Найти в документе", text: $state.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { state.stepMatch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onExitCommand { state.hideFind() }

            Text(countLabel)
                .font(AppFont.caption)
                .foregroundColor(theme.secondary)
                .monospacedDigit()

            Button { state.stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                .help("Предыдущее совпадение (⌘⇧G)")
            Button { state.stepMatch(1) } label: { Image(systemName: "chevron.down") }
                .help("Следующее совпадение (⌘G)")
            Button("Готово") { state.hideFind() }
                .buttonStyle(.hoverText)
        }
        .buttonStyle(.hover)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.codeBackground.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
        .onChange(of: state.findFocusToken) { _ in focused = true }
    }

    private var countLabel: String {
        if state.findQuery.isEmpty { return "" }
        if state.matches.isEmpty { return L("Нет совпадений") }
        return L("%d из %d", state.matchIndex + 1, state.matches.count)
    }
}

struct BookmarksButton: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.theme) private var theme
    @State private var shown = false

    private var lines: [Int] { library.bookmarks(for: state.current?.libraryID) }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: lines.isEmpty ? "bookmark" : "bookmark.fill")
        }
        .buttonStyle(.hover)
        .help("Закладки")
        .disabled(state.current == nil)
        .popover(isPresented: $shown, arrowEdge: .bottom) { list }
    }

    @ViewBuilder
    private var list: some View {
        let doc = state.current
        VStack(alignment: .leading, spacing: 6) {
            Text("Закладки").font(AppFont.headline)
            if lines.isEmpty {
                Text("Пока нет закладок. В режиме «Исходник» нажмите на номер строки, чтобы поставить закладку.")
                    .font(AppFont.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.self) { line in
                            row(line, doc: doc)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ line: Int, doc: Document?) -> some View {
        let preview = doc.flatMap { $0.lines.indices.contains(line - 1) ? $0.lines[line - 1] : nil } ?? ""
        return HStack(spacing: 8) {
            Button {
                shown = false
                state.goToLine(line - 1)
            } label: {
                HStack(spacing: 8) {
                    Text("\(line)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(theme.bookmark)
                        .frame(width: 36, alignment: .trailing)
                    Text(preview.trimmingCharacters(in: .whitespaces).isEmpty ? L("(пустая строка)") : preview)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { library.toggleBookmark(doc?.libraryID, line: line) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Убрать закладку")
        }
        .padding(.vertical, 3)
    }
}
