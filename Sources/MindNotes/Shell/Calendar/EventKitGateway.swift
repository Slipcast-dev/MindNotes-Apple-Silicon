import AppKit
import EventKit

/// Реализация `CalendarGateway` поверх EventKit. При переносе в MindNotes кладётся в `Shell/Calendar/`.
@MainActor
final class EventKitGateway: CalendarGateway {
    private(set) var store = EKEventStore()
    var onChange: (() -> Void)?
    /// Последний виденный статус: хранилище, созданное до выдачи доступа, календарей не видит,
    /// поэтому при смене статуса оно пересоздаётся.
    private var seen: [SyncKind: EKAuthorizationStatus] = [:]
    /// Схема url, по которой элемент узнаёт свой UUID приложения.
    let urlPrefix: String
    private var observer: NSObjectProtocol?

    init(urlPrefix: String = "mindnotes://item/") {
        self.urlPrefix = urlPrefix
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    // MARK: Доступ

    private func entity(_ kind: SyncKind) -> EKEntityType { kind == .event ? .event : .reminder }

    func status(_ kind: SyncKind) -> AccessStatus {
        let now = EKEventStore.authorizationStatus(for: entity(kind))
        if let old = seen[kind], old != now { store = EKEventStore() }
        seen[kind] = now
        switch now {
        case .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess(_ kind: SyncKind) async -> Bool {
        do {
            let ok = kind == .event ? try await store.requestFullAccessToEvents()
                                    : try await store.requestFullAccessToReminders()
            // После разрешения хранилище нужно пересоздать, иначе оно не видит календари.
            if ok { store = EKEventStore() }
            seen[kind] = EKEventStore.authorizationStatus(for: entity(kind))
            return ok || seen[kind] == .fullAccess
        } catch {
            return EKEventStore.authorizationStatus(for: entity(kind)) == .fullAccess
        }
    }

    // MARK: Календари

    func ensureContainer(_ kind: SyncKind, preferredID: String?, title: String) throws -> String {
        guard status(kind) == .granted else { throw SyncError.accessDenied(kind) }
        if let id = preferredID, let cal = store.calendar(withIdentifier: id), cal.allowsContentModifications {
            return id
        }
        // Календарь с таким названием мог остаться от прошлой установки: используем его, а не плодим копии.
        if let same = store.calendars(for: entity(kind)).first(where: { $0.title == title && $0.allowsContentModifications }) {
            return same.calendarIdentifier
        }
        let cal = EKCalendar(for: entity(kind), eventStore: store)
        cal.title = title
        cal.cgColor = NSColor.systemIndigo.cgColor
        guard let source = preferredSource(kind) else { throw SyncError.noSource }
        cal.source = source
        do { try store.saveCalendar(cal, commit: true) } catch { throw SyncError.eventKit(error.localizedDescription) }
        return cal.calendarIdentifier
    }

    /// iCloud → источник календаря по умолчанию → «На Mac».
    private func preferredSource(_ kind: SyncKind) -> EKSource? {
        let fallback = kind == .event ? store.defaultCalendarForNewEvents?.source : store.defaultCalendarForNewReminders()?.source
        let usable = store.sources.filter { !$0.calendars(for: entity(kind)).isEmpty || $0.sourceType == .local }
        return usable.first { $0.sourceType == .calDAV && $0.title == "iCloud" }
            ?? fallback
            ?? store.sources.first { $0.sourceType == .local }
    }

    func removeContainer(_ id: String) throws {
        guard let cal = store.calendar(withIdentifier: id) else { return }
        do { try store.removeCalendar(cal, commit: true) } catch { throw SyncError.eventKit(error.localizedDescription) }
    }

    func containers(_ kind: SyncKind) -> [CalendarInfo] {
        guard status(kind) == .granted else { return [] }
        return store.calendars(for: entity(kind)).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "",
                         color: Self.rgb($0.cgColor), isEditable: $0.allowsContentModifications)
        }.sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    // MARK: Чтение для синхронизации

    func fetch(_ kind: SyncKind, container: String, window: DateInterval?) async throws -> [RemoteItem] {
        guard let cal = store.calendar(withIdentifier: container) else { throw SyncError.notFound }
        switch kind {
        case .event:
            let w = window ?? DateInterval(start: Date().addingTimeInterval(-86400 * 90), duration: 86400 * 455)
            let p = store.predicateForEvents(withStart: w.start, end: w.end, calendars: [cal])
            // У повторяющегося события экземпляры с одним id: в синхронизацию идёт одна запись на серию.
            var seen = Set<String>()
            return store.events(matching: p).compactMap { ev in
                guard seen.insert(ev.calendarItemIdentifier).inserted else { return nil }
                return remote(master(of: ev))
            }
        case .reminder:
            let p = store.predicateForReminders(in: [cal])
            let prefix = urlPrefix
            return await withCheckedContinuation { cont in
                store.fetchReminders(matching: p) { list in
                    let items = (list ?? []).map { Self.remote($0, prefix: prefix) }
                    cont.resume(returning: items)
                }
            }
        }
    }

    func lookup(_ externalIDs: [String], kind: SyncKind) -> [RemoteItem] {
        externalIDs.compactMap { id in
            switch store.calendarItem(withIdentifier: id) {
            case let ev as EKEvent where kind == .event: return remote(master(of: ev))
            case let r as EKReminder where kind == .reminder: return Self.remote(r, prefix: urlPrefix)
            default: return nil
            }
        }
    }

    /// Для серии — исходное событие, а не экземпляр из окна, иначе дата «менялась» бы каждую неделю.
    private func master(of ev: EKEvent) -> EKEvent {
        guard ev.hasRecurrenceRules, let m = store.calendarItem(withIdentifier: ev.calendarItemIdentifier) as? EKEvent else { return ev }
        return m
    }

    private func remote(_ ev: EKEvent) -> RemoteItem {
        RemoteItem(externalID: ev.calendarItemIdentifier, appID: Self.appID(ev.url, prefix: urlPrefix), kind: .event,
                   fields: SyncFields(title: ev.title ?? "", notes: ev.notes, start: ev.startDate, end: ev.endDate,
                                      isAllDay: ev.isAllDay, isCompleted: false, priority: 0,
                                      recurrence: Self.recurrence(ev.recurrenceRules?.first)),
                   modifiedAt: ev.lastModifiedDate ?? ev.creationDate ?? .distantPast)
    }

    nonisolated private static func remote(_ r: EKReminder, prefix: String) -> RemoteItem {
        let comps = r.dueDateComponents
        let due = comps.flatMap { Calendar.current.date(from: $0) }
        return RemoteItem(externalID: r.calendarItemIdentifier, appID: appID(r.url, prefix: prefix), kind: .reminder,
                          fields: SyncFields(title: r.title ?? "", notes: r.notes, start: due, end: nil,
                                             isAllDay: due != nil && comps?.hour == nil, isCompleted: r.isCompleted,
                                             priority: r.priority, recurrence: recurrence(r.recurrenceRules?.first)),
                          modifiedAt: r.lastModifiedDate ?? r.creationDate ?? .distantPast)
    }

    nonisolated private static func appID(_ url: URL?, prefix: String) -> UUID? {
        guard let s = url?.absoluteString, s.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(s.dropFirst(prefix.count)))
    }

    // MARK: Повторы

    nonisolated private static func recurrence(_ rule: EKRecurrenceRule?) -> SyncRecurrence? {
        guard let rule else { return nil }
        let f: SyncRecurrence.Frequency
        switch rule.frequency {
        case .daily: f = .daily
        case .weekly: f = .weekly
        case .monthly: f = .monthly
        case .yearly: f = .yearly
        @unknown default: return nil
        }
        return SyncRecurrence(frequency: f, interval: max(rule.interval, 1), until: rule.recurrenceEnd?.endDate)
    }

    private static func rule(_ r: SyncRecurrence?) -> [EKRecurrenceRule]? {
        guard let r else { return nil }
        let f: EKRecurrenceFrequency
        switch r.frequency {
        case .daily: f = .daily
        case .weekly: f = .weekly
        case .monthly: f = .monthly
        case .yearly: f = .yearly
        }
        return [EKRecurrenceRule(recurrenceWith: f, interval: max(r.interval, 1), end: r.until.map { EKRecurrenceEnd(end: $0) })]
    }

    /// Правило меняется, только если оно действительно другое: иначе EventKit пересоздаёт серию.
    private func apply(_ r: SyncRecurrence?, to item: EKCalendarItem) {
        if Self.recurrence(item.recurrenceRules?.first) == r { return }
        item.recurrenceRules?.forEach { item.removeRecurrenceRule($0) }
        Self.rule(r)?.forEach { item.addRecurrenceRule($0) }
    }

    // MARK: Запись для синхронизации

    func upsert(_ item: LocalItem, container: String, alarmMinutes: Int?) throws -> RemoteItem {
        guard let cal = store.calendar(withIdentifier: container) else { throw SyncError.notFound }
        let f = item.fields
        let url = URL(string: urlPrefix + item.id.uuidString)
        do {
            switch item.kind {
            case .event:
                let existing = item.externalID.flatMap { store.calendarItem(withIdentifier: $0) as? EKEvent }
                let ev = existing ?? EKEvent(eventStore: store)
                if existing == nil { ev.calendar = cal }
                ev.title = f.title
                ev.notes = f.notes
                let start = f.start ?? Date()
                ev.startDate = start
                ev.endDate = max(f.end ?? start.addingTimeInterval(3600), start)
                ev.isAllDay = f.isAllDay
                ev.url = url
                // Повтор задаётся до начала: у нового события правило без даты не сохраняется.
                apply(f.recurrence, to: ev)
                if existing == nil, let m = alarmMinutes { ev.addAlarm(EKAlarm(relativeOffset: TimeInterval(-60 * m))) }
                try store.save(ev, span: .futureEvents, commit: true)
                return remote(ev)

            case .reminder:
                let existing = item.externalID.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
                let r = existing ?? EKReminder(eventStore: store)
                if existing == nil { r.calendar = cal }
                r.title = f.title
                r.notes = f.notes
                r.priority = f.priority
                r.isCompleted = f.isCompleted
                r.url = url
                r.alarms?.forEach { r.removeAlarm($0) }
                if let due = f.start {
                    let parts: Set<Calendar.Component> = f.isAllDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
                    r.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
                    if !f.isAllDay { r.addAlarm(EKAlarm(absoluteDate: due)) }
                    apply(f.recurrence, to: r)
                } else {
                    // Повтор у напоминания без срока EventKit не принимает.
                    r.dueDateComponents = nil
                    apply(nil, to: r)
                }
                try store.save(r, commit: true)
                return Self.remote(r, prefix: urlPrefix)
            }
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.eventKit(error.localizedDescription)
        }
    }

    func delete(externalID: String, kind: SyncKind) throws {
        guard let item = store.calendarItem(withIdentifier: externalID) else { return }
        do {
            if let ev = item as? EKEvent { try store.remove(ev, span: .futureEvents, commit: true) }
            else if let r = item as? EKReminder { try store.remove(r, commit: true) }
        } catch {
            throw SyncError.eventKit(error.localizedDescription)
        }
    }

    // MARK: Виды календаря

    func agenda(_ interval: DateInterval, calendarIDs: Set<String>?, reminderListIDs: [String]) async -> [AgendaEntry] {
        var out: [AgendaEntry] = []
        if status(.event) == .granted {
            let cals = store.calendars(for: .event).filter { calendarIDs?.contains($0.calendarIdentifier) ?? true }
            if !cals.isEmpty {
                let p = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: cals)
                out += store.events(matching: p).map { ev in
                    AgendaEntry(id: ev.calendarItemIdentifier + "@\(Int(ev.startDate.timeIntervalSince1970))", kind: .event,
                                externalID: ev.calendarItemIdentifier, title: ev.title ?? "", notes: ev.notes,
                                start: ev.startDate, end: ev.endDate, isAllDay: ev.isAllDay, isCompleted: false,
                                isRecurring: ev.hasRecurrenceRules,
                                isEditable: ev.calendar?.allowsContentModifications ?? false,
                                calendarID: ev.calendar?.calendarIdentifier ?? "",
                                calendarTitle: ev.calendar?.title ?? "", color: Self.rgb(ev.calendar?.cgColor))
                }
            }
        }
        if status(.reminder) == .granted {
            let lists = reminderListIDs.compactMap { store.calendar(withIdentifier: $0) }
            if !lists.isEmpty {
                let p = store.predicateForReminders(in: lists)
                let entries: [AgendaEntry] = await withCheckedContinuation { cont in
                    store.fetchReminders(matching: p) { list in
                        let items: [AgendaEntry] = (list ?? []).compactMap { r in
                            guard let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps),
                                  interval.contains(due) else { return nil }
                            return AgendaEntry(id: r.calendarItemIdentifier, kind: .reminder, externalID: r.calendarItemIdentifier,
                                               title: r.title ?? "", notes: r.notes, start: due, end: due,
                                               isAllDay: comps.hour == nil, isCompleted: r.isCompleted,
                                               isRecurring: r.hasRecurrenceRules,
                                               isEditable: r.calendar?.allowsContentModifications ?? false,
                                               calendarID: r.calendar?.calendarIdentifier ?? "",
                                               calendarTitle: r.calendar?.title ?? "", color: Self.rgb(r.calendar?.cgColor))
                        }
                        cont.resume(returning: items)
                    }
                }
                out += entries
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Экземпляр серии ищется по началу: `calendarItem(withIdentifier:)` вернул бы первое событие серии.
    private func event(_ id: String, occurrence: Date?) -> EKEvent? {
        guard let base = store.calendarItem(withIdentifier: id) as? EKEvent else { return nil }
        guard let occurrence, base.hasRecurrenceRules, let cal = base.calendar else { return base }
        let p = store.predicateForEvents(withStart: occurrence.addingTimeInterval(-60), end: occurrence.addingTimeInterval(60), calendars: [cal])
        return store.events(matching: p).first { $0.calendarItemIdentifier == id && abs($0.startDate.timeIntervalSince(occurrence)) < 1 } ?? base
    }

    @discardableResult
    func saveEvent(_ d: EventDraft, span: EditSpan) throws -> String {
        let ev: EKEvent
        if let id = d.externalID {
            guard let found = event(id, occurrence: d.occurrenceStart) else { throw SyncError.notFound }
            ev = found
        } else {
            ev = EKEvent(eventStore: store)
            if let m = d.alarmMinutes { ev.addAlarm(EKAlarm(relativeOffset: TimeInterval(-60 * m))) }
        }
        if let cal = store.calendar(withIdentifier: d.calendarID), cal.allowsContentModifications { ev.calendar = cal }
        guard ev.calendar != nil else { throw SyncError.notFound }
        ev.title = d.title
        ev.notes = d.notes
        ev.isAllDay = d.isAllDay
        ev.startDate = d.start
        ev.endDate = max(d.end, d.start)
        if d.externalID == nil || span == .future { apply(d.recurrence, to: ev) }
        do { try store.save(ev, span: span == .future ? .futureEvents : .thisEvent, commit: true) }
        catch { throw SyncError.eventKit(error.localizedDescription) }
        return ev.calendarItemIdentifier
    }

    func deleteEvent(externalID: String, occurrenceStart: Date?, span: EditSpan) throws {
        guard let ev = event(externalID, occurrence: occurrenceStart) else { return }
        do { try store.remove(ev, span: span == .future ? .futureEvents : .thisEvent, commit: true) }
        catch { throw SyncError.eventKit(error.localizedDescription) }
    }

    func setReminderCompleted(externalID: String, _ done: Bool) throws {
        guard let r = store.calendarItem(withIdentifier: externalID) as? EKReminder else { throw SyncError.notFound }
        r.isCompleted = done
        do { try store.save(r, commit: true) } catch { throw SyncError.eventKit(error.localizedDescription) }
    }

    @discardableResult
    func saveReminder(_ d: ReminderDraft) throws -> String {
        guard let list = store.calendar(withIdentifier: d.listID) ?? store.defaultCalendarForNewReminders() else { throw SyncError.notFound }
        let r = EKReminder(eventStore: store)
        r.calendar = list
        r.title = d.title
        r.notes = d.notes
        r.priority = d.priority
        let parts: Set<Calendar.Component> = d.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        r.dueDateComponents = Calendar.current.dateComponents(parts, from: d.due)
        // С временем — уведомление в срок, как у Напоминаний.
        if d.hasTime { r.addAlarm(EKAlarm(absoluteDate: d.due)) }
        do { try store.save(r, commit: true) } catch { throw SyncError.eventKit(error.localizedDescription) }
        return r.calendarItemIdentifier
    }

    func defaultReminderListID() -> String? {
        status(.reminder) == .granted ? store.defaultCalendarForNewReminders()?.calendarIdentifier : nil
    }

    nonisolated private static func rgb(_ c: CGColor?) -> UInt32 {
        guard let c, let ns = NSColor(cgColor: c)?.usingColorSpace(.sRGB) else { return 0x888780 }
        let r = UInt32((ns.redComponent * 255).rounded()), g = UInt32((ns.greenComponent * 255).rounded()),
            b = UInt32((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    /// Ссылка на раздел «Конфиденциальность» в Системных настройках.
    static func privacySettingsURL(_ kind: SyncKind) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + (kind == .event ? "Privacy_Calendars" : "Privacy_Reminders"))!
    }
}
