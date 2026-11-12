import Foundation
import Observation

/// Движок синхронизации: строит план (`SyncPlanner`) и выполняет его через порты.
/// Без EventKit и UI. При переносе в MindNotes кладётся в `Workspace/Services/`.
@MainActor
@Observable
final class CalendarSyncEngine {
    private(set) var settings: SyncSettings
    private(set) var log: [SyncLogEntry] = []
    private(set) var conflicts: [SyncConflict] = []
    private(set) var isSyncing = false
    private(set) var lastSummary = SyncSummary()

    @ObservationIgnored let gateway: CalendarGateway
    @ObservationIgnored let store: LocalItemStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settingsKey: String
    /// Название календаря и списка приложения в EventKit.
    @ObservationIgnored let containerTitle: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pendingResync = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private let logLimit = 200

    init(gateway: CalendarGateway, store: LocalItemStore, defaults: UserDefaults = .standard,
         settingsKey: String = "calendarSync.settings", containerTitle: String = "MindNotes",
         now: @escaping () -> Date = Date.init) {
        self.gateway = gateway
        self.store = store
        self.defaults = defaults
        self.settingsKey = settingsKey
        self.containerTitle = containerTitle
        self.now = now
        self.settings = SyncSettings.load(defaults, key: settingsKey)
        gateway.onChange = { [weak self] in self?.scheduleSync() }
    }

    // MARK: Доступ и настройки

    func status(_ kind: SyncKind) -> AccessStatus { gateway.status(kind) }

    /// Включает синхронизацию вида: спрашивает доступ, создаёт календарь приложения, сразу сверяет.
    @discardableResult
    func enable(_ kind: SyncKind) async -> Bool {
        if gateway.status(kind) != .granted {
            guard await gateway.requestAccess(kind) else {
                note(.warning, .noAccess(kind))
                update { $0.setEnabled(kind, false) }
                return false
            }
        }
        do {
            let id = try gateway.ensureContainer(kind, preferredID: settings.containerID(kind), title: containerTitle)
            update { $0.setContainerID(kind, id); $0.setEnabled(kind, true) }
        } catch {
            note(.error, .createFailed("\(error)"))
            return false
        }
        await syncNow()
        return true
    }

    func disable(_ kind: SyncKind) {
        update { $0.setEnabled(kind, false) }
        note(.info, .disabled(kind))
    }

    func setPolicy(_ p: ConflictPolicy) { update { $0.conflictPolicy = p } }
    func setDefaultAlarm(_ minutes: Int?) { update { $0.defaultAlarmMinutes = minutes } }
    func setCompletedDays(_ days: Int) { update { $0.completedDays = days } }
    func setVisibleCalendars(_ ids: Set<String>?) { update { $0.visibleCalendarIDs = ids } }

    /// Переносит синхронизацию в другой календарь или список. Элементы переписываются туда при следующей сверке.
    func setContainer(_ kind: SyncKind, id: String) async {
        guard id != settings.containerID(kind) else { return }
        update { $0.setContainerID(kind, id) }
        for var item in store.all(kind) where item.syncEnabled && !item.isDeleted {
            item.externalID = nil
            item.syncedAt = nil
            store.save(item)
        }
        await syncNow()
    }

    private func update(_ change: (inout SyncSettings) -> Void) {
        change(&settings)
        settings.save(defaults, key: settingsKey)
    }

    // MARK: Сверка

