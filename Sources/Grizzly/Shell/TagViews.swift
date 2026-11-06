import SwiftUI

struct TagChip: View {
    let tag: Tag
    var body: some View {
        Chip(text: tag.name, colors: Tokens.swatch(tag.color) ?? (Tokens.soft, Tokens.ink))
    }
}

/// Теги страницы: отметка, поиск и создание по вводу, как свойство «Выбор» в Notion.
struct TagPickerButton: View {
    @EnvironmentObject private var shell: ShellModel
    let page: UUID
    @State private var open = false
    @State private var query = ""

    private var assigned: Set<UUID> { Set(shell.pageTags[page] ?? []) }
    private var matches: [Tag] {
        let key = Tag.key(query)
        return key.isEmpty ? shell.tags : shell.tags.filter { Tag.key($0.name).contains(key) }
    }
    private var canCreate: Bool {
        let key = Tag.key(query)
        return !key.isEmpty && !shell.tags.contains { Tag.key($0.name) == key }
    }

    var body: some View {
        Button { open = true } label: { Label("Тег", systemImage: "tag") }
            .buttonStyle(NotesButtonStyle(kind: .plain))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L("Найти или создать тег"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(matches) { tag in
                                Button { shell.toggleTag(tag.id, on: page) } label: {
                                    HStack {
                                        Image(systemName: assigned.contains(tag.id) ? "checkmark.square.fill" : "square")
                                            .foregroundColor(assigned.contains(tag.id) ? Tokens.accent : Tokens.muted)
                                        TagChip(tag: tag)
                                        Spacer()
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if canCreate {
                                Button(action: submit) {
                                    Label(String(format: L("Создать «%@»"), query.trimmingCharacters(in: .whitespaces)), systemImage: "plus")
                                        .padding(.vertical, 3)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if matches.isEmpty && !canCreate {
                                Text("Тегов пока нет").foregroundColor(Tokens.muted).font(.system(size: 12))
                            }
                        }
                    }
                    .frame(height: 200)
                }
                .padding(12)
                .frame(width: 260)
            }
    }

    private func submit() {
        guard !Tag.key(query).isEmpty else { return }
        shell.addTag(named: query, to: page)
        query = ""
    }
}

/// Все страницы с тегом.
struct TagScreen: View {
    @EnvironmentObject private var shell: ShellModel
    let id: UUID
    @State private var name = ""

    private var tag: Tag? { shell.tags.first { $0.id == id } }
    private var pages: [Page] { shell.pages.filter { shell.pageTags[$0.id]?.contains(id) == true } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Тег"))
                TextField(L("Название"), text: $name)
                    .textFieldStyle(.plain)
                    .font(Tokens.titleFont())
                    .padding(.top, 8)
                    .padding(.bottom, 9)
                    .onSubmit { shell.renameTag(id, to: name) }
                    .accessibilityLabel(Text("Название тега"))
                Text(String(format: L("Страниц: %d"), pages.count))
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                HStack(spacing: 9) {
                    Button(L("Переименовать")) { shell.renameTag(id, to: name) }.buttonStyle(NotesButtonStyle())
                    Menu(L("Цвет")) {
                        Button(L("Обычный")) { shell.setTagColor(id, nil) }
                        ForEach(BlockTextStyle.colors, id: \.name) { c in
                            Button(NSLocalizedString(c.title, comment: "")) { shell.setTagColor(id, c.name) }
                        }
                    }
                    .fixedSize()
                    Button { shell.deleteTag(id) } label: { Text("Удалить тег").foregroundColor(Tokens.danger) }
                        .buttonStyle(NotesButtonStyle())
                }
                .padding(.bottom, 16)
                VStack(spacing: 0) {
                    if pages.isEmpty {
                        Text("На страницах этого тега пока нет.")
                            .foregroundColor(Tokens.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(pages) { page in
                        RecentRow(page: page, parents: shell.path(of: page.id).map(\.title)) { shell.openPage(page.id) }
                    }
                }
                .padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
        .onAppear { name = tag?.name ?? "" }
        .onChange(of: id) { _ in name = tag?.name ?? "" }
    }
}
