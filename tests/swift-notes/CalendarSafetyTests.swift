import Foundation

/// Источник записей, который по флагам отказывает в записи: имитация ошибки SQLite (диск заполнен, блокировка).
@MainActor
final class FailingRecordSource: CalendarRecordSource {
    let base: CalendarRecordSource
    var failWrites = false
    struct Refused: Error {}
    init(_ base: CalendarRecordSource) { self.base = base }
    func calendarDatabases() async throws -> [CalendarDatabaseInfo] { try await base.calendarDatabases() }
    func calendarDatabase(_ id: UUID) async throws -> Database? { try await base.calendarDatabase(id) }
    func calendarRecords(_ database: Database) async throws -> [RecordRow] { try await base.calendarRecords(database) }
    func calendarCreateRecord(database: UUID, title: String, id: UUID) async throws {
        if failWrites { throw Refused() }
        try await base.calendarCreateRecord(database: database, title: title, id: id)
    }
    func calendarRename(record: UUID, title: String) async throws {
        if failWrites { throw Refused() }
        try await base.calendarRename(record: record, title: title)
    }
    func calendarSetValue(record: UUID, property: UUID, value: PropertyValue?) async throws {
        if failWrites { throw Refused() }
        try await base.calendarSetValue(record: record, property: property, value: value)
    }
    func calendarTrash(records: [UUID]) async throws {
        if failWrites { throw Refused() }
        try await base.calendarTrash(records: records)
    }
}

/// Отвязка баз и ошибки записи не должны удалять или перезаписывать элементы Календаря и Напоминаний.
@MainActor
func runCalendarSafetyTests() async {
    let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                               statusOptions: ["Запланировано", "Готово"], dateProperty: "Срок", viewName: "Таблица")
    struct Rig {
        let w: SQLiteWorkspace, db: Database, host: CalendarSyncHost, gw: FakeGateway, clock: TestClock, source: FailingRecordSource
        let defaults: UserDefaults, support: URL, workspaceID: UUID
    }
    func setup(_ dir: URL, bind: Bool = true) async throws -> Rig {
        let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
        let db = try await w.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
        let clock = TestClock()
        clock.now = Date()
        let gw = FakeGateway(clock: { clock.now })
        let source = FailingRecordSource(w)
        let defaults = UserDefaults(suiteName: "calsafety-\(UUID())")!
        let support = dir.appendingPathComponent("support"), wid = UUID()
        let host = CalendarSyncHost(source: source, workspaceID: wid, supportDir: support, gateway: gw, defaults: defaults, containerTitle: "T")
        if bind { host.setBinding(RecordCalendarMapping.defaultBinding(db, kind: .reminder)!) }
        return Rig(w: w, db: db, host: host, gw: gw, clock: clock, source: source, defaults: defaults, support: support, workspaceID: wid)
    }
    func tick(_ c: TestClock) async { c.tick(); try? await Task.sleep(for: .milliseconds(5)) }
    func syncTimes(_ r: Rig, _ n: Int) async { for _ in 0..<n { await tick(r.clock); await r.host.engine.syncNow() } }

    await atest("календарь: после отвязки последней базы несколько сверок и перезапуск не удаляют задачи") {
        try await withTempDir { dir in
            let r = try await setup(dir)
            defer { r.w.close() }
            try await r.w.createRecord(database: r.db.id, title: "Оставить", id: UUID(), now: 2)
            _ = await r.host.engine.enable(.reminder)
            checkEqual(r.gw.items.count, 1)
            let ext = r.gw.items.keys.first!
            let urlBefore = r.gw.items[ext]?.appID
            r.host.removeBinding(r.db.id)
            await syncTimes(r, 4)
            checkEqual(r.gw.items.count, 1, "задача осталась после нескольких сверок")
            checkEqual(r.gw.items[ext]?.appID, urlBefore, "элемент в Напоминаниях не переписан")
            // Перезапуск: новый хост с теми же настройками и файлом связей.
            let again = CalendarSyncHost(source: r.source, workspaceID: r.workspaceID, supportDir: r.support, gateway: r.gw,
                                         defaults: r.defaults, containerTitle: "T")
            for _ in 0..<3 { await tick(r.clock); await again.engine.syncNow() }
            checkEqual(r.gw.items.count, 1, "задача осталась после перезапуска")
            checkEqual(try await r.w.calendarRecords(r.db).count, 1, "в базу ничего не добавлено")
        }
    }

    await atest("календарь: включённый вид без связанной базы не трогает существующие элементы") {
        try await withTempDir { dir in
            let r = try await setup(dir, bind: false)
            defer { r.w.close() }
            _ = await r.host.engine.enable(.reminder)
            let container = r.host.engine.settings.containerID(.reminder)!
            let ext = r.gw.userCreate(.reminder, container: container, title: "Чужая задача", start: nil)
            await syncTimes(r, 4)
            check(r.gw.items[ext] != nil, "элемент не удалён")
            checkEqual(r.gw.items[ext]?.appID, nil, "url элемента не переписан")
        }
    }

    await atest("календарь: ошибка записи правки из Напоминаний не перезаписывает её старой версией") {
        try await withTempDir { dir in
            let r = try await setup(dir)
            defer { r.w.close() }
            let id = UUID()
            try await r.w.createRecord(database: r.db.id, title: "A", id: id, now: 2)
            _ = await r.host.engine.enable(.reminder)
            let ext = r.gw.items.keys.first!
            await tick(r.clock)
            r.gw.userEdit(ext) { $0.title = "B" }
            r.source.failWrites = true
            await r.host.engine.syncNow()
            checkEqual(r.gw.items[ext]?.fields.title, "B", "во время отказа Напоминания не тронуты")
            r.source.failWrites = false
            await syncTimes(r, 3)
            checkEqual(r.gw.items[ext]?.fields.title, "B", "правка из Напоминаний не затёрта старой версией")
            checkEqual(try await r.w.calendarRecords(r.db).first { $0.id == id }?.title, "B", "после повтора правка пришла в запись")
        }
    }

    await atest("календарь: неудачное создание записи из нового элемента не удаляет его") {
        try await withTempDir { dir in
            let r = try await setup(dir)
            defer { r.w.close() }
            _ = await r.host.engine.enable(.reminder)
            let container = r.host.engine.settings.containerID(.reminder)!
            let ext = r.gw.userCreate(.reminder, container: container, title: "Из Напоминаний", start: nil)
            r.source.failWrites = true
            await syncTimes(r, 1)
            r.source.failWrites = false
            await syncTimes(r, 3)
            check(r.gw.items[ext] != nil, "элемент в Напоминаниях не удалён")
            checkEqual(try await r.w.calendarRecords(r.db).map(\.title), ["Из Напоминаний"], "после повтора запись создана")
        }
    }
}
