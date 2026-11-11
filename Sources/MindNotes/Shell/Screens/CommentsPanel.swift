import SwiftUI

/// Все комментарии страницы (M14): комментарий к странице, ветки с ответами, «Решено» и удаление.
struct CommentsPanel: View {
    @EnvironmentObject private var shell: ShellModel
    let page: UUID
    @State private var draft = ""
    @State private var replies: [UUID: String] = [:]
    @State private var showResolved = false

    private var threads: [CommentThread] {
        shell.commentThreads.filter { showResolved || !$0.root.resolved || $0.id == shell.focusedThread }
    }

    private func date(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Комментарии").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("Автор", selection: Binding(get: { shell.commentAuthor }, set: { shell.setCommentAuthor($0) })) {
                    Text("Без автора").tag(UUID?.none)
                    ForEach(shell.people) { Text($0.label).tag(UUID?.some($0.id)) }
                }
                .frame(width: 170)
                .help(L("Автор новых комментариев — из справочника людей («Настройки» → «Люди»)"))
            }
            HStack(alignment: .top) {
                TextField("Комментарий к странице…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button("Добавить") {
                    let text = draft
                    draft = ""
                    Task { _ = await shell.addComment(page: page, block: nil, anchor: "", body: text) }
                }
                .disabled(Comment.clean(draft) == nil)
            }
            Toggle("Показывать решённые", isOn: $showResolved).font(.system(size: 12))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if threads.isEmpty {
                            Text("Комментариев пока нет. Выделите текст и выберите «Комментировать…» в меню правой кнопки.")
                                .font(.system(size: 12)).foregroundColor(Tokens.muted)
                        }
                        ForEach(threads) { thread in threadView(thread).id(thread.id) }
                    }
                }
                .onAppear { if let focus = shell.focusedThread { proxy.scrollTo(focus, anchor: .top) } }
            }
        }
        .padding(14)
        .frame(width: 440, height: 520)
    }

    private func threadView(_ thread: CommentThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thread.root.anchorText.isEmpty {
                Text("«\(thread.root.anchorText)»").font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(2)
                    .padding(.leading, 6).overlay(Rectangle().fill(Color.yellow).frame(width: 2), alignment: .leading)
            } else {
                Text("К странице").font(.system(size: 11)).foregroundColor(Tokens.muted)
            }
            ForEach([thread.root] + thread.replies) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(comment.authorName ?? L("Без автора")).font(.system(size: 12, weight: .semibold))
                        Text(date(comment.createdAt)).font(.system(size: 11)).foregroundColor(Tokens.muted)
                        Spacer()
                        Button { shell.deleteComment(comment.id, page: page) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundColor(Tokens.muted)
                            .help(comment.isRoot ? L("Удалить ветку") : L("Удалить комментарий"))
                    }
                    Text(comment.body).font(.system(size: 13)).textSelection(.enabled)
                }
            }
            HStack {
                TextField("Ответить…", text: Binding(get: { replies[thread.id] ?? "" }, set: { replies[thread.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(thread) }
                Button(thread.root.resolved ? L("Открыть снова") : L("Решено")) {
                    shell.resolveThread(thread.id, !thread.root.resolved, page: page)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(thread.id == shell.focusedThread ? Tokens.accent.opacity(0.08) : Tokens.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tokens.line))
        .opacity(thread.root.resolved ? 0.6 : 1)
    }

    private func send(_ thread: CommentThread) {
        guard let text = replies[thread.id], Comment.clean(text) != nil else { return }
        replies[thread.id] = ""
        shell.reply(to: thread.id, page: page, body: text)
    }
}
