import Foundation

/// Календарь в памяти: ведёт себя как EventKit для движка, но ничего не пишет на диск.
@MainActor
final class FakeGateway: CalendarGateway {
    var access: [SyncKind: AccessStatus] = [.event: .granted, .reminder: .granted]
    var grantOnRequest = true
    var containersByKind: [SyncKind: [CalendarInfo]] = [.event: [], .reminder: []]
    var items: [String: RemoteItem] = [:]
    var itemContainer: [String: String] = [:]
    var clock: () -> Date
    var onChange: (() -> Void)?
    var upserts = 0
    var failNextUpsert = false
    private var counter = 0

    init(clock: @escaping () -> Date) { self.clock = clock }

    func status(_ kind: SyncKind) -> AccessStatus { access[kind] ?? .notDetermined }

    func requestAccess(_ kind: SyncKind) async -> Bool {
        access[kind] = grantOnRequest ? .granted : .denied
        return grantOnRequest
    }

    func ensureContainer(_ kind: SyncKind, preferredID: String?, title: String) throws -> String {
        guard status(kind) == .granted else { throw SyncError.accessDenied(kind) }
        if let id = preferredID, containersByKind[kind]!.contains(where: { $0.id == id }) { return id }
        if let same = containersByKind[kind]!.first(where: { $0.title == title }) { return same.id }
        counter += 1
        let c = CalendarInfo(id: "\(kind.rawValue)-cal-\(counter)", title: title, source: "iCloud", color: 0x7F77DD, isEditable: true)
        containersByKind[kind]!.append(c)
        return c.id
    }

    func removeContainer(_ id: String) throws {
        for k in SyncKind.allCases { containersByKind[k]!.removeAll { $0.id == id } }
        for (ext, c) in itemContainer where c == id { items[ext] = nil; itemContainer[ext] = nil }
    }

    func containers(_ kind: SyncKind) -> [CalendarInfo] { containersByKind[kind] ?? [] }

    func updateContainer(_ id: String, title: String?, color: UInt32?) throws {
        for k in SyncKind.allCases {
            guard let i = containersByKind[k]!.firstIndex(where: { $0.id == id }) else { continue }
            if let title { containersByKind[k]![i].title = title }
            if let color { containersByKind[k]![i].color = color }
            return
        }
        throw SyncError.notFound
    }

    func createContainer(_ kind: SyncKind, title: String, color: UInt32, sourceID: String) throws -> String {
        counter += 1
        let c = CalendarInfo(id: "\(kind.rawValue)-cal-\(counter)", title: title, source: "iCloud", color: color, isEditable: true,
                             canEditCalendar: true)
        containersByKind[kind]!.append(c)
        return c.id
    }

    func fetch(_ kind: SyncKind, container: String, window: DateInterval?) async throws -> [RemoteItem] {
        items.values.filter { $0.kind == kind && itemContainer[$0.externalID] == container }
            .filter { r in
                guard let w = window, let s = r.fields.start else { return true }
                return w.contains(s)
            }
            .sorted { $0.externalID < $1.externalID }
    }

    func upsert(_ item: LocalItem, container: String, alarmMinutes: Int?) throws -> RemoteItem {
        if failNextUpsert { failNextUpsert = false; throw SyncError.eventKit("сбой записи") }
        upserts += 1
        let ext: String
        if let e = item.externalID, items[e] != nil { ext = e } else { counter += 1; ext = "ek-\(counter)" }
        let r = RemoteItem(externalID: ext, appID: item.id, kind: item.kind, fields: item.fields.normalized, modifiedAt: clock())
        items[ext] = r
        itemContainer[ext] = container
        return r
    }

    func delete(externalID: String, kind: SyncKind) throws {
        items[externalID] = nil
        itemContainer[externalID] = nil
    }

    func lookup(_ externalIDs: [String], kind: SyncKind) -> [RemoteItem] {
        externalIDs.compactMap { items[$0] }.filter { $0.kind == kind }
    }

    func agenda(_ interval: DateInterval, calendarIDs: Set<String>?, reminderListIDs: [String]) async -> [AgendaEntry] { [] }
    func saveEvent(_ draft: EventDraft, span: EditSpan) throws -> String { draft.externalID ?? "" }
    func deleteEvent(externalID: String, occurrenceStart: Date?, span: EditSpan) throws {}
    func setReminderCompleted(externalID: String, _ done: Bool) throws {}
    func saveReminder(_ draft: ReminderDraft) throws -> String {
        userCreate(.reminder, container: draft.listID, title: draft.title, start: draft.due)
    }
    func defaultReminderListID() -> String? { containersByKind[.reminder]?.first?.id }

    /// Календарь «потерял» url элемента.
    func wipeURL(_ ext: String) { items[ext]?.appID = nil }

    /// Переносит элемент в другой календарь (вне выборки календаря приложения).
    func moveOut(_ ext: String) { itemContainer[ext] = "elsewhere" }

    // MARK: Действия «пользователя в Календаре»

    func userEdit(_ ext: String, _ change: (inout SyncFields) -> Void) {
        guard var r = items[ext] else { return }
        change(&r.fields)
        r.modifiedAt = clock()
        items[ext] = r
    }

    @discardableResult
    func userCreate(_ kind: SyncKind, container: String, title: String, start: Date?) -> String {
        counter += 1
        let ext = "ek-\(counter)"
        items[ext] = RemoteItem(externalID: ext, appID: nil, kind: kind,
                                fields: SyncFields(title: title, start: start, end: kind == .event ? start?.addingTimeInterval(3600) : nil),
                                modifiedAt: clock())
        itemContainer[ext] = container
        return ext
    }

    func userDelete(_ ext: String) { items[ext] = nil; itemContainer[ext] = nil }

    /// iCloud сменил идентификатор элемента.
    func renameID(_ ext: String, to new: String) {
        guard var r = items[ext] else { return }
        let c = itemContainer[ext]
        items[ext] = nil; itemContainer[ext] = nil
        r.externalID = new
        items[new] = r; itemContainer[new] = c
    }
}

/// Управляемые часы для тестов.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func tick(_ s: TimeInterval = 60) { now = now.addingTimeInterval(s) }
}

/// Хранилище элементов в памяти для тестов движка.
@MainActor
final class MemoryItemStore: LocalItemStore {
    private(set) var items: [LocalItem] = []
    func all(_ kind: SyncKind) -> [LocalItem] { items.filter { $0.kind == kind } }
    func item(_ id: UUID) -> LocalItem? { items.first { $0.id == id } }
    func save(_ item: LocalItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }
    func purge(_ id: UUID) { items.removeAll { $0.id == id } }
}
