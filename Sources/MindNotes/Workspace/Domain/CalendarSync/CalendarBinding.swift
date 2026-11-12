import Foundation

/// Связка базы данных MindNotes с Календарём или Напоминаниями.
/// Собирается только вместе с исходниками MindNotes (`Database`, `RecordRow`, `PropertyValue`).
/// При переносе: `Workspace/Domain/CalendarSync/`.
struct CalendarBinding: Codable, Equatable, Identifiable, Sendable {
    var databaseID: UUID
    var kind: SyncKind
    /// Свойство «Дата»: начало и конец события или срок задачи.
    var dateProperty: UUID
    /// Свойство «Флажок» для «Выполнено» (только у задач).
    var doneProperty: UUID?
    /// Текстовое свойство для заметок.
    var notesProperty: UUID?
    var enabled = true

    var id: UUID { databaseID }
}

/// Хранимое состояние связи одной записи с элементом EventKit. Живёт на этом Mac, а не в базе:
/// идентификаторы EventKit у каждого Mac свои.
struct CalendarLink: Codable, Equatable, Sendable {
    var kind: SyncKind
    var externalID: String?
    var syncedAt: Date?
    /// Содержимое на момент последней синхронизации: по нему видно, менялась ли запись с тех пор.
    var syncedFields: SyncFields?
    var syncEnabled = true
}

struct CalendarDatabaseInfo: Equatable, Identifiable {
    var database: Database
    var title: String
    var id: UUID { database.id }
}

/// Что адаптеру нужно от хранилища MindNotes. `SQLiteWorkspace` реализует его в `Shell/Calendar`.
protocol CalendarRecordSource: AnyObject {
    func calendarDatabases() async throws -> [CalendarDatabaseInfo]
    func calendarDatabase(_ id: UUID) async throws -> Database?
    /// Все записи базы без фильтра (записи в корзине не возвращаются).
    func calendarRecords(_ database: Database) async throws -> [RecordRow]
    func calendarCreateRecord(database: UUID, title: String, id: UUID) async throws
    func calendarRename(record: UUID, title: String) async throws
    func calendarSetValue(record: UUID, property: UUID, value: PropertyValue?) async throws
    func calendarTrash(records: [UUID]) async throws
}

/// Перевод «запись базы ↔ поля синхронизации». Чистые функции.
enum RecordCalendarMapping {

    /// Поля из записи. `nil` — запись не подходит (событие без даты).
    /// Свойства, которых в базе нет (приоритет, повтор, заметки без свойства), берутся из `previous`,
    /// чтобы синхронизация их не стирала.
    static func fields(_ row: RecordRow, binding: CalendarBinding, previous: SyncFields?, zone: TimeZone = .current) -> SyncFields? {
        var f = SyncFields(title: row.title)
        f.priority = previous?.priority ?? 0
        f.recurrence = previous?.recurrence
        f.notes = previous?.notes

        if case .date(let value)? = row.values[binding.dateProperty] {
            let (s, e, allDay) = dates(value, zone: zone)
            f.start = s
            f.isAllDay = allDay
            f.end = binding.kind == .event ? (e ?? (allDay ? s : s.addingTimeInterval(3600))) : nil
        } else {
            if binding.kind == .event { return nil }
            f.recurrence = nil   // у задачи без срока повтора не бывает
        }
        if let p = binding.doneProperty, case .checkbox(let done)? = row.values[p] { f.isCompleted = done }
        if let p = binding.notesProperty {
            if case .text(let t)? = row.values[p] { f.notes = t.isEmpty ? nil : t } else { f.notes = nil }
        }
        return f
    }

    /// Значения свойств для записи из полей Календаря.
    static func values(_ f: SyncFields, binding: CalendarBinding, zone: TimeZone = .current) -> [(property: UUID, value: PropertyValue?)] {
        var out: [(UUID, PropertyValue?)] = [(binding.dateProperty, f.start.map { .date(dateValue(start: $0, end: f.end, allDay: f.isAllDay, kind: binding.kind, zone: zone)) })]
        if let p = binding.doneProperty { out.append((p, .checkbox(f.isCompleted))) }
        if let p = binding.notesProperty { out.append((p, f.notes.flatMap { $0.isEmpty ? nil : .text($0) })) }
        return out
    }

    static func dates(_ v: DateValue, zone: TimeZone) -> (Date, Date?, Bool) {
        switch v.start {
        case .day(let d):
            // `LocalDate.date(in:)` — полдень; EventKit ждёт у событий на весь день начало суток.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            var endDay: Date?
            if case .day(let e)? = v.end { endDay = cal.startOfDay(for: e.date(in: zone)) }
            return (cal.startOfDay(for: d.date(in: zone)), endDay, true)
        case .moment(let ms, _):
            var end: Date?
            if case .moment(let e, _)? = v.end { end = Date(timeIntervalSince1970: Double(e) / 1000) }
            return (Date(timeIntervalSince1970: Double(ms) / 1000), end, false)
        }
    }

    static func dateValue(start: Date, end: Date?, allDay: Bool, kind: SyncKind, zone: TimeZone) -> DateValue {
        if allDay {
            let s = LocalDate(date: start, in: zone)
            // Конец на весь день — последний день события; однодневное событие хранится без конца.
            let e = end.map { LocalDate(date: $0, in: zone) }.flatMap { $0 > s ? $0 : nil }
            return DateValue(start: .day(s), end: kind == .event ? e.map { .day($0) } : nil)
        }
        let ms = Int64((start.timeIntervalSince1970 * 1000).rounded())
        guard kind == .event, let end, end > start else { return DateValue(start: .moment(ms: ms, zone: zone.identifier)) }
        let endMs = Int64((end.timeIntervalSince1970 * 1000).rounded())
        // Событие на час без явного конца в MindNotes так и хранится — без конца.
        if endMs - ms == 3_600_000 { return DateValue(start: .moment(ms: ms, zone: zone.identifier)) }
        return DateValue(start: .moment(ms: ms, zone: zone.identifier), end: .moment(ms: endMs, zone: zone.identifier))
    }

    /// Базы, которые можно связать: есть хотя бы одно свойство «Дата».
    static func candidates(_ all: [CalendarDatabaseInfo]) -> [CalendarDatabaseInfo] {
        all.filter { $0.database.properties.contains { $0.type == .date } }
    }

    /// Связка по умолчанию: первое свойство даты, первый флажок (у задач).
    static func defaultBinding(_ db: Database, kind: SyncKind) -> CalendarBinding? {
        guard let date = db.properties.first(where: { $0.type == .date }) else { return nil }
        return CalendarBinding(databaseID: db.id, kind: kind, dateProperty: date.id,
                               doneProperty: kind == .reminder ? db.properties.first { $0.type == .checkbox }?.id : nil)
    }
}
