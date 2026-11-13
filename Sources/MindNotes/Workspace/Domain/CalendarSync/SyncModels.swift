import Foundation

/// Чистый слой синхронизации с Календарём и Напоминаниями: без EventKit, SwiftUI и AppKit.
/// При переносе в MindNotes кладётся в `Workspace/Domain/CalendarSync/`.

/// Что синхронизируется: событие календаря или напоминание.
enum SyncKind: String, Codable, CaseIterable, Sendable {
    case event, reminder
}

/// Содержимое элемента, которое сравнивается и переносится в обе стороны.
struct SyncFields: Equatable, Codable, Sendable {
    var title: String
    var notes: String?
    /// Начало события или срок напоминания.
    var start: Date?
    /// Конец события; у напоминаний `nil`.
    var end: Date?
    var isAllDay: Bool
    var isCompleted: Bool
    /// 0 — нет, 1 — высокий, 5 — средний, 9 — низкий (как в EventKit).
    var priority: Int
    /// Повтор серии. Отдельные изменённые экземпляры серии не синхронизируются.
    var recurrence: SyncRecurrence?

    init(title: String, notes: String? = nil, start: Date? = nil, end: Date? = nil,
         isAllDay: Bool = false, isCompleted: Bool = false, priority: Int = 0, recurrence: SyncRecurrence? = nil) {
        self.title = title
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCompleted = isCompleted
        self.priority = priority
        self.recurrence = recurrence
    }

    /// EventKit хранит даты с точностью до секунды, а пустые заметки возвращает как `nil` или "".
    /// Сравнение идёт по нормализованным значениям, иначе каждая сверка находила бы «изменения».
    var normalized: SyncFields {
        var f = self
        if isAllDay {
            // У событий на весь день важен только день: EventKit хранит конец как 23:59:59 последнего дня.
            let cal = Calendar.current
            f.start = start.map { cal.startOfDay(for: $0) }
            // Конец — последний день события (EventKit отдаёт 23:59:59 этого дня).
            f.end = end.map { cal.startOfDay(for: $0) }
        } else {
            f.start = start.map(Self.trim)
            f.end = end.map(Self.trim)
        }
        if f.notes?.isEmpty == true { f.notes = nil }
        f.recurrence = recurrence.map { r in
            var r = r
            r.until = r.until.map { Calendar.current.startOfDay(for: $0) }
            return r
        }
        return f
    }

    /// Тот же элемент «на глаз»: название и начало. Нужен, чтобы найти пару, если связь потеряна.
    func looksLike(_ other: SyncFields) -> Bool {
        let a = normalized, b = other.normalized
        return a.title == b.title && a.start == b.start && !a.title.isEmpty
    }

    func sameContent(as other: SyncFields) -> Bool { normalized == other.normalized }

    private static func trim(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: d.timeIntervalSinceReferenceDate.rounded(.down))
    }
}

/// Правило повтора: подмножество RRULE, которое поддерживают и Календарь, и Напоминания.
struct SyncRecurrence: Equatable, Codable, Sendable {
    enum Frequency: String, Codable, CaseIterable, Sendable { case daily, weekly, monthly, yearly }
    var frequency: Frequency
    var interval: Int = 1
    /// Последний день серии; `nil` — без конца.
    var until: Date?
}

/// Элемент приложения, связанный (или связываемый) с Календарём.
struct LocalItem: Equatable, Codable, Identifiable, Sendable {
    var id: UUID
    var kind: SyncKind
    var fields: SyncFields
    /// `calendarItemIdentifier` в EventKit; `nil`, пока элемент не выгружен.
    var externalID: String?
    /// Когда элемент последний раз меняли в приложении.
    var updatedAt: Date
    /// Когда элемент последний раз совпадал с Календарём. `nil` — ещё не синхронизирован.
    var syncedAt: Date?
    /// Мягкое удаление: элемент ждёт, пока удаление дойдёт до Календаря.
    var isDeleted: Bool
    /// Переключатель «В Календаре» / «В Напоминаниях» у конкретного элемента.
    var syncEnabled: Bool

    init(id: UUID = UUID(), kind: SyncKind, fields: SyncFields, externalID: String? = nil,
         updatedAt: Date = Date(), syncedAt: Date? = nil, isDeleted: Bool = false, syncEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.fields = fields
        self.externalID = externalID
        self.updatedAt = updatedAt
        self.syncedAt = syncedAt
        self.isDeleted = isDeleted
        self.syncEnabled = syncEnabled
    }
}

/// Снимок элемента из Календаря или Напоминаний.
struct RemoteItem: Equatable, Sendable {
    var externalID: String
    /// Идентификатор приложения из `url` (`mindnotes://item/<uuid>`), если элемент создан приложением.
    var appID: UUID?
    var kind: SyncKind
    var fields: SyncFields
    var modifiedAt: Date
}

/// Что делать, если элемент изменили и в приложении, и в Календаре.
enum ConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, newerWins, appWins
    var id: String { rawValue }
}

/// Один шаг плана синхронизации. План строит `SyncPlanner`, выполняет `CalendarSyncEngine`.
enum SyncAction: Equatable, Sendable {
    /// Выгрузить новый элемент приложения.
    case pushCreate(UUID)
    /// Отправить изменения приложения в Календарь.
    case pushUpdate(UUID)
    /// Элемент удалён в приложении: удалить в Календаре и забыть.
    case pushDelete(UUID, externalID: String)
    /// Календарь новее: забрать изменения.
    case pullUpdate(UUID, RemoteItem)
    /// Элемент пропал из Календаря: удалить в приложении.
    case pullDelete(UUID)
    /// Элемент создан в календаре приложения вручную: импортировать.
    case importNew(RemoteItem)
    /// Изменён с обеих сторон, а политика — «Спросить».
    case conflict(UUID, RemoteItem)
    /// Идентификатор EventKit сменился (бывает после синхронизации iCloud); элемент найден по `appID`.
    case relink(UUID, externalID: String)
    /// Содержимое совпадает: отметить, что синхронизировано.
    case markSynced(UUID, modifiedAt: Date)
}

/// Конфликт, ожидающий решения пользователя.
struct SyncConflict: Identifiable, Equatable, Sendable {
    var id: UUID { local.id }
    var local: LocalItem
    var remote: RemoteItem
}
