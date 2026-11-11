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
        } else {
            var loaded: [RecordSection] = []
            if let property = current.groupProperty(fresh.properties, kind: kind) {
                for group in RecordGroup.groups(for: property, people: people) {
                    let page = try await store.queryRecords(database: fresh, state: current.narrowed(by: [group.rule]), limit: limits[group.id] ?? Self.pageSize, offset: 0)
                    loaded.append(RecordSection(id: group.id, group: group, rows: page.rows, total: page.total))
                }
            } else {
                let page = try await store.queryRecords(database: fresh, state: current, limit: limits["all"] ?? Self.pageSize, offset: 0)
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

    func setValue(pages: [UUID], property: UUID, value: PropertyValue?) {
        perform { [store] in try await store.setValue(pages: pages, property: property, value: value, now: SystemClock().nowMillis()) }
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
