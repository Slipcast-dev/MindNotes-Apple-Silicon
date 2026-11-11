import Foundation
import SwiftUI

extension PropertyType {
    var title: String {
        switch self {
        case .title: return L("Заголовок")
        case .text: return L("Текст")
        case .number: return L("Число")
        case .date: return L("Дата")
        case .checkbox: return L("Флажок")
        case .status: return L("Статус")
        case .select: return L("Выбор")
        case .multiSelect: return L("Множественный выбор")
        case .url: return L("Ссылка")
        case .person: return L("Человек")
        case .files: return L("Файлы и медиа")
        case .relation: return L("Связь")
        case .rollup: return L("Свёртка")
        case .formula: return L("Формула")
        case .createdTime: return L("Создано")
        case .editedTime: return L("Изменено")
        default: return rawValue
        }
    }
}

extension RollupAggregate {
    var title: String {
        switch self {
        case .count: return L("Количество записей")
        case .countValues: return L("Заполнено")
        case .countUnique: return L("Разных значений")
        case .countEmpty: return L("Пустых")
        case .percentEmpty: return L("Процент пустых")
        case .sum: return L("Сумма")
        case .average: return L("Среднее")
        case .median: return L("Медиана")
        case .min: return L("Минимум")
        case .max: return L("Максимум")
        case .range: return L("Размах")
        case .earliest: return L("Самая ранняя дата")
        case .latest: return L("Самая поздняя дата")
        case .dateRange: return L("Диапазон дат, дней")
        case .percentChecked: return L("Процент отмеченных")
        case .showOriginal: return L("Показать значения")
        default: return rawValue
        }
    }
}

extension FilterOp {
    func title(for type: PropertyType) -> String {
        let isDate = type == .date || type.isTimestamp
        switch self {
        case .contains: return type == .relation ? L("содержит запись") : L("содержит")
        case .notContains: return type == .relation ? L("не содержит запись") : L("не содержит")
        case .equals: return isDate ? L("в этот день") : L("равно")
        case .notEquals: return L("не равно")
        case .startsWith: return L("начинается с")
        case .less: return isDate ? L("раньше") : L("меньше")
        case .lessOrEqual: return isDate ? L("не позже") : L("не больше")
        case .greater: return isDate ? L("позже") : L("больше")
        case .greaterOrEqual: return isDate ? L("не раньше") : L("не меньше")
        case .isTrue: return L("отмечено")
        case .isFalse: return L("не отмечено")
        case .isEmpty: return L("пусто")
        case .isNotEmpty: return L("не пусто")
        default: return rawValue
        }
    }
}

/// Экран одной базы: чтение и запись идут последовательно, после каждого изменения записи читаются заново.
@MainActor
final class DatabaseModel: ObservableObject {
    static let pageSize = 100
    static let calendarLimit = 1000

    let store: SQLiteWorkspace
    let databaseID: UUID
    let pageID: UUID
    @Published private(set) var database: Database?
    @Published var activeViewID: UUID?
    @Published private(set) var rows: [RecordRow] = []
    @Published private(set) var total = 0
    /// Группы текущего вида: без группировки одна, с `group == nil`.
    @Published private(set) var sections: [RecordSection] = []
    /// Календарь: записи месяца и записи без даты.
    @Published private(set) var calendarRows: [RecordRow] = []
    /// Записей в видимых днях: больше предела означает, что показаны не все.
    @Published private(set) var calendarTotal = 0
    @Published private(set) var undated: RecordPage = RecordPage(rows: [], total: 0)
    @Published var month = LocalDate(date: Date(), in: .current).firstOfMonth
    /// Хронология: шкала растёт порциями при прокрутке; для какого вида и масштаба она построена.
    @Published private(set) var timelineWindow = TimelineWindow(scale: .week, anchor: LocalDate(date: Date(), in: .current))
    /// День, к которому экран должен прокрутить шкалу; экран сбрасывает его, когда прокрутил.
    @Published var timelineScrollTarget: LocalDate?
    private var timelineKey: String?
    @Published private(set) var templates: [PageTemplate] = []
    /// Справочник людей пространства: варианты ячеек «Человек» и группы доски.
    @Published private(set) var people: [Person] = []
    @Published var selection: Set<UUID> = []
    private var limits: [String: Int] = [:]
    private var embedded: EmbeddedView?
    private var chain: Task<Void, Never>?
    private let flush: () async throws -> Void
    private let pagesChanged: () async throws -> Void
    private let report: (String) -> Void

