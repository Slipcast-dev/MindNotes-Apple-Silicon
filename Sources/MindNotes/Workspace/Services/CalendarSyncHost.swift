import Foundation
import Observation

/// Синхронизация одного пространства MindNotes: движок, хранилище записей, связки баз.
/// Создаётся в `ShellModel` после открытия пространства и закрывается вместе с ним. При переносе: `Workspace/Services/`.
@MainActor
@Observable
final class CalendarSyncHost {
    let engine: CalendarSyncEngine
    let store: DatabaseItemStore
    @ObservationIgnored let source: CalendarRecordSource
    private(set) var bindings: [CalendarBinding]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bindingsKey: String

    /// - Parameters:
    ///   - workspaceID: связи и связки хранятся отдельно для каждого пространства.
    ///   - supportDir: каталог данных приложения этой сборки (с учётом `AppDataScope`).
    init(source: CalendarRecordSource, workspaceID: UUID, supportDir: URL, gateway: CalendarGateway,
         defaults: UserDefaults = .standard, containerTitle: String = "MindNotes") {
        self.source = source
        self.defaults = defaults
        bindingsKey = "calendarSync.bindings.\(workspaceID.uuidString.lowercased())"
        let saved = defaults.data(forKey: bindingsKey).flatMap { try? JSONDecoder().decode([CalendarBinding].self, from: $0) } ?? []
        bindings = saved
        store = DatabaseItemStore(source: source, bindings: saved,
                                  linksFile: supportDir.appendingPathComponent("CalendarSync/\(workspaceID.uuidString.lowercased()).json"))
        engine = CalendarSyncEngine(gateway: gateway, store: store, defaults: defaults,
                                    settingsKey: "calendarSync.settings.\(workspaceID.uuidString.lowercased())",
                                    containerTitle: containerTitle)
    }

    func binding(for database: UUID) -> CalendarBinding? { bindings.first { $0.databaseID == database } }

    func setBinding(_ b: CalendarBinding) {
        if let i = bindings.firstIndex(where: { $0.databaseID == b.databaseID }) { bindings[i] = b } else { bindings.append(b) }
        commit()
    }

    /// Отвязать базу: элементы в Календаре остаются, но больше не обновляются.
    func removeBinding(_ database: UUID) {
        bindings.removeAll { $0.databaseID == database }
        store.forget(database: database)
        commit()
    }

    /// Вызывается после изменений записей в MindNotes (например, из `pagesChanged`).
    func recordsChanged() {
        guard bindings.contains(where: \.enabled) else { return }
        engine.scheduleSync()
    }

    private func commit() {
        store.setBindings(bindings)
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: bindingsKey) }
        engine.scheduleSync()
    }
}
