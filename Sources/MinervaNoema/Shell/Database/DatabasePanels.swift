import SwiftUI

// MARK: Фильтр

struct FilterPopover: View {
    @ObservedObject var model: DatabaseModel
    /// Черновик: следующая правка строится на предыдущей, даже если та ещё записывается.
    @State private var draft: FilterGroup?

    var body: some View {
        ScrollView {
            FilterGroupEditor(group: draft ?? model.state.filter, properties: model.database?.properties ?? [], depth: 0) { new in
                draft = new
                model.updateState { $0.filter = new }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 620, height: 340)
    }
}

/// Группа правил. Вложенность — один уровень: этого хватает для И/ИЛИ и остаётся понятным.
struct FilterGroupEditor: View {
    let group: FilterGroup
    let properties: [PropertyDefinition]
    let depth: Int
    let onChange: (FilterGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Условия", selection: Binding(get: { group.mode }, set: { mode in
                var next = group
                next.mode = mode
                onChange(next)
            })) {
                Text("Все условия (И)").tag(FilterMode.and)
                Text("Любое условие (ИЛИ)").tag(FilterMode.or)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            ForEach(Array(group.items.enumerated()), id: \.offset) { index, node in
                HStack(alignment: .top, spacing: 6) {
                    switch node {
                    case .rule(let rule):
                        FilterRuleEditor(rule: rule, properties: properties) { replace(index, .rule($0)) }
                    case .group(let inner):
                        FilterGroupEditor(group: inner, properties: properties, depth: depth + 1) { replace(index, .group($0)) }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.soft))
                    }
                    Spacer(minLength: 0)
                    Button { remove(index) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundColor(Tokens.muted)
                        .help(L("Убрать условие"))
                        .accessibilityLabel(Text("Убрать условие"))
                }
            }
            HStack(spacing: 8) {
                Button("Добавить условие") { add(group: false) }.buttonStyle(NotesButtonStyle(kind: .plain))
                if depth == 0 { Button("Добавить группу") { add(group: true) }.buttonStyle(NotesButtonStyle(kind: .plain)) }
            }
        }
    }

    private func replace(_ index: Int, _ node: FilterNode) {
        var next = group
        next.items[index] = node
        onChange(next)
    }

    private func remove(_ index: Int) {
        var next = group
        next.items.remove(at: index)
        onChange(next)
    }

    private func add(group asGroup: Bool) {
        guard let first = properties.first(where: { !FilterOp.available(for: $0.type).isEmpty }), let op = FilterOp.available(for: first.type).first else { return }
        let rule = FilterNode.rule(FilterRule(property: first.id, op: op, value: ""))
        var next = group
        next.items.append(asGroup ? .group(FilterGroup(mode: .or, items: [rule])) : rule)
        onChange(next)
    }
}

struct FilterRuleEditor: View {
    let rule: FilterRule
    let properties: [PropertyDefinition]
    let onChange: (FilterRule) -> Void

    private var property: PropertyDefinition? { properties.first { $0.id == rule.property } }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Свойство", selection: Binding(get: { rule.property }, set: { id in
                // Другой тип — другие операции и формат значения.
                let type = properties.first { $0.id == id }?.valueType ?? .text
                onChange(FilterRule(property: id, op: FilterOp.available(for: type).first ?? .isEmpty, value: ""))
            })) {
                ForEach(properties.filter { !FilterOp.available(for: $0.valueType).isEmpty }) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 140)
            if let property {
                Picker("Операция", selection: Binding(get: { rule.op }, set: { op in
                    var next = rule
                    next.op = op
                    onChange(next)
                })) {
                    ForEach(FilterOp.available(for: property.valueType), id: \.self) { Text($0.title(for: property.valueType)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                if rule.op.needsValue { valueEditor(property) }
            }
        }
    }

    private func set(_ value: String) {
        var next = rule
        next.value = value
        onChange(next)
    }

    @ViewBuilder private func valueEditor(_ property: PropertyDefinition) -> some View {
        switch property.valueType {
        case .date, .createdTime, .editedTime:
            DatePicker("Дата", selection: Binding(get: {
                (LocalDate(iso: rule.value) ?? LocalDate(date: Date(), in: .current)).date(in: .current)
            }, set: { set(LocalDate(date: $0, in: .current).iso) }), displayedComponents: [.date])
            .labelsHidden()
            .onAppear { if LocalDate(iso: rule.value) == nil { set(LocalDate(date: Date(), in: .current).iso) } }
        case .status, .select, .multiSelect:
            Picker("Вариант", selection: Binding(get: { UUID(uuidString: rule.value) }, set: { set($0?.uuidString ?? "") })) {
                Text("Выберите").tag(UUID?.none)
                ForEach(property.options) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden()
            .frame(width: 150)
        default:
            // Запрос — по Return или уходу из поля, а не на каждую букву.
            CommitField(value: rule.value, placeholder: L("Значение")) { set($0) }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tokens.line))
                .frame(width: 150)
        }
    }
}