    /// Встроенное представление: состояние принадлежит блоку страницы, а не базе.
    struct EmbeddedView {
        var id: UUID
        var name: String
        var kind: String
        var state: DatabaseViewState
        var save: (String, DatabaseViewState) -> Void
    }

    init(store: SQLiteWorkspace, databaseID: UUID, pageID: UUID, embedded: EmbeddedView? = nil, flush: @escaping () async throws -> Void,
         pagesChanged: @escaping () async throws -> Void, report: @escaping (String) -> Void) {
        self.embedded = embedded
        self.store = store
        self.databaseID = databaseID
        self.pageID = pageID
        self.flush = flush
        self.pagesChanged = pagesChanged
        self.report = report
    }

    var isEmbedded: Bool { embedded != nil }

    /// Вид неизвестной версии хранится, но не показывается.
    var views: [DatabaseView] {
        if let embedded {
            return [DatabaseView(id: embedded.id, databaseID: databaseID, name: embedded.name, kind: embedded.kind, sortKey: "", state: embedded.state)]
        }
        return database?.views.filter { DatabaseView.knownKinds.contains($0.kind) } ?? []
    }
    var activeView: DatabaseView? { views.first { $0.id == activeViewID } ?? views.first }
    var state: DatabaseViewState { activeView?.state ?? DatabaseViewState() }

    var visibleColumns: [PropertyDefinition] {
        guard let database else { return [] }
        return state.orderedColumns(database.properties).filter(\.visible).compactMap { database.property($0.property) }
    }

