import AppKit
import SwiftUI

/// Поиск ⌘K: страницы и текст блоков. Управляется с клавиатуры.
struct SearchSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var selected = 0
    @State private var searched = false

    private var recents: [SearchHit] {
        shell.recent.map { SearchHit(pageID: $0.id, blockID: nil, title: $0.title, snippet: "") }
    }

    private var rows: [SearchHit] { query.trimmingCharacters(in: .whitespaces).isEmpty ? recents : hits }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Tokens.muted)
                SearchField(text: $query, placeholder: L("Найти страницу или текст"),
                            onMove: move, onSubmit: open, onCancel: { dismiss() })
                    .frame(height: 24)
            }
            .padding(14)
            Rectangle().fill(Tokens.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text(searched ? "Ничего не найдено. Попробуйте другой запрос." : "Начните вводить запрос.")
                                .foregroundColor(Tokens.muted)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, hit in
                            Button { selected = i; open() } label: { row(hit, active: i == selected) }
                                .buttonStyle(.plain)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { proxy.scrollTo($0) }
            }
            .frame(height: 320)
        }
        .frame(width: 600)
        .background(Tokens.paper)
        .task(id: query) {
            // Пауза, чтобы не искать на каждый символ при быстром вводе.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let found = await shell.search(query)
            guard !Task.isCancelled else { return }
            hits = found
            searched = !query.trimmingCharacters(in: .whitespaces).isEmpty
            selected = 0
        }
    }

    private func row(_ hit: SearchHit, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title.isEmpty ? L("Без названия") : hit.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if !hit.snippet.isEmpty {
                Text(highlighted(hit.snippet)).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? Tokens.soft : .clear))
        .contentShape(Rectangle())
    }

    /// Подсветка первого слова запроса во фрагменте.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let word = SearchText.tokens(query).first else { return out }
        let source = SearchText.normalize(text)
        if let hit = source.range(of: word), source.count == text.count {
            let start = source.distance(from: source.startIndex, to: hit.lowerBound)
            let lower = out.index(out.startIndex, offsetByCharacters: start)
            let upper = out.index(lower, offsetByCharacters: word.count)
            out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            out[lower..<upper].foregroundColor = Tokens.ink
        }
        return out
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
    }

    private func open() {
        guard rows.indices.contains(selected) else { return }
        let hit = rows[selected]
        dismiss()
        shell.openPage(hit.pageID, block: hit.blockID)
    }
}

/// Поле ввода со стрелками: SwiftUI на macOS 13 не даёт перехватить их в TextField.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