// MARK: Сортировка

struct SortPopover: View {
    @ObservedObject var model: DatabaseModel

    private var properties: [PropertyDefinition] { model.database?.properties.filter(\.type.isKnown) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.state.sorts.isEmpty { Text("Порядок добавления записей.").font(.system(size: 12)).foregroundColor(Tokens.muted) }
            ForEach(Array(model.state.sorts.enumerated()), id: \.offset) { index, sort in
                HStack(spacing: 6) {
                    Picker("Свойство", selection: Binding(get: { sort.property }, set: { id in
                        model.updateState { if $0.sorts.indices.contains(index) { $0.sorts[index].property = id } }
                    })) {
                        ForEach(properties) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Picker("Направление", selection: Binding(get: { sort.descending }, set: { value in
                        model.updateState { if $0.sorts.indices.contains(index) { $0.sorts[index].descending = value } }
                    })) {
                        Text("По возрастанию").tag(false)
                        Text("По убыванию").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Button {
                        model.updateState { if $0.sorts.indices.contains(index) { $0.sorts.remove(at: index) } }
                    } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundColor(Tokens.muted)
                    .accessibilityLabel(Text("Убрать сортировку"))
                }
            }
            Button("Добавить сортировку") {
                guard let first = properties.first else { return }
                model.updateState { $0.sorts.append(SortRule(property: first.id)) }
            }
            .buttonStyle(NotesButtonStyle(kind: .plain))
        }
        .padding(14)
        .frame(width: 400)
    }
}

// MARK: Свойства

struct PropertiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel
    @State private var newName = ""
    @State private var newType = PropertyType.text
    @State private var relationTarget: UUID?
    @State private var twoWay = true
    @State private var rollupRelation: UUID?
    @State private var rollupProperty: UUID?
    @State private var rollupAggregate: RollupAggregate?
    /// Базы, на которые смотрят связи этой базы: для выбора источника свёртки и подписей.
    @State private var related: [UUID: Database] = [:]

    private var relations: [PropertyDefinition] { model.database?.properties.filter { $0.type == .relation } ?? [] }

    private var rollupSource: PropertyDefinition? {
        guard let relation = relations.first(where: { $0.id == rollupRelation }), let target = relation.config.target else { return nil }
        return related[target]?.property(rollupProperty ?? UUID())
    }

    private func rollupCandidates(_ relation: UUID?) -> [PropertyDefinition] {
        guard let target = relations.first(where: { $0.id == relation })?.config.target else { return [] }
        return related[target]?.properties.filter { $0.type != .editedTime && !RollupAggregate.available(for: $0.valueType).isEmpty } ?? []
    }

    /// Подпись свёртки: связь, свойство и агрегат; пропавший источник виден сразу.
    private func rollupSummary(_ property: PropertyDefinition) -> String {
        guard let relation = model.database?.property(property.config.rollupRelation ?? UUID()), let target = relation.config.target,
              let source = related[target]?.property(property.config.rollupProperty ?? UUID()), let aggregate = property.config.aggregate else {
            return L("Свёртка: источник удалён")
        }
        return L("Свёртка: %@ → %@ · %@", relation.name, source.name, aggregate.title)
    }

    private func loadRelated() async {
        var out: [UUID: Database] = [:]
        for target in Set(relations.compactMap(\.config.target)) {
            if let base = try? await model.store.database(target) { out[target] = base }
        }
        related = out
    }
    @State private var change: TypeChange?