    /// Изменения в Календаре приходят пачками, поэтому сверка откладывается на полсекунды.
    func scheduleSync() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        if isSyncing { pendingResync = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            pendingResync = false
            var total = SyncSummary()
            let active = SyncKind.allCases.filter { settings.isEnabled($0) }
            if !active.isEmpty { await store.prepare() }
            for kind in active { total.add(await sync(kind)) }
            if !active.isEmpty { await store.finish() }
            lastSummary = total
            update { $0.lastSyncAt = now() }
            if !total.isEmpty { note(total.failures > 0 ? .warning : .info, .summary(total)) }
        } while pendingResync
    }

    func window(for kind: SyncKind) -> DateInterval? {
        guard kind == .event else { return nil }
        let cal = Calendar.current
        let from = cal.date(byAdding: .month, value: -3, to: now())!
        let to = cal.date(byAdding: .month, value: 12, to: now())!
        return DateInterval(start: from, end: to)
    }

    private func sync(_ kind: SyncKind) async -> SyncSummary {
        var s = SyncSummary()
        guard gateway.status(kind) == .granted else {
            note(.warning, .noAccess(kind))
            return s
        }
        let container: String
        do {
            container = try gateway.ensureContainer(kind, preferredID: settings.containerID(kind), title: containerTitle)
            if container != settings.containerID(kind) {
                // Календарь удалили снаружи: создан новый, всё выгружается в него заново.
                note(.warning, .recreated)
                update { $0.setContainerID(kind, container) }
                for var item in store.all(kind) where item.externalID != nil {
                    item.externalID = nil
                    item.syncedAt = nil
                    store.save(item)
                }
            }
        } catch {
            note(.error, .openFailed("\(error)"))
            s.failures += 1
            return s
        }

        let win = window(for: kind)
        var remote: [RemoteItem]
        do { remote = try await gateway.fetch(kind, container: container, window: win) }
        catch {
            note(.error, .readFailed("\(error)"))
            s.failures += 1
            return s
        }
        // Связанные элементы вне окна ищутся по id: так удаление в далёком будущем или прошлом тоже замечается.
        let missing = SyncPlanner.needsLookup(local: store.all(kind), fetched: remote)
        if !missing.isEmpty { remote += gateway.lookup(missing, kind: kind) }

        let plan = SyncPlanner.plan(local: store.all(kind), remote: remote, policy: settings.conflictPolicy, window: nil)
        conflicts.removeAll { $0.local.kind == kind }
        for action in plan {
            do { try apply(action, container: container, summary: &s) }
            catch {
                s.failures += 1
                note(.error, .failed("\(error)"))
            }
        }
        return s
    }

    private func apply(_ action: SyncAction, container: String, summary s: inout SyncSummary) throws {
        switch action {
        case .relink(let id, let ext):
            guard var item = store.item(id) else { return }
            item.externalID = ext
            store.save(item)

        case .markSynced(let id, let modified):
            guard var item = store.item(id) else { return }
            item.syncedAt = max(now(), modified)
            store.save(item)

        case .pushCreate(let id), .pushUpdate(let id):
            guard var item = store.item(id) else { return }
            let r = try gateway.upsert(item, container: container, alarmMinutes: settings.defaultAlarmMinutes)
            item.externalID = r.externalID
            item.syncedAt = max(now(), r.modifiedAt, item.updatedAt)
            store.save(item)
            s.pushed += 1

        case .pushDelete(let id, let ext):
            try gateway.delete(externalID: ext, kind: store.item(id)?.kind ?? .event)
            store.purge(id)
            s.deletedThere += 1

        case .pullUpdate(let id, let r):
            guard var item = store.item(id) else { return }
            item.fields = r.fields
            item.externalID = r.externalID
            item.updatedAt = r.modifiedAt
            item.syncedAt = max(now(), r.modifiedAt)
            store.save(item)
            s.pulled += 1

        case .pullDelete(let id):
            guard var item = store.item(id) else { return }
            item.isDeleted = true
            item.externalID = nil
            item.syncedAt = now()
            store.save(item)
            s.deletedHere += 1

        case .importNew(let r):
            var item = LocalItem(kind: r.kind, fields: r.fields, externalID: r.externalID,
                                 updatedAt: r.modifiedAt, syncedAt: nil)
            store.save(item)
            // Записать свой UUID в url, чтобы в следующий раз найти элемент даже при смене id EventKit.
            let saved = try gateway.upsert(item, container: container, alarmMinutes: nil)
            item.externalID = saved.externalID
            item.syncedAt = max(now(), saved.modifiedAt)
            store.save(item)
            s.imported += 1

        case .conflict(let id, let r):
            guard let item = store.item(id) else { return }
            conflicts.append(SyncConflict(local: item, remote: r))
            s.conflicts += 1
        }
    }

    // MARK: Конфликты

    /// `keepApp == true` — оставить версию приложения, иначе версию Календаря.
    func resolve(_ conflict: SyncConflict, keepApp: Bool) async {
        conflicts.removeAll { $0.id == conflict.id }
        guard let container = settings.containerID(conflict.local.kind) else { return }
        var s = SyncSummary()
        do {
            if keepApp {
                try apply(.pushUpdate(conflict.local.id), container: container, summary: &s)
            } else {
                try apply(.pullUpdate(conflict.local.id, conflict.remote), container: container, summary: &s)
            }
            note(.info, .resolved(keptApp: keepApp))
        } catch {
            note(.error, .failed("\(error)"))
        }
    }

    func resolveAllByNewer() async {
        let pending = conflicts
        setPolicy(.newerWins)
        for c in pending { await resolve(c, keepApp: c.local.updatedAt >= c.remote.modifiedAt) }
    }

    // MARK: Изменения из приложения

    /// Вызывается приложением после сохранения элемента: сразу отправляет изменение.
    func itemChanged(_ id: UUID) async {
        guard let item = store.item(id), item.syncEnabled, settings.isEnabled(item.kind) else { return }
        await syncNow()
    }

    // MARK: Журнал

    func note(_ level: SyncLogEntry.Level, _ message: SyncMessage) {
        log.insert(SyncLogEntry(date: now(), level: level, message: message), at: 0)
        if log.count > logLimit { log.removeLast(log.count - logLimit) }
    }

    func clearLog() { log.removeAll() }
}

extension SyncSummary {
    mutating func add(_ o: SyncSummary) {
        pushed += o.pushed; pulled += o.pulled; deletedHere += o.deletedHere; deletedThere += o.deletedThere
        imported += o.imported; conflicts += o.conflicts; failures += o.failures
    }
}
