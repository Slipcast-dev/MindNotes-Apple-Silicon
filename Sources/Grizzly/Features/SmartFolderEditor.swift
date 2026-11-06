import SwiftUI

/// What the settings sheet of a smart folder is opened for: a new folder (inside `parentID`) or an existing one.
struct SmartFolderRequest: Identifiable {
    let id = UUID()
    var folderID: UUID?
    var parentID: UUID?
}

/// The symbol of a smart folder: a folder with a gear, like the smart folders of Apple Notes.
enum SmartFolderIcon {
    static let symbol = "folder.badge.gearshape"
}

/// Settings of a smart folder: its name, the tags and file types that bring a file into it, and the sort order.
struct SmartFolderEditor: View {
    let request: SmartFolderRequest
    var onSaved: (UUID) -> Void

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var name = ""
    @State private var rule = SmartRule()
    @State private var tagInput = ""
    @State private var error: String?
    @State private var loaded = false

    private var isNew: Bool { request.folderID == nil }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmedName.isEmpty && !rule.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: SmartFolderIcon.symbol).font(.system(size: 24, weight: .light)).foregroundColor(theme.accent)
                Text(isNew ? "Новая смарт-папка" : "Настройки смарт-папки").font(AppFont.title3.weight(.semibold))
            }
            .padding(.bottom, 4)
            Text("Файл попадает в смарт-папку сам, как только в его тексте появляется нужный #тег или если он нужного типа. Сами файлы остаются на своих местах.")
                .font(AppFont.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Название") {
                        TextField("Название папки", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                    }
                    section("Теги") { tagsSection }
                    section("Типы файлов") { typesSection }
                    section("Сортировка") {
                        Picker("", selection: $rule.sort) {
                            Text("По названию").tag(SmartRule.Sort.name)
                            Text("По типу файла").tag(SmartRule.Sort.type)
                            Text("По дате открытия").tag(SmartRule.Sort.opened)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.trailing, 6)
            }

            Divider().padding(.top, 8)
            footer
                .padding(.top, 10)
        }
        .padding(18)
        .frame(width: 480, height: 560)
        .onAppear(perform: load)
        .onChange(of: name) { _ in error = nil }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(AppFont.caption.weight(.semibold)).foregroundColor(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        if !rule.tags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(rule.tags, id: \.self) { tag in
                    Button { rule.tags.removeAll { $0 == tag } } label: {
                        HStack(spacing: 4) {
                            Text("#" + tag).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .chip(on: true, theme: theme)
                    }
                    .buttonStyle(.plain)
                    .help("Убрать тег из условий")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 6) {
            TextField("Добавить тег…", text: $tagInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTag)
            Button("Добавить", action: addTag)
                .buttonStyle(.hoverFilled)
                .disabled(LibraryStore.cleanTag(tagInput).isEmpty)
        }
        let suggestions = library.allTags.filter { tag in !rule.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        if !suggestions.isEmpty {
            ScrollView {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button { rule.tags.append(tag) } label: {
                            Text("#" + tag).lineLimit(1).chip(on: false, theme: theme)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 84)
        }
        if rule.tags.count > 1 {
            Picker("", selection: $rule.matchAllTags) {
                Text("Со всеми тегами").tag(true)
                Text("С любым из тегов").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        if rule.tags.isEmpty {
            Text("Если теги не указаны, подойдут файлы любого содержания: выберите тип файла.")
                .font(AppFont.caption).foregroundColor(.secondary)
        }
    }

    private var typesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(FileType.allCases, id: \.rawValue) { type in
                    let on = rule.types.contains(type.rawValue)
                    Button {
                        if on { rule.types.removeAll { $0 == type.rawValue } } else { rule.types.append(type.rawValue) }
                    } label: {
                        Text(type.title).lineLimit(1).chip(on: on, theme: theme)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if rule.types.isEmpty {
                Text("Если типы не выбраны, подойдут файлы любого типа.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Group {
                if let error {
                    Text(error).foregroundColor(.red)
                } else if rule.isEmpty {
                    Text("Укажите хотя бы один тег или тип файла.").foregroundColor(.secondary)
                } else {
                    Text("Сейчас подходит файлов: \(library.smartMatchCount(rule))").foregroundColor(.secondary)
                }
            }
            .font(AppFont.caption)
            .lineLimit(2)
            Spacer()
            Button("Отмена") { dismiss() }
                .buttonStyle(.hoverFilled)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Создать" : "Сохранить", action: save)
                .buttonStyle(.hoverFilled)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let id = request.folderID, let folder = library.folder(id), let existing = folder.smart {
            name = folder.name
            rule = existing
        }
    }

    private func addTag() {
        let tag = LibraryStore.cleanTag(tagInput)
        tagInput = ""
        guard !tag.isEmpty, !rule.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        // A tag the library already knows keeps its spelling.
        rule.tags.append(library.allTags.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag)
    }

    private func save() {
        // Return in the tag field adds the tag; a tag typed but not added still counts when the sheet is confirmed.
        if !LibraryStore.cleanTag(tagInput).isEmpty { addTag() }
        guard canSave else { return }
        let parent = request.folderID.flatMap { library.folder($0)?.parentID } ?? request.parentID
        guard !library.folderExists(trimmedName, in: parent, ignoring: request.folderID) else {
            error = L("Папка с таким именем уже есть.")
            return
        }
        let id: UUID
        if let existing = request.folderID {
            library.updateSmartFolder(existing, name: trimmedName, rule: rule)
            id = existing
        } else {
            id = library.createSmartFolder(trimmedName, rule: rule, parent: request.parentID).id
        }
        onSaved(id)
        dismiss()
    }
}

private extension View {
    /// The capsule of a tag or a file type: filled with the accent color when chosen.
    func chip(on: Bool, theme: Theme) -> some View {
        self
            .font(AppFont.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(on ? .white : .primary)
            .background(Capsule().fill(on ? theme.accent : Color.primary.opacity(0.09)))
    }
}
