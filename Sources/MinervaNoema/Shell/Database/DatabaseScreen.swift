import AppKit
import SwiftUI

/// Экран базы по макету: надзаголовок, заголовок, кнопки, вкладки представлений, таблица.
struct DatabaseScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel
    @State private var title = ""
    @State private var showsFilter = false
    @State private var showsSort = false
    @State private var showsViewSettings = false
    @State private var showsProperties = false
    @State private var bulkProperty: PropertyDefinition?

    private var page: Page? { shell.pageTree.page(model.pageID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L(model.isEmbedded ? "Встроенное представление" : "База данных"))
                if model.isEmbedded {
                    Text(page?.title.isEmpty == false ? page?.title ?? "" : L("Без названия"))
                        .font(Tokens.titleFont(28))
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                } else {
                    TextField("Без названия", text: $title)
                        .textFieldStyle(.plain)
                        .font(Tokens.titleFont())
                        .accessibilityLabel(Text("Название базы"))
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .onChange(of: title) { _, new in if new != page?.title { shell.rename(model.pageID, to: new) } }
                }
                Text(L("Записей: %d", model.total)).font(.system(size: 14)).foregroundColor(Tokens.muted).padding(.bottom, 18)
                toolbar
                if !model.isEmbedded { tabs.padding(.top, 14) }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 28)
            if !model.selection.isEmpty, kind == DatabaseView.tableKind { bulkBar }
            content
        }
        .onAppear {
            title = page?.title ?? ""
            model.reload()
        }
        .sheet(isPresented: $showsProperties) { PropertiesSheet(model: model) }
        .sheet(item: $bulkProperty) { BulkEditSheet(model: model, property: $0) }
    }

    private var kind: String { model.activeView?.kind ?? DatabaseView.tableKind }

    @ViewBuilder private var content: some View {
        switch kind {
        case DatabaseView.boardKind: BoardView(model: model)
        case DatabaseView.listKind: ListKindView(model: model)
        case DatabaseView.calendarKind: CalendarKindView(model: model)
        case DatabaseView.galleryKind: GalleryView(model: model)
        default: table
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            if model.templates.isEmpty {
                Button { model.createRecord() } label: { Label("Запись", systemImage: "plus") }
                    .buttonStyle(NotesButtonStyle(kind: .primary))
            } else {
                Menu {
                    Button("Пустая запись") { model.createRecord() }
                    Divider()
                    ForEach(model.templates) { template in
                        Button(template.name) { model.createRecord(from: template) }
                    }
                } label: { Label("Запись", systemImage: "plus") }
                .fixedSize()
            }
            Button { showsFilter = true } label: {
                Label(model.state.filter.ruleCount > 0 ? L("Фильтр (%d)", model.state.filter.ruleCount) : L("Фильтр"), systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(NotesButtonStyle())
            .popover(isPresented: $showsFilter, arrowEdge: .bottom) { FilterPopover(model: model) }
            Button { showsSort = true } label: {
                Label(model.state.sorts.isEmpty ? L("Сортировка") : L("Сортировка (%d)", model.state.sorts.count), systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(NotesButtonStyle())
            .popover(isPresented: $showsSort, arrowEdge: .bottom) { SortPopover(model: model) }
            Button { showsProperties = true } label: { Label("Свойства", systemImage: "slider.horizontal.3") }
                .buttonStyle(NotesButtonStyle())
            Button { showsViewSettings = true } label: { Label("Вид", systemImage: "rectangle.3.group") }
                .buttonStyle(NotesButtonStyle())
                .popover(isPresented: $showsViewSettings, arrowEdge: .bottom) { ViewSettingsPopover(model: model) }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(model.views) { view in
                let active = view.id == model.activeView?.id
                Button { model.selectView(view.id) } label: {
                    Text(view.name)
                        .font(.system(size: 14, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? Tokens.accent : Tokens.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().fill(active ? Tokens.accent : .clear).frame(height: 2), alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Переименовать…") { renameView(view) }
                    Button("Удалить представление") { deleteView(view) }.disabled(model.views.count < 2)
                }
            }
            Menu {
                ForEach(DatabaseView.knownKinds, id: \.self) { kind in
                    Button(ViewKindTitle.title(kind)) { addView(kind) }
                }
            } label: { Image(systemName: "plus").font(.system(size: 11)) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Новое представление"))
            .accessibilityLabel(Text("Новое представление"))
            Spacer()
        }
        .overlay(Rectangle().fill(Tokens.line).frame(height: 1), alignment: .bottom)
    }

    private func addView(_ kind: String) {
        let state = model.state
        let same = model.views.filter { $0.kind == kind }.count
        let name = same == 0 ? ViewKindTitle.title(kind) : "\(ViewKindTitle.title(kind)) \(same + 1)"
        let id = UUID()
        model.perform { [store = model.store, databaseID = model.databaseID] in
            try await store.createView(database: databaseID, name: name, kind: kind, state: state, id: id)
        }
        model.activeViewID = id
    }

    private func renameView(_ view: DatabaseView) {
        guard let name = PromptAlert.ask(L("Название представления"), value: view.name) else { return }
        model.perform { [store = model.store] in try await store.renameView(view.id, to: name) }
    }

    private func deleteView(_ view: DatabaseView) {
        if model.activeViewID == view.id { model.activeViewID = nil }
        model.perform { [store = model.store, databaseID = model.databaseID] in try await store.deleteView(view.id, database: databaseID) }
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text(L("Выбрано: %d", model.selection.count)).font(.system(size: 13, weight: .semibold))
            Menu("Изменить свойство") {
                ForEach(model.database?.properties.filter { $0.type != .title && $0.type.isKnown && !$0.type.isComputed } ?? []) { property in
                    Button(property.name) { bulkProperty = property }
                }
            }
            .fixedSize()
            Button("В корзину") { model.trashSelected() }.buttonStyle(NotesButtonStyle(kind: .plain))
            Button("Снять выбор") { model.selection = [] }.buttonStyle(NotesButtonStyle(kind: .plain))
            Spacer()
        }
        .padding(.horizontal, Tokens.contentPadding)
        .padding(.vertical, 6)
        .background(Tokens.soft)
    }

    // MARK: Таблица

    private static func width(_ type: PropertyType) -> CGFloat {
        switch type {
        case .title: return 280
        case .date: return 200
        case .checkbox: return 90
        case .multiSelect, .url, .createdTime, .editedTime, .person: return 200
        case .relation: return 240
        default: return 160
        }
    }

    private var table: some View {
        TopLeadingScroll(resetKey: model.visibleColumns.count) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: header) {
                    ForEach(model.sections) { section in
                        if let group = section.group {
                            GroupHeader(group: group, count: section.total, property: model.database?.property(group.property))
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        ForEach(section.rows) { row($0) }
                        if section.rows.count < section.total {
                            Button(L("Показать ещё (осталось %d)", section.total - section.rows.count)) { model.showMore(section.id) }
                                .buttonStyle(NotesButtonStyle(kind: .plain))
                                .padding(.top, 6)
                        }
                    }
                    footer
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.bottom, 30)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 30)
            ForEach(model.visibleColumns) { property in
                HStack(spacing: 5) {
                    Text(property.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Tokens.muted).lineLimit(1)
                    if let sort = model.state.sorts.first(where: { $0.property == property.id }) {
                        Image(systemName: sort.descending ? "arrow.down" : "arrow.up").font(.system(size: 9)).foregroundColor(Tokens.muted)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: Self.width(property.type), height: 32, alignment: .leading)
            }
        }
        .background(Tokens.paper)
        .overlay(Rectangle().fill(Tokens.line).frame(height: 1), alignment: .bottom)
    }

    private func row(_ row: RecordRow) -> some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { model.selection.contains(row.id) }, set: { on in
                if on { model.selection.insert(row.id) } else { model.selection.remove(row.id) }
            }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text("Выбрать запись"))
            .frame(width: 18, alignment: .leading)
            // Ручка: строку переносят за неё, чтобы перетаскивание не мешало правке ячеек.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(Tokens.muted)
                .frame(width: 12, height: 36)
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(object: "\(row.id.uuidString)|table" as NSString) }
                .help(model.canReorder ? L("Перетащите, чтобы изменить порядок") : L("Порядок задан сортировкой"))
                .accessibilityLabel(Text("Переместить запись"))
            ForEach(model.visibleColumns) { property in
                Group {
                    if property.type == .title { titleCell(row) } else {
                        PropertyCell(property: property, value: row.values[property.id]) { new in
                            model.setValue(pages: [row.id], property: property.id, value: new)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: Self.width(property.type), height: 36, alignment: .leading)
            }
        }
        .overlay(Rectangle().fill(Tokens.line).frame(height: 1), alignment: .bottom)
        .acceptsRecord { id, _ in model.reorder(record: id, before: row.id) }
        .contextMenu {
            Button("Открыть") { shell.openPage(row.id) }
            Button("Дублировать") { shell.duplicatePage(row.id) }
            Button("В корзину") { shell.trash(row.id) }
        }
    }

    private func titleCell(_ row: RecordRow) -> some View {
        HStack(spacing: 6) {
            if let icon = row.icon { Text(icon).font(.system(size: 13)) }
            CommitField(value: row.title, placeholder: L("Без названия"), bold: true) { new in
                model.setTitle(row.id, new)
                shell.rename(row.id, to: new)
            }
            // Запись — обычная страница: кнопка открывает её в редакторе.
            Button { shell.openPage(row.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)) }
                .buttonStyle(.plain)
                .foregroundColor(Tokens.muted)
                .help(L("Открыть как страницу"))
                .accessibilityLabel(Text("Открыть как страницу"))
        }
    }

    @ViewBuilder private var footer: some View {
        if model.rows.isEmpty {
            Text(model.state.filter.ruleCount > 0 ? "Под фильтр не подходит ни одна запись." : "Записей пока нет. Нажмите «Запись».")
                .font(.system(size: 13))
                .foregroundColor(Tokens.muted)
                .padding(.vertical, 18)
                .padding(.leading, 30)
        }
    }
}

/// Простой запрос строки и подтверждение: системные окна не требуют отдельного экрана.
enum PromptAlert {
    @MainActor
    static func ask(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Готово"))
        alert.addButton(withTitle: L("Отмена"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let clean = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    @MainActor
    static func confirm(_ title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Отмена"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