    /// Изменение и последующее чтение. Ошибка видна пользователю, а экран показывает то, что реально записано.
    func perform(_ body: @escaping () async throws -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            do { try await body() } catch { self.report((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            do { try await self.load() } catch { self.report((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    func reload() { perform {} }

    fileprivate func setEmbedded(kind: String) {
        guard var view = embedded else { return }
        view.kind = kind
        embedded = view
        limits = [:]
        view.save(kind, view.state)
        reload()
    }

    /// Ждёт завершения всех поставленных действий.
    func settle() async { await chain?.value }

    private func load() async throws {
        try await flush() // Заголовки записей идут общей очередью сохранения.
        guard let fresh = try await store.database(databaseID) else { return }
        database = fresh
        templates = try await store.templates().filter { $0.databaseID == databaseID }
        people = fresh.properties.contains { $0.type == .person } ? try await store.people() : []
        let current = state
        let kind = activeView?.kind ?? DatabaseView.tableKind
        total = try await store.queryRecords(database: fresh, state: current, limit: 0, offset: 0).total
        if kind == DatabaseView.calendarKind {
            try await loadCalendar(fresh, current)
            rows = calendarRows + undated.rows
            sections = []
        } else if kind == DatabaseView.timelineKind {
            try await loadTimeline(fresh, current)
            rows = sections.flatMap(\.rows) + undated.rows
        } else {
            var loaded: [RecordSection] = []
            if let property = current.groupProperty(fresh.properties, kind: kind) {
                for group in RecordGroup.groups(for: property, people: people) {
                    let page = try await store.queryRecords(database: fresh, state: current.narrowed(by: [group.rule]), limit: limits[group.id] ?? Self.pageSize, offset: 0, manualView: manualOrderView)
                    loaded.append(RecordSection(id: group.id, group: group, rows: page.rows, total: page.total))
                }
            } else {
                let page = try await store.queryRecords(database: fresh, state: current, limit: limits["all"] ?? Self.pageSize, offset: 0, manualView: manualOrderView)
                loaded = [RecordSection(id: "all", group: nil, rows: page.rows, total: page.total)]
            }
            sections = loaded
            rows = loaded.flatMap(\.rows)
        }
        selection.formIntersection(Set(rows.map(\.id)))
    }

    private func loadCalendar(_ fresh: Database, _ current: DatabaseViewState) async throws {
        guard let date = current.calendarProperty(fresh.properties) else {
            calendarRows = []
            calendarTotal = 0
            undated = RecordPage(rows: [], total: 0)
            return
        }
        // Границы — вся видимая сетка: в днях соседних месяцев записи тоже показаны.
        let first = calendarDays.first ?? month, last = calendarDays.last ?? month
        // «Не раньше» сравнивает конец значения, «не позже» — начало: попадают и диапазоны, идущие через месяц.
        let inMonth = current.narrowed(by: [FilterRule(property: date.id, op: .greaterOrEqual, value: first.iso),
                                            FilterRule(property: date.id, op: .lessOrEqual, value: last.iso)])
        let page = try await store.queryRecords(database: fresh, state: inMonth, limit: Self.calendarLimit, offset: 0)
        calendarRows = page.rows
        calendarTotal = page.total
        undated = try await store.queryRecords(database: fresh, state: current.narrowed(by: [FilterRule(property: date.id, op: .isEmpty, value: "")]),
                                               limit: limits["undated"] ?? Self.pageSize, offset: 0)
    }

    /// Записи, задевающие шкалу, по группам вида; на все группы вместе не больше `calendarLimit`, как у календаря.
    private func loadTimeline(_ fresh: Database, _ current: DatabaseViewState) async throws {
        // Новая шкала — при открытии вида и смене масштаба: от запомненного дня или от сегодня.
        let key = "\(activeView?.id.uuidString ?? "")|\(current.timelineScale.rawValue)"
        if key != timelineKey {
            timelineKey = key
            let day = current.timelineDay ?? LocalDate(date: Date(), in: .current)
            timelineWindow = TimelineWindow(scale: current.timelineScale, anchor: day)
            timelineScrollTarget = day
        }
        guard let date = current.calendarProperty(fresh.properties) else {
            sections = []
            calendarTotal = 0
            undated = RecordPage(rows: [], total: 0)
            return
        }
        let window = timelineWindow
        let inWindow = current.narrowed(by: [FilterRule(property: date.id, op: .greaterOrEqual, value: window.start.iso),
                                             FilterRule(property: date.id, op: .lessOrEqual, value: window.end.iso)])
        let groups: [RecordGroup?] = current.groupProperty(fresh.properties, kind: DatabaseView.timelineKind).map { RecordGroup.groups(for: $0, people: people) } ?? [nil]
        var loaded: [RecordSection] = [], budget = Self.calendarLimit, total = 0
        for group in groups {
            let state = group.map { inWindow.narrowed(by: [$0.rule]) } ?? inWindow
            let page = try await store.queryRecords(database: fresh, state: state, limit: budget, offset: 0, manualView: manualOrderView)
            budget -= page.rows.count
            total += page.total
            loaded.append(RecordSection(id: group?.id ?? "all", group: group, rows: page.rows, total: page.total))
        }
        sections = loaded
        calendarTotal = total
        undated = try await store.queryRecords(database: fresh, state: current.narrowed(by: [FilterRule(property: date.id, op: .isEmpty, value: "")]),
                                               limit: limits["undated"] ?? Self.pageSize, offset: 0)
    }

    /// Продлить шкалу на порцию; возвращает, на сколько точек сдвинулось её начало (экран поправит прокрутку).
    /// Шкала у предела не растёт — экран перестраивает её вокруг видимого дня через `showTimeline`.
    @discardableResult
    func extendTimeline(before: Bool) -> Double? {
        guard timelineWindow.canGrow else { return nil }
        let next = timelineWindow.extended(before: before)
        timelineWindow = next.window
        reload()
        return next.shift
    }

    /// Показать день: внутри шкалы — только прокрутка, вне её — шкала строится заново вокруг дня.
    func showTimeline(around day: LocalDate, rebuild: Bool = false) {
        let w = timelineWindow
        if rebuild || day < w.start || day > w.end {
            timelineWindow = TimelineWindow(scale: w.scale, anchor: day)
            reload()
        }
        timelineScrollTarget = day
        rememberTimelineDay(day) // программная прокрутка не меняет фазу прокрутки, поэтому день запоминается здесь
    }

    /// День у левого края после прокрутки запоминается в виде без перечитывания записей.
    /// Встроенное представление его не запоминает: иначе каждая прокрутка меняла бы страницу.
    func rememberTimelineDay(_ day: LocalDate) {
        guard !isEmbedded, let view = activeView, view.state.timelineDay != day else { return }
        let previous = chain
        chain = Task { @MainActor [store, databaseID] in
            await previous?.value
            do {
                var state = (try await store.database(databaseID))?.views.first { $0.id == view.id }?.state ?? view.state
                state.timelineDay = day
                try await store.saveViewState(view.id, state)
                if let fresh = try await store.database(databaseID) { self.database = fresh }
            } catch { self.report((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    func setTimelineScale(_ scale: TimelineScale) {
        updateState {
            $0.timelineScale = scale
            $0.extra["timelineScale"] = nil // выбор заменяет и незнакомый масштаб более новой версии
        }
    }

    /// Перенос полосы целиком; шаг — минуты (масштаб «Часы») или дни.
    func shiftDate(record id: UUID, byMinutes minutes: Int) {
        changeDate(record: id) { $0.moved(byMinutes: minutes) }
    }

    func shiftDate(record id: UUID, byDays days: Int) { shiftDate(record: id, byMinutes: days * 1440) }

    /// Растягивание полосы за левый (`start`) или правый край.
    func resizeDate(record id: UUID, start: Bool, byMinutes minutes: Int) {
        changeDate(record: id) { start ? $0.resized(startByMinutes: minutes) : $0.resized(endByMinutes: minutes) }
    }

    func resizeDate(record id: UUID, start: Bool, byDays days: Int) { resizeDate(record: id, start: start, byMinutes: days * 1440) }

    /// Запись без даты получает день, на который её бросили.
    func setDay(record id: UUID, _ day: LocalDate) {
        guard let database, let property = state.calendarProperty(database.properties) else { return }
        setValue(pages: [id], property: property.id, value: .date(DateValue(start: .day(day))))
    }

    private func changeDate(record id: UUID, _ change: (DateValue) -> DateValue) {
        guard let database, let property = state.calendarProperty(database.properties),
              case .date(let value)? = rows.first(where: { $0.id == id })?.values[property.id] else { return }
        let next = change(value)
        guard next != value, next.isValid else { return }
        setValue(pages: [id], property: property.id, value: .date(next))
    }

    // MARK: Зависимости хронологии

    var dependencyProperty: PropertyDefinition? {
        database.flatMap { state.dependencyProperty($0.properties, database: databaseID) }
    }

    /// От каких записей зависит каждая запись шкалы.
    var dependencyLinks: [UUID: [UUID]] {
        guard let property = dependencyProperty else { return [:] }
        var out: [UUID: [UUID]] = [:]
        for row in rows {
            if case .relation(let pages)? = row.values[property.id], !pages.isEmpty { out[row.id] = pages.map(\.id) }
        }
        return out
    }

    /// `record` начинает зависеть от `source`: связь дописывается в конец ячейки.
    func addDependency(record: UUID, on source: UUID) {
        guard record != source, let property = dependencyProperty, let row = rows.first(where: { $0.id == record }) else { return }
        var pages: [LinkedPage] = []
        if case .relation(let list)? = row.values[property.id] { pages = list }
        guard !pages.contains(where: { $0.id == source }), pages.count < RelationLimits.maxLinks else { return }
        pages.append(LinkedPage(id: source, title: rows.first { $0.id == source }?.title ?? ""))
        setValue(pages: [record], property: property.id, value: .relation(pages))
    }

    func removeDependency(record: UUID, on source: UUID) {
        guard let property = dependencyProperty, let row = rows.first(where: { $0.id == record }),
              case .relation(let list)? = row.values[property.id] else { return }
        let rest = list.filter { $0.id != source }
        setValue(pages: [record], property: property.id, value: rest.isEmpty ? nil : .relation(rest))
    }

    /// Пара связей базы с самой собой «Зависит от» / «Блокирует»; хронология сразу рисует по ней стрелки.
    func createDependencyProperty() {
        let id = UUID(), pair = UUID()
        let viewID = activeView?.id
        perform { [store, databaseID] in
            try await store.addRelation(database: databaseID, name: L("Зависит от"), target: databaseID, twoWay: true, pairName: L("Блокирует"),
                                        id: id, pairID: pair, now: SystemClock().nowMillis())
        }
        if viewID != nil { updateState { $0.dependencyProperty = id } }
    }

    func showMore(_ section: String = "all") {
        limits[section, default: Self.pageSize] += Self.pageSize
        reload()
    }

    /// Дни сетки: с понедельника недели первого числа до конца последней недели месяца.
    var calendarDays: [LocalDate] {
        let first = month.firstOfMonth
        let start = first.adding(days: -first.weekdayFromMonday)
        let count = start.days(to: first.addingMonths(1).adding(days: -1)) + 1
        return (0..<((count + 6) / 7 * 7)).map { start.adding(days: $0) }
    }

    func showMonth(_ value: LocalDate) {
        month = value.firstOfMonth
        reload()
    }

    /// Ручной порядок есть у представлений базы; встроенное представление показывает порядок добавления.
    private var manualOrderView: UUID? { isEmbedded ? nil : activeView?.id }
    /// Перетаскивать записи можно, пока у вида нет сортировки, как в Notion.
    var canReorder: Bool { manualOrderView != nil && state.sorts.isEmpty }

    /// Запись встаёт перед `before` (nil — в конец). На доске перенос в другую колонку меняет и значение группы.
    func reorder(record id: UUID, before: UUID?, from source: RecordSection? = nil, to target: RecordSection? = nil) {
        guard id != before else { return }
        guard canReorder, let view = manualOrderView else {
            if let target, source?.id != target.id { move(record: id, from: source, to: target) }
            report(isEmbedded ? L("Порядок записей меняется в самой базе, а не во встроенном представлении.")
                              : L("Порядок задан сортировкой: уберите её, чтобы расставлять записи вручную."))
            return
        }
        var change: (property: UUID, value: PropertyValue?)?
        if let target, let group = target.group, source?.id != target.id,
           let type = database?.property(group.property)?.type, let row = rows.first(where: { $0.id == id }) {
            change = (group.property, group.value(replacing: row.values[group.property], from: source?.group, type: type))
        }
        // Прежнее место — перед следующей записью своей группы; прежнее значение группы — из строки.
        let home = (source ?? sections.first { $0.rows.contains { $0.id == id } })?.rows ?? rows
        let next = home.firstIndex { $0.id == id }.flatMap { $0 + 1 < home.count ? home[$0 + 1].id : nil }
        let oldValue = change.flatMap { snapshot([id], $0.property) }
        registerUndo(L("Перенос записи")) { model in
            model.undoMove(id, before: next, values: change.map { ($0.property, oldValue ?? []) }) { $0.reorder(record: id, before: before, from: source, to: target) }
        }
        perform { [store] in
            let now = SystemClock().nowMillis()
            if let change { try await store.setValue(pages: [id], property: change.property, value: change.value, now: now) }
            try await store.moveRecord(id, before: before, view: view)
        }
    }

    /// Отмена переноса: место и значение группы возвращаются одной цепочкой; `redo` повторяет перенос.
    private func undoMove(_ id: UUID, before: UUID?, values: (property: UUID, list: [(page: UUID, value: PropertyValue?)])?,
                          redo: @escaping (DatabaseModel) -> Void) {
        registerUndo(L("Перенос записи"), redo)
        guard let view = manualOrderView else { return }
        perform { [store] in
            let now = SystemClock().nowMillis()
            if let values, !values.list.isEmpty { try await store.setValues(property: values.property, values.list, now: now) }
            try await store.moveRecord(id, before: before, view: view)
        }
    }

    /// Перенос карточки между группами: меняется значение свойства группировки.
    func move(record id: UUID, from source: RecordSection?, to target: RecordSection) {
        guard let group = target.group, source?.id != target.id,
              let type = database?.property(group.property)?.type,
              let row = rows.first(where: { $0.id == id }) else { return }
        setValue(pages: [id], property: group.property, value: group.value(replacing: row.values[group.property], from: source?.group, type: type))
    }

    /// Перенос в календаре: длина диапазона и время сохраняются, сдвиг считается от дня, за который взяли карточку.
    /// Запись без даты получает этот день.
    func move(record id: UUID, grabbedOn grabbed: LocalDate?, toDay day: LocalDate) {
        guard let database, let property = state.calendarProperty(database.properties),
              let row = rows.first(where: { $0.id == id }) else { return }
        if case .date(let value)? = row.values[property.id] {
            let moved = grabbed.map { value.moved(byDays: $0.days(to: day)) } ?? value.moved(toDay: day)
            setValue(pages: [id], property: property.id, value: .date(moved))
        } else {
            setValue(pages: [id], property: property.id, value: .date(DateValue(start: .day(day))))
        }
    }

    func createRecord(from template: PageTemplate) {
        perform { [store, pagesChanged] in
            _ = try await store.instantiate(template: template.id, parent: nil, ids: RandomIDs(), now: SystemClock().nowMillis())
            try await pagesChanged()
        }
    }

    func selectView(_ id: UUID) {
        activeViewID = id
        limits = [:]
        selection = []
        reload()
    }

    func updateState(_ change: @escaping (inout DatabaseViewState) -> Void) {
        if var view = embedded {
            change(&view.state)
            embedded = view
            view.save(view.kind, view.state)
            return reload()
        }
        guard let view = activeView else { return }
        perform { [store] in
            var state = (try await store.database(self.databaseID))?.views.first { $0.id == view.id }?.state ?? view.state
            change(&state)
            try await store.saveViewState(view.id, state)
        }
    }

    // MARK: Отмена (M10.5)

    /// Стек отмены окна: правки значений, массовые изменения и переносы записей отменяются ⌘Z и возвращаются ⇧⌘Z.
    weak var undoManager: UndoManager?

    /// Прежние значения из загруженных строк. Если какой-то записи нет на экране, шаг не запоминается:
    /// отмена не должна стереть значение, которого модель не видела.
    private func snapshot(_ pages: [UUID], _ property: UUID) -> [(page: UUID, value: PropertyValue?)]? {
        var out: [(page: UUID, value: PropertyValue?)] = []
        for id in pages {
            guard let row = rows.first(where: { $0.id == id }) else { return nil }
            out.append((id, row.values[property]))
        }
        return out
    }

    private func registerUndo(_ name: String, _ action: @escaping (DatabaseModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { action($0) }
        if !undoManager.isUndoing, !undoManager.isRedoing { undoManager.setActionName(name) }
    }

    /// Шаги этой базы уходят из стека вместе с экраном: другая база не должна отменять чужие правки.
    func dropUndo() { undoManager?.removeAllActions(withTarget: self) }

    func setValue(pages: [UUID], property: UUID, value: PropertyValue?) {
        if let old = snapshot(pages, property) {
            registerUndo(pages.count > 1 ? L("Изменение записей") : L("Изменение значения")) { $0.restore(property: property, old) }
        }
        perform { [store] in try await store.setValue(pages: pages, property: property, value: value, now: SystemClock().nowMillis()) }
    }

    /// Возврат значений: сам становится шагом, который можно повторить.
    private func restore(property: UUID, _ values: [(page: UUID, value: PropertyValue?)]) {
        if let current = snapshot(values.map(\.page), property) {
            registerUndo(values.count > 1 ? L("Изменение записей") : L("Изменение значения")) { $0.restore(property: property, current) }
        }
        perform { [store] in try await store.setValues(property: property, values, now: SystemClock().nowMillis()) }
    }

    func createRecord() {
        perform { [store, databaseID, pagesChanged] in
            try await store.createRecord(database: databaseID, title: "", id: UUID(), now: SystemClock().nowMillis())
            try await pagesChanged()
        }
    }

    func trashSelected() {
        let pages = Array(selection)
        perform { [store, pagesChanged] in
            try await store.trashRecords(pages, ids: RandomIDs(), now: SystemClock().nowMillis())
            try await pagesChanged()
        }
    }

    func setTitle(_ id: UUID, _ title: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].title = title }
    }

    /// Столбцы считаются по свежей базе: свойство могло появиться или исчезнуть после последнего показа.
    private func updateColumns(_ change: @escaping (inout [ColumnState]) -> Void) {
        if embedded != nil, let database {
            return updateState { state in
                var columns = state.orderedColumns(database.properties)
                change(&columns)
                state.columns = columns
            }
        }
        guard let view = activeView else { return }
        perform { [store, databaseID] in
            guard let fresh = try await store.database(databaseID), var state = fresh.views.first(where: { $0.id == view.id })?.state else { return }
            var columns = state.orderedColumns(fresh.properties)
            change(&columns)
            state.columns = columns
            try await store.saveViewState(view.id, state)
        }
    }

    func moveColumn(_ property: UUID, by delta: Int) {
        updateColumns { columns in
            guard let i = columns.firstIndex(where: { $0.property == property }), columns.indices.contains(i + delta) else { return }
            columns.swapAt(i, i + delta)
        }
    }

    func setColumnVisible(_ property: UUID, _ visible: Bool) {
        updateColumns { columns in
            if let i = columns.firstIndex(where: { $0.property == property }) { columns[i].visible = visible }
        }
    }
}

/// Группа записей на экране. `group == nil` — всё без группировки.
struct RecordSection: Identifiable, Equatable {
    var id: String
    var group: RecordGroup?
    var rows: [RecordRow]
    var total: Int
}

extension DatabaseModel {
    /// Вид встроенного представления меняется на месте: блок хранит его сам.
    func setEmbeddedKind(_ kind: String) {
        setEmbedded(kind: kind)
    }
}

/// Текст значения для показа. День форматируется от полудня своего дня: сдвига быть не может.
enum PropertyDisplay {
    static func date(_ value: DateValue) -> String {
        func one(_ point: DatePoint) -> String {
            let f = DateFormatter()
            f.locale = Locale.current
            switch point {
            case .day(let d):
                f.timeZone = .current
                f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
                return f.string(from: d.date(in: .current))
            case .moment(let ms, let zone):
                f.timeZone = TimeZone(identifier: zone) ?? .current
                f.setLocalizedDateFormatFromTemplate("dMMMMyyyyHHmm")
                let text = f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
                return zone == TimeZone.current.identifier ? text : "\(text) (\(zone))"
            }
        }
        return value.end.map { "\(one(value.start)) — \(one($0))" } ?? one(value.start)
    }

    /// Значение одной строкой: для карточек, где правка идёт в таблице или на странице записи.
    static func text(_ value: PropertyValue?, property: PropertyDefinition) -> String? {
        switch value {
        case .text(let s)?, .url(let s)?, .unconverted(let s)?: return s.isEmpty ? nil : s
        case .number(let n)?:
            // Проценты свёртки показываются со знаком: 40 без него читается как количество.
            let percent = property.config.aggregate == .percentEmpty || property.config.aggregate == .percentChecked
            return percent ? "\(number(n)) %" : number(n)
        case .date(let d)?: return date(d)
        case .checkbox(let b)?: return b ? "\(property.name): ✓" : nil
        case .options(let ids)?:
            let names = ids.compactMap { id in property.options.first { $0.id == id }?.name }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        case .relation(let links)?: return links.isEmpty ? nil : links.map { $0.title.isEmpty ? L("Без названия") : $0.title }.joined(separator: ", ")
        case .people(let people)?: return people.isEmpty ? nil : people.map(\.label).joined(separator: ", ")
        case .files(let files)?: return files.isEmpty ? nil : files.map(\.name).joined(separator: ", ")
        case .time(let ms)?: return time(ms)
        case .error?: return L("Ошибка формулы")
        case nil: return nil
        }
    }

    /// «Создано» и «Изменено»: момент в поясе пользователя.
    static func time(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyyHHmm")
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func number(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale.current
        f.numberStyle = .decimal
        f.maximumFractionDigits = 10
        return f.string(from: NSNumber(value: value)) ?? PropertyParse.numberText(value)
    }
}
