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
        default: return rawValue
        }
    }
}

extension FilterOp {
    func title(for type: PropertyType) -> String {
        switch self {
        case .contains: return L("содержит")
        case .notContains: return L("не содержит")
        case .equals: return type == .date ? L("в этот день") : L("равно")
        case .notEquals: return L("не равно")
        case .startsWith: return L("начинается с")
        case .less: return type == .date ? L("раньше") : L("меньше")
        case .lessOrEqual: return type == .date ? L("не позже") : L("не больше")
        case .greater: return type == .date ? L("позже") : L("больше")
        case .greaterOrEqual: return type == .date ? L("не раньше") : L("не меньше")
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

    let store: SQLiteWorkspace
    let databaseID: UUID
    let pageID: UUID
    @Published private(set) var database: Database?
    @Published var activeViewID: UUID?
    @Published private(set) var rows: [RecordRow] = []
    @Published private(set) var total = 0
    @Published var selection: Set<UUID> = []
    private var limit = DatabaseModel.pageSize
    private var chain: Task<Void, Never>?
    private let flush: () async throws -> Void
    private let pagesChanged: () async throws -> Void
    private let report: (String) -> Void

    init(store: SQLiteWorkspace, databaseID: UUID, pageID: UUID, flush: @escaping () async throws -> Void,
         pagesChanged: @escaping () async throws -> Void, report: @escaping (String) -> Void) {
        self.store = store
        self.databaseID = databaseID
        self.pageID = pageID
        self.flush = flush
        self.pagesChanged = pagesChanged
        self.report = report
    }

    /// Показываются только таблицы; представления других видов хранятся до M6.
    var views: [DatabaseView] { database?.views.filter { $0.kind == DatabaseView.tableKind } ?? [] }
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

    /// Ждёт завершения всех поставленных действий.
    func settle() async { await chain?.value }

    private func load() async throws {
        try await flush() // Заголовки записей идут общей очередью сохранения.
        guard let fresh = try await store.database(databaseID) else { return }
        database = fresh
        let page = try await store.queryRecords(database: fresh, state: state, limit: limit, offset: 0)
        rows = page.rows
        total = page.total
        selection.formIntersection(Set(rows.map(\.id)))
    }

    func showMore() {
        limit += Self.pageSize
        reload()
    }

    func selectView(_ id: UUID) {
        activeViewID = id
        limit = Self.pageSize
        selection = []
        reload()
    }

    func updateState(_ change: @escaping (inout DatabaseViewState) -> Void) {
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

    static func number(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale.current
        f.numberStyle = .decimal
        f.maximumFractionDigits = 10
        return f.string(from: NSNumber(value: value)) ?? PropertyParse.numberText(value)
    }
}
