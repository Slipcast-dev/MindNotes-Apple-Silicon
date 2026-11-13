import Foundation

/// Порты синхронизации: движок не знает ни про EventKit, ни про хранилище MindNotes.
/// В лаборатории это `EventKitGateway` и `JSONItemStore`, в тестах — подделки в памяти.

enum AccessStatus: Equatable, Sendable {
    case notDetermined, granted, denied, writeOnly
}

/// Календарь или список напоминаний.
struct CalendarInfo: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var title: String
    /// Название источника: iCloud, Google, «На Mac».
    var source: String
    /// 0xRRGGBB.
    var color: UInt32
    /// Можно добавлять и менять элементы.
    var isEditable: Bool
    /// Можно переименовать, перекрасить и удалить сам календарь (не подписка и не «Дни рождения»).
    var canEditCalendar = false
    /// Тип источника: iCloud, Exchange, «На Mac»… — для группировки и создания новых календарей.
    var sourceID: String = ""
}

/// Элемент для видов календаря: экземпляр события любого видимого календаря или задача со сроком.
struct AgendaEntry: Identifiable, Equatable, Sendable {
    /// Уникален для экземпляра серии: id EventKit + начало.
    var id: String
    var kind: SyncKind
    /// `calendarItemIdentifier` — по нему элемент открывается на редактирование.
    var externalID: String
    var title: String
    var notes: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var isCompleted: Bool
    var isRecurring: Bool
    var isEditable: Bool
    var calendarID: String
    var calendarTitle: String
    var color: UInt32
}

/// Новое или изменённое событие из видов календаря.
struct EventDraft: Equatable, Sendable {
    /// `nil` — новое событие.
    var externalID: String?
    /// Начало изменяемого экземпляра серии.
    var occurrenceStart: Date?
    var calendarID: String
    var title: String
    var notes: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var recurrence: SyncRecurrence?
    var alarmMinutes: Int?
}

/// Новое напоминание из календаря (правый щелчок по дню).
struct ReminderDraft: Equatable, Sendable {
    var listID: String
    var title: String
    var notes: String?
    var due: Date
    /// `false` — напоминание на весь день, без времени.
    var hasTime: Bool
    var priority: Int = 0
}

/// Какие экземпляры серии затрагивает правка.
enum EditSpan: Sendable { case thisOnly, future }

enum SyncError: Error, Equatable {
    case accessDenied(SyncKind)
    case noSource
    case notFound
    case eventKit(String)
}

@MainActor
protocol CalendarGateway: AnyObject {
    func status(_ kind: SyncKind) -> AccessStatus
    func requestAccess(_ kind: SyncKind) async -> Bool
    /// Возвращает id календаря приложения, создавая его при необходимости.
    func ensureContainer(_ kind: SyncKind, preferredID: String?, title: String) throws -> String
    func removeContainer(_ id: String) throws
    /// Переименовать или перекрасить календарь либо список.
    func updateContainer(_ id: String, title: String?, color: UInt32?) throws
    /// Новый календарь или список в источнике `sourceID` (пусто — источник по умолчанию).
    @discardableResult
    func createContainer(_ kind: SyncKind, title: String, color: UInt32, sourceID: String) throws -> String
    func containers(_ kind: SyncKind) -> [CalendarInfo]
    func fetch(_ kind: SyncKind, container: String, window: DateInterval?) async throws -> [RemoteItem]
    /// Элементы по идентификаторам EventKit в любом календаре; ненайденные пропускаются.
    func lookup(_ externalIDs: [String], kind: SyncKind) -> [RemoteItem]
    /// Создаёт или обновляет элемент и возвращает его состояние после сохранения.
    func upsert(_ item: LocalItem, container: String, alarmMinutes: Int?) throws -> RemoteItem
    func delete(externalID: String, kind: SyncKind) throws
    /// События видимых календарей и задачи со сроком в интервале.
    func agenda(_ interval: DateInterval, calendarIDs: Set<String>?, reminderListIDs: [String]) async -> [AgendaEntry]
    /// Правка из видов календаря: пишет прямо в EventKit, а элементы приложения подтягиваются сверкой.
    @discardableResult
    func saveEvent(_ draft: EventDraft, span: EditSpan) throws -> String
    func deleteEvent(externalID: String, occurrenceStart: Date?, span: EditSpan) throws
    func setReminderCompleted(externalID: String, _ done: Bool) throws
    @discardableResult
    func saveReminder(_ draft: ReminderDraft) throws -> String
    /// Список напоминаний по умолчанию (из настроек Напоминаний).
    func defaultReminderListID() -> String?
    /// Календарь для новых событий по умолчанию (из настроек Календаря).
    func defaultEventCalendarID() -> String?
    /// Вызывается при любом изменении в базе Календаря (в том числе после собственных записей).
    var onChange: (() -> Void)? { get set }
}

@MainActor
protocol LocalItemStore: AnyObject {
    func all(_ kind: SyncKind) -> [LocalItem]
    func item(_ id: UUID) -> LocalItem?
    func save(_ item: LocalItem)
    func purge(_ id: UUID)
    /// Перед сверкой: подготовить снимок (например, перечитать базу).
    func prepare() async
    /// После сверки: дождаться записи изменений.
    func finish() async
}

extension LocalItemStore {
    func prepare() async {}
    func finish() async {}
}
