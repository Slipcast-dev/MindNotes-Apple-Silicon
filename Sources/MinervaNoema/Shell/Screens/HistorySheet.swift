import SwiftUI

/// История версий страницы (FR-07.8–9): список снимков, просмотр и восстановление.
struct HistorySheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    let page: Page
    @State private var revisions: [Revision] = []
    @State private var selected: Revision?
    @State private var preview: [Block] = []
    @State private var loaded = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("История версий").font(.system(size: 15, weight: .semibold)).padding(16)
            Rectangle().fill(Tokens.line).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if loaded, revisions.isEmpty {
                            Text("Версий пока нет. Снимок появляется при уходе со страницы и не чаще раза в 10 минут во время работы.")
                                .font(.system(size: 12)).foregroundColor(Tokens.muted).padding(12)
                        }
                        ForEach(revisions) { revision in
                            Button { select(revision) } label: { row(revision) }.buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 230)
                Rectangle().fill(Tokens.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if selected != nil, preview.isEmpty {
                            Text("Пустая страница").foregroundColor(Tokens.muted)
                        }
                        ForEach(preview) { block in Text(Self.line(block)).font(.system(size: 13)).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            .frame(height: 380)
            Rectangle().fill(Tokens.line).frame(height: 1)
            HStack {
                Button("Восстановить эту версию") { confirming = true }
                    .buttonStyle(NotesButtonStyle(kind: .primary))
                    .disabled(selected == nil)
                Spacer()
                Button("Закрыть") { dismiss() }
                    .buttonStyle(NotesButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 720)
        .background(Tokens.paper)
        .task {
            revisions = await shell.revisions(of: page.id)
            loaded = true
            if let first = revisions.first { select(first) }
        }
        .alert(Text("Восстановить версию?"), isPresented: $confirming) {
            Button("Восстановить") {
                guard let revision = selected else { return }
                dismiss()
                shell.restore(revision)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущий текст сохранится в истории. Вернуть его можно и через ⌘Z.")
        }
    }

    private func select(_ revision: Revision) {
        selected = revision
        Task {
            let blocks = await shell.revisionBlocks(revision)
            // Ответы могут прийти не по порядку: показывается только выбранная сейчас версия.
            if selected?.id == revision.id { preview = blocks }
        }
    }

    private func row(_ revision: Revision) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.date(revision.createdAt)).font(.system(size: 13, weight: .medium))
            Text(verbatim: "\(String(format: L("Версия %d"), revision.seq)) · \(Self.reason(revision.reason))")
                .font(.system(size: 11)).foregroundColor(Tokens.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected?.id == revision.id ? Tokens.soft : Color.clear))
        .contentShape(Rectangle())
    }

    /// Причина хранится по-русски: это постоянный ключ. Показывается переведённой; номер версии сохраняется.
    static func reason(_ stored: String) -> String {
        let prefix = "Восстановлено из версии "
        if stored.hasPrefix(prefix), let n = Int(stored.dropFirst(prefix.count)) {
            return String(format: L("Восстановлено из версии %d"), n)
        }
        return L(stored)
    }

    static func date(_ millis: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyyHHmm")
        return f.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    /// Строка просмотра: текст с меткой типа, как в Markdown.
    static func line(_ block: Block) -> String {
        let text = block.plainText
        switch block.type {
        case .heading1: return "# " + text
        case .heading2: return "## " + text
        case .heading3: return "### " + text
        case .task: return (block.content?.checked == true ? "☑ " : "☐ ") + text
        case .bullet: return "• " + text
        case .numbered: return "1. " + text
        case .quote, .callout: return "> " + text
        case .divider: return "———"
        case .image: return L("[Изображение]") + (text.isEmpty ? "" : " " + text)
        case .file: return L("[Файл]") + (text.isEmpty ? "" : " " + text)
        case .table: return L("[Таблица]")
        case .databaseView: return L("[Представление базы]")
        default: return text
        }
    }
}
