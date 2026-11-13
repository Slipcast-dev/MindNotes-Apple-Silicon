import Foundation

/// Настройки синхронизации (экран «Синхронизация»). Хранятся одной JSON-строкой в UserDefaults.
struct SyncSettings: Codable, Equatable, Sendable {
    var eventsEnabled = false
    var remindersEnabled = false
    /// Календарь и список приложения в EventKit.
    var eventCalendarID: String?
    var reminderListID: String?
    /// Какие календари показывать в виде «День». `nil` — все.
    var visibleCalendarIDs: Set<String>?
    /// Оповещение по умолчанию для новых событий, минут до начала. `nil` — без оповещения.
    var defaultAlarmMinutes: Int? = 15
    /// За сколько дней показывать выполненные напоминания.
    var completedDays = 30
    var conflictPolicy: ConflictPolicy = .ask
    var lastSyncAt: Date?

    func isEnabled(_ kind: SyncKind) -> Bool { kind == .event ? eventsEnabled : remindersEnabled }

    mutating func setEnabled(_ kind: SyncKind, _ on: Bool) {
        if kind == .event { eventsEnabled = on } else { remindersEnabled = on }
    }

    func containerID(_ kind: SyncKind) -> String? { kind == .event ? eventCalendarID : reminderListID }

    mutating func setContainerID(_ kind: SyncKind, _ id: String?) {
        if kind == .event { eventCalendarID = id } else { reminderListID = id }
    }

    static func load(_ defaults: UserDefaults, key: String) -> SyncSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(SyncSettings.self, from: data) else { return SyncSettings() }
        return s
    }

    func save(_ defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// Событие журнала. Текст собирает UI: чистый слой не знает про локализацию.
enum SyncMessage: Equatable, Sendable {
    case noAccess(SyncKind)
    case disabled(SyncKind)
    case createFailed(String)
    case openFailed(String)
    case readFailed(String)
    case failed(String)
    case recreated
    /// Календарь синхронизации удалён — синхронизация вида выключена.
    case containerDeleted(SyncKind)
    case summary(SyncSummary)
    case resolved(keptApp: Bool)
    /// Готовый текст от приложения.
    case text(String)
}

/// Запись журнала синхронизации (экран «Журнал»).
struct SyncLogEntry: Identifiable, Equatable, Sendable {
    enum Level: Sendable { case info, warning, error }
    let id = UUID()
    var date: Date
    var level: Level
    var message: SyncMessage

    static func == (a: SyncLogEntry, b: SyncLogEntry) -> Bool { a.id == b.id }
}

/// Итог одного прохода сверки.
struct SyncSummary: Equatable, Sendable {
    var pushed = 0
    var pulled = 0
    var deletedHere = 0
    var deletedThere = 0
    var imported = 0
    var conflicts = 0
    var failures = 0

    var isEmpty: Bool { pushed + pulled + deletedHere + deletedThere + imported + conflicts + failures == 0 }
}
