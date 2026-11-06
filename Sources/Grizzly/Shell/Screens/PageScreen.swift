import SwiftUI

/// Экран страницы по макету редактора: надзаголовок, заголовок, блоки.
struct PageScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var editor: PageEditorModel
    @State private var title = ""

    private var page: Page? { shell.pages.first { $0.id == editor.pageID } }

    private var updatedLine: String {
        guard let page else { return "" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return String(format: L("Изменено · %@"), f.string(from: Date(timeIntervalSince1970: Double(page.updatedAt) / 1000)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let path = shell.path(of: editor.pageID).map(\.title)
                Eyebrow(text: path.isEmpty ? (page?.isFolder == true ? L("Папка") : L("Страница")) : path.joined(separator: " / "))
                TextField("Без названия", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Tokens.titleFont())
                    .accessibilityLabel(Text("Заголовок страницы"))
                    .padding(.top, 8)
                    .padding(.bottom, 9)
                    .onChange(of: title) { new in
                        if new != page?.title { shell.rename(editor.pageID, to: new) }
                    }
                Text(updatedLine)
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                HStack(spacing: 9) {
                    Menu {
                        ForEach(BlockKind.all, id: \.type) { kind in
                            Button(kind.title) { editor.insert(kind.type) }
                        }
                    } label: { Label("Блок", systemImage: "plus") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button { shell.createPage(parent: editor.pageID) } label: { Label("Подстраница", systemImage: "doc.badge.plus") }
                        .buttonStyle(NotesButtonStyle(kind: .plain))
                }
                Rectangle().fill(Tokens.line).frame(height: 1).padding(.vertical, 18)
                NativeBlockEditor(editor: editor).frame(height: editor.contentHeight)
                let kids = shell.children(of: editor.pageID)
                if !kids.isEmpty {
                    Text("Подстраницы").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 10)
                    ForEach(kids) { kid in
                        RecentRow(page: kid, parents: []) { shell.openPage(kid.id) }
                        Rectangle().fill(Tokens.line).frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: page?.fullWidth == true ? .infinity : Tokens.editorWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
        .onAppear { title = page?.title ?? "" }
    }
}
