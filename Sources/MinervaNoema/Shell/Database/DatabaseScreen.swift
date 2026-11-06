import AppKit
import SwiftUI

/// Экран базы по макету: надзаголовок, заголовок, кнопки, вкладки представлений, таблица.
struct DatabaseScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel
    @State private var title = ""
    @State private var showsFilter = false
    @State private var showsSort = false
    @State private var showsProperties = false
    @State private var bulkProperty: PropertyDefinition?

    private var page: Page? { shell.pages.first { $0.id == model.pageID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("База данных"))
                TextField("Без названия", text: $title)
                    .textFieldStyle(.plain)
                    .font(Tokens.titleFont())
                    .accessibilityLabel(Text("Название базы"))
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .onChange(of: title) { if $0 != page?.title { shell.rename(model.pageID, to: $0) } }
                Text(L("Записей: %d", model.total)).font(.system(size: 14)).foregroundColor(Tokens.muted).padding(.bottom, 18)
                toolbar
                tabs.padding(.top, 14)
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 28)
            if !model.selection.isEmpty { bulkBar }
            table
        }
        .onAppear {
            title = page?.title ?? ""
            model.reload()
        }
        .sheet(isPresented: $showsProperties) { PropertiesSheet(model: model) }
        .sheet(item: $bulkProperty) { BulkEditSheet(model: model, property: $0) }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Button { model.createRecord() } label: { Label("Запись", systemImage: "plus") }
                .buttonStyle(NotesButtonStyle(kind: .primary))
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
            Button { addView() } label: { Image(systemName: "plus").font(.system(size: 11)).padding(8).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .foregroundColor(Tokens.muted)
                .help(L("Новое представление"))
                .accessibilityLabel(Text("Новое представление"))
            Spacer()
        }
        .overlay(Rectangle().fill(Tokens.line).frame(height: 1), alignment: .bottom)
    }

    private func addView() {
        let state = model.state
        let name = L("Таблица %d", model.views.count + 1)
        let id = UUID()
        model.perform { [store = model.store, databaseID = model.databaseID] in
            try await store.createView(database: databaseID, name: name, kind: DatabaseView.tableKind, state: state, id: id)
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
                ForEach(model.database?.properties.filter { $0.type != .title && $0.type.isKnown } ?? []) { property in
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
        case .multiSelect, .url: return 200
        default: return 160
        }
    }

    private var table: some View {
        // Двумерная прокрутка центрирует содержимое меньше себя, поэтому оно растянуто до размера области.
        GeometryReader { area in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section(header: header) {
                        ForEach(model.rows) { row($0) }
                        footer
                    }
                }
                .padding(.horizontal, Tokens.contentPadding)
                .padding(.bottom, 30)
                .frame(minWidth: area.size.width, minHeight: area.size.height, alignment: .topLeading)
            }
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
            .frame(width: 30, alignment: .leading)
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
        if model.rows.count < model.total {
            Button(L("Показать ещё (осталось %d)", model.total - model.rows.count)) { model.showMore() }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .padding(.top, 10)
        } else if model.rows.isEmpty {
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