    /// Базы пространства для связи, включая эту: связь базы с самой собой допустима.
    private var databases: [(id: UUID, title: String)] {
        shell.databaseIndex.compactMap { page, id in
            shell.pages.first { $0.id == page }.map { (id: id, title: $0.title.isEmpty ? L("Без названия") : $0.title) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func databaseTitle(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return databases.first { $0.id == id }?.title
    }

    /// Подпись связи: куда смотрит и есть ли обратная сторона.
    private func relationSummary(_ property: PropertyDefinition) -> String {
        let target = databaseTitle(property.config.target) ?? L("база недоступна")
        let side = property.config.pair == nil ? L("односторонняя") : (property.config.isBackSide ? L("обратная сторона") : L("двусторонняя"))
        return L("Связь → %@ · %@", target, side)
    }

    struct TypeChange: Identifiable {
        var property: PropertyDefinition
        var to: PropertyType
        var preview: TypeChangePreview
        var id: UUID { property.id }
    }

    private var columns: [ColumnState] { model.state.orderedColumns(model.database?.properties ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Свойства базы").font(.system(size: 17, weight: .semibold))
            Text("Порядок и видимость столбцов относятся к текущему представлению.").font(.system(size: 12)).foregroundColor(Tokens.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(columns.enumerated()), id: \.element.property) { index, column in
                        if let property = model.database?.property(column.property) {
                            propertyRow(property, column: column, index: index)
                            Rectangle().fill(Tokens.line).frame(height: 1)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Новое свойство", text: $newName).textFieldStyle(.roundedBorder)
                Picker("Тип", selection: $newType) {
                    ForEach(PropertyType.creatable, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                Button("Добавить", action: addProperty)
                    .buttonStyle(NotesButtonStyle())
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || (newType == .relation && relationTarget == nil)
                              || (newType == .rollup && (rollupSource == nil || rollupAggregate == nil)))
            }
            if newType == .relation {
                HStack(spacing: 8) {
                    Picker("Записи базы", selection: $relationTarget) {
                        Text("Выберите базу").tag(UUID?.none)
                        ForEach(databases, id: \.id) { Text($0.title).tag(UUID?.some($0.id)) }
                    }
                    .frame(width: 300)
                    Toggle("Показывать связь в выбранной базе", isOn: $twoWay)
                        .help(L("Без обратной связи выбранная база не получит нового свойства."))
                }
            }
            if newType == .rollup {
                if relations.isEmpty {
                    Text("Сначала добавьте связь: свёртка считает значения связанных записей.").font(.system(size: 12)).foregroundColor(Tokens.muted)
                } else {
                    HStack(spacing: 8) {
                        Picker("Связь", selection: Binding(get: { rollupRelation }, set: { rollupRelation = $0; rollupProperty = nil; rollupAggregate = nil })) {
                            Text("Выберите").tag(UUID?.none)
                            ForEach(relations) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .frame(width: 190)
                        Picker("Свойство", selection: Binding(get: { rollupProperty }, set: { rollupProperty = $0; rollupAggregate = nil })) {
                            Text("Выберите").tag(UUID?.none)
                            ForEach(rollupCandidates(rollupRelation)) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .frame(width: 190)
                        Picker("Считать", selection: $rollupAggregate) {
                            Text("Выберите").tag(RollupAggregate?.none)
                            ForEach(rollupSource.map { RollupAggregate.available(for: $0.valueType) } ?? [], id: \.self) { Text($0.title).tag(RollupAggregate?.some($0)) }
                        }
                        .frame(width: 210)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(NotesButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .sheet(item: $change) { TypeChangeSheet(model: model, change: $0) }
        .task(id: relations.map(\.id)) { await loadRelated() }
    }

    private func propertyRow(_ property: PropertyDefinition, column: ColumnState, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { column.visible }, set: { model.setColumnVisible(property.id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(property.type == .title)
                    .help(L("Показывать столбец"))
                    .accessibilityLabel(Text("Показывать столбец"))
                CommitField(value: property.name, placeholder: L("Без названия"), bold: true) { name in
                    let clean = name.trimmingCharacters(in: .whitespaces)
                    guard !clean.isEmpty else { return }
                    model.perform { [store = model.store] in try await store.renameProperty(property.id, to: clean) }
                }
                if property.type == .relation {
                    Text(relationSummary(property)).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1)
                } else if property.type == .rollup {
                    Text(rollupSummary(property)).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1)
                } else if !PropertyType.convertible.contains(property.type) {
                    Text(property.type.title).font(.system(size: 12)).foregroundColor(Tokens.muted)
                } else {
                    Menu(property.type.title) {
                        ForEach(PropertyType.convertible.filter { $0 != property.type }, id: \.self) { type in
                            Button(type.title) { previewChange(property, to: type) }
                        }
                    }
                    .fixedSize()
                }
                Button { model.moveColumn(property.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).disabled(index == 0).accessibilityLabel(Text("Выше"))
                Button { model.moveColumn(property.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).disabled(index == columns.count - 1).accessibilityLabel(Text("Ниже"))
                if property.type != .title {
                    Button { deleteProperty(property) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundColor(Tokens.danger)
                        .help(L("Удалить свойство"))
                        .accessibilityLabel(Text("Удалить свойство"))
                }
            }
            if property.type.usesOptions { OptionsEditor(model: model, property: property).padding(.leading, 26) }
        }
    }

    private func addProperty() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let type = newType
        newName = ""
        if type == .rollup, let relation = rollupRelation, let source = rollupSource, let aggregate = rollupAggregate {
            rollupRelation = nil
            rollupProperty = nil
            rollupAggregate = nil
            model.perform { [store = model.store, databaseID = model.databaseID] in
                try await store.addRollup(database: databaseID, name: name, relation: relation, property: source.id, aggregate: aggregate,
                                          id: UUID(), now: SystemClock().nowMillis())
            }
            return
        }
        if type == .relation, let target = relationTarget {
            // Обратная сторона называется как эта база: так в целевой базе видно, откуда связь.
            let pairName = shell.pages.first { $0.id == model.pageID }.map { $0.title.isEmpty ? L("Без названия") : $0.title } ?? L("Связь")
            let both = twoWay
            model.perform { [store = model.store, databaseID = model.databaseID] in
                try await store.addRelation(database: databaseID, name: name, target: target, twoWay: both, pairName: pairName,
                                            id: UUID(), pairID: UUID(), now: SystemClock().nowMillis())
            }
            return
        }
        model.perform { [store = model.store, databaseID = model.databaseID] in
            try await store.addProperty(database: databaseID, name: name, type: type, id: UUID(), now: SystemClock().nowMillis())
        }
    }

    private func previewChange(_ property: PropertyDefinition, to type: PropertyType) {
        model.perform { [store = model.store] in
            let preview = try await store.previewTypeChange(property: property.id, to: type, zone: TimeZone.current.identifier)
            change = TypeChange(property: property, to: type, preview: preview)
        }
    }

    /// Диалог вне очереди модели: пока он открыт, остальные действия экрана не стоят.
    private func deleteProperty(_ property: PropertyDefinition) {
        let store = model.store
        Task { @MainActor in
            let count = (try? await store.valueCount(property: property.id)) ?? 0
            // У двусторонней связи значения не пропадают: их сохраняет парное свойство.
            let detail = property.type == .relation && property.config.pair != nil
                ? L("Связи сохранятся у парного свойства в базе «%@», оно станет односторонним.", databaseTitle(property.config.target) ?? "")
                : L("Значений будет удалено: %d. Это действие нельзя отменить.", count)
            guard PromptAlert.confirm(L("Удалить свойство «%@»?", property.name), detail: detail, action: L("Удалить")) else { return }
            model.perform { try await store.deleteProperty(property.id) }
        }
    }
}

struct OptionsEditor: View {
    @ObservedObject var model: DatabaseModel
    let property: PropertyDefinition
    @State private var newOption = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(property.options.enumerated()), id: \.element.id) { index, option in
                HStack(spacing: 8) {
                    Chip(text: " ", colors: Tokens.swatch(option.color) ?? (Tokens.soft, Tokens.ink))
                    CommitField(value: option.name, placeholder: L("Без названия")) { name in
                        let clean = name.trimmingCharacters(in: .whitespaces)
                        guard !clean.isEmpty else { return }
                        model.perform { [store = model.store] in try await store.updateOption(option.id, name: clean, color: option.color) }
                    }
                    Menu("Цвет") {
                        Button("Без цвета") { setColor(option, nil) }
                        ForEach(BlockTextStyle.colors, id: \.name) { color in
                            Button(L(color.title)) { setColor(option, color.name) }
                        }
                    }
                    .fixedSize()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).disabled(index == 0).accessibilityLabel(Text("Выше"))
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).disabled(index == property.options.count - 1).accessibilityLabel(Text("Ниже"))
                    Button { delete(option) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundColor(Tokens.muted)
                        .accessibilityLabel(Text("Удалить вариант"))
                }
                .font(.system(size: 12))
            }
            HStack(spacing: 6) {
                TextField("Новый вариант", text: $newOption)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(add)
                Button("Добавить", action: add).buttonStyle(NotesButtonStyle(kind: .plain)).disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func setColor(_ option: PropertyOption, _ color: String?) {
        model.perform { [store = model.store] in try await store.updateOption(option.id, name: option.name, color: color) }
    }

    private func move(_ index: Int, by delta: Int) {
        var ids = property.options.map(\.id)
        ids.swapAt(index, index + delta)
        model.perform { [store = model.store] in try await store.reorderOptions(property: property.id, ordered: ids) }
    }

    private func add() {
        let name = newOption.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newOption = ""
        model.perform { [store = model.store] in try await store.addOption(property: property.id, name: name, color: nil, id: UUID()) }
    }

    private func delete(_ option: PropertyOption) {
        let store = model.store
        Task { @MainActor in
            let count = (try? await store.valueCount(option: option.id)) ?? 0
            if count > 0 {
                guard PromptAlert.confirm(L("Удалить вариант «%@»?", option.name),
                                          detail: L("Его снимут с записей: %d. Сами записи останутся.", count),
                                          action: L("Удалить")) else { return }
            }
            model.perform { try await store.deleteOption(option.id) }
        }
    }
}

/// Предварительный результат смены типа: ровно то, что будет записано.
struct TypeChangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DatabaseModel
    let change: PropertiesSheet.TypeChange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("«%@»: %@ → %@", change.property.name, change.property.type.title, change.to.title)).font(.system(size: 17, weight: .semibold))
            Text(L("Значений: %d, не преобразуются: %d.", change.preview.total, change.preview.failed)).font(.system(size: 13))
            if change.preview.failed > 0 {
                Text("Непреобразованные значения не удаляются: они остаются как есть, выделены в ячейке и вернутся при обратной смене типа.")
                    .font(.system(size: 12))
                    .foregroundColor(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !change.preview.newOptions.isEmpty {
                Text(L("Новые варианты: %@", change.preview.newOptions.joined(separator: ", "))).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(3)
            }
            ForEach(Array(change.preview.samples.enumerated()), id: \.offset) { _, sample in
                HStack {
                    Text(sample.from).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundColor(Tokens.muted)
                    Text(sample.to ?? L("останется как есть"))
                        .foregroundColor(sample.to == nil ? Tokens.danger : Tokens.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Сменить тип") {
                    dismiss()
                    model.perform { [store = model.store] in
                        try await store.changePropertyType(change.property.id, to: change.to, zone: TimeZone.current.identifier, ids: RandomIDs(), now: SystemClock().nowMillis())
                    }
                }
                .buttonStyle(NotesButtonStyle(kind: .primary))
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
    }
}

/// Одно значение сразу для выбранных записей: применяется одной транзакцией.
struct BulkEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DatabaseModel
    let property: PropertyDefinition
    @State private var value: PropertyValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("«%@» для записей: %d", property.name, model.selection.count)).font(.system(size: 15, weight: .semibold))
            PropertyCell(property: property, value: value) { value = $0 }
                .environment(\.liveCommit, true)
                .frame(minHeight: 24)
            HStack {
                // Очистка — отдельное действие с подтверждением: пустое поле не должно стирать значения.
                Button("Очистить у всех") {
                    guard PromptAlert.confirm(L("Очистить «%@»?", property.name),
                                              detail: L("Значение будет удалено у записей: %d.", model.selection.count),
                                              action: L("Очистить")) else { return }
                    model.setValue(pages: Array(model.selection), property: property.id, value: nil)
                    dismiss()
                }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Применить") {
                    model.setValue(pages: Array(model.selection), property: property.id, value: value)
                    dismiss()
                }
                .buttonStyle(NotesButtonStyle(kind: .primary))
                .disabled(value == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
