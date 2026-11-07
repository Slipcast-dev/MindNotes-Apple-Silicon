import SwiftUI

/// Выбор нового родителя страницы. Отдельное окно, а не подменю: в контекстном меню каждой строки дерева
/// подменю со всеми страницами строилось при каждой перерисовке и останавливало приложение.
struct MovePageSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    let page: Page
    @State private var query = ""
    @State private var targets: [Page] = []

    private var visible: [Page] {
        let key = SearchText.normalize(query.trimmingCharacters(in: .whitespaces))
        return key.isEmpty ? targets : targets.filter { SearchText.normalize($0.title).contains(key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Переместить в…").font(.system(size: 15, weight: .semibold)).padding([.horizontal, .top], 16)
            TextField(L("Найти страницу"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(16)
            Rectangle().fill(Tokens.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if page.parentID != nil, query.isEmpty {
                        row(title: L("В корень"), path: "") { move(to: nil) }
                    }
                    ForEach(visible) { target in
                        row(title: target.title.isEmpty ? L("Без названия") : target.title,
                            path: shell.path(of: target.id).map(\.title).joined(separator: " / ")) { move(to: target.id) }
                    }
                    if visible.isEmpty {
                        Text("Ничего не найдено. Попробуйте другой запрос.")
                            .foregroundColor(Tokens.muted)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                .padding(8)
            }
            .frame(height: 320)
            Rectangle().fill(Tokens.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(NotesButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 480)
        .background(Tokens.paper)
        .onAppear { targets = shell.moveTargets(for: page.id).filter { $0.id != page.parentID } }
    }

    private func move(to parent: UUID?) {
        dismiss()
        shell.move(page.id, toParent: parent)
    }

    private func row(title: String, path: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !path.isEmpty {
                    Text(path).font(.system(size: 11)).foregroundColor(Tokens.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
