import SwiftUI

/// Экран страницы по макету редактора: надзаголовок, заголовок, блоки.
struct PageScreen: View {
    @State private var showsIcon = false
    @State private var iconText = ""
    @State private var showsBacklinks = false
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

    private var iconButton: some View {
        Button {
            iconText = page?.emoji ?? ""
            showsIcon = true
        } label: {
            if let emoji = page?.emoji {
                Text(emoji).font(.system(size: 34))
            } else {
                Label("Добавить значок", systemImage: "face.smiling")
                    .font(.system(size: 12))
                    .foregroundColor(Tokens.muted)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .popover(isPresented: $showsIcon, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Значок страницы").font(.system(size: 13, weight: .semibold))
                TextField(L("Emoji"), text: $iconText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(applyIcon)
                HStack {
                    Button(L("Эмодзи…")) { NSApp.orderFrontCharacterPalette(nil) }.buttonStyle(NotesButtonStyle())
                    Button(L("Готово"), action: applyIcon).buttonStyle(NotesButtonStyle(kind: .primary))
                }
                if page?.emoji != nil {
                    Button(L("Убрать значок")) {
                        shell.setIcon(editor.pageID, page?.isFolder == true ? Page.folderIcon : nil)
                        showsIcon = false
                    }
                    .buttonStyle(NotesButtonStyle(kind: .plain))
                }
            }
            .padding(14)
        }
    }

    private func applyIcon() {
        // Только один символ: значок, а не подпись.
        if let first = iconText.trimmingCharacters(in: .whitespaces).first { shell.setIcon(editor.pageID, String(first)) }
        showsIcon = false
    }

    private var backlinksPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Обратные ссылки").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
            if shell.backlinks.isEmpty {
                Text("На эту страницу пока никто не ссылается.").font(.system(size: 12)).foregroundColor(Tokens.muted)
            }
            ForEach(shell.backlinks) { link in
                Button {
                    showsBacklinks = false
                    shell.openPage(link.pageID, block: link.blockID)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.title.isEmpty ? L("Без названия") : link.title).font(.system(size: 13, weight: .semibold))
                        Text(link.text).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let path = shell.path(of: editor.pageID).map(\.title)
                Eyebrow(text: path.isEmpty ? (page?.isFolder == true ? L("Папка") : L("Страница")) : path.joined(separator: " / "))
                iconButton
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
                    ForEach(shell.tagsOf(page: editor.pageID)) { tag in
                        TagChip(tag: tag)
                            .contextMenu { Button("Снять тег") { shell.toggleTag(tag.id, on: editor.pageID) } }
                    }
                    TagPickerButton(page: editor.pageID)
                    Button {
                        shell.reloadBacklinks(for: editor.pageID)
                        showsBacklinks = true
                    } label: { Label("Обратные ссылки", systemImage: "arrow.up.right") }
                    .buttonStyle(NotesButtonStyle(kind: .plain))
                    .popover(isPresented: $showsBacklinks, arrowEdge: .bottom) { backlinksPopover }
            Menu {
                        ForEach(Array(EditorAction.slashItems.enumerated()), id: \.offset) { _, item in
                            Button(item.title) { editor.controller.run(item.action) }
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
