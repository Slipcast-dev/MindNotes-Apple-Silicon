import Foundation

/// Адаптер на настоящем временном пространстве MindNotes (SQLite) и подделке EventKit.
@MainActor
func runAdapterTests() async throws {
    let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                               statusOptions: ["Запланировано", "Готово"], dateProperty: "Срок", viewName: "Таблица")

    func setup(_ dir: URL, kind: SyncKind) async throws -> (SQLiteWorkspace, Database, CalendarSyncHost, FakeGateway, TestClock) {
        let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
        var db = try await w.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
        try await w.addProperty(database: db.id, name: "Сделано", type: .checkbox, id: UUID(), now: 1)
        try await w.addProperty(database: db.id, name: "Заметки", type: .text, id: UUID(), now: 1)
        db = try await w.database(db.id)!
        let clock = TestClock()
        clock.now = Date()
        let gw = FakeGateway(clock: { clock.now })
        let host = CalendarSyncHost(source: w, workspaceID: UUID(), supportDir: dir.appendingPathComponent("support"), gateway: gw,
                                    defaults: UserDefaults(suiteName: "adapter-\(UUID())")!, containerTitle: "T")
        var b = RecordCalendarMapping.defaultBinding(db, kind: kind)!
        b.notesProperty = db.properties.first { $0.type == .text }?.id
        host.setBinding(b)
        return (w, db, host, gw, clock)
    }
    func prop(_ db: Database, _ type: PropertyType) -> UUID { db.properties.first { $0.type == type }!.id }
    func tick(_ c: TestClock) async { c.tick(); try? await Task.sleep(for: .milliseconds(5)) }

    await atest("adapter: запись базы → задача Напоминаний и обратно") {
        try await withTempDir { dir in
            let (w, db, host, gw, clock) = try await setup(dir, kind: .reminder)
            defer { w.close() }
            let id = UUID()
            try await w.createRecord(database: db.id, title: "Сдать отчёт", id: id, now: 2)
            let due = Date(timeIntervalSince1970: 1_900_000_000)
            try await w.setValue(pages: [id], property: prop(db, .date),
                                 value: .date(DateValue(start: .moment(ms: 1_900_000_000_000, zone: "Europe/Moscow"))), now: 3)
            _ = await host.engine.enable(.reminder)
            checkEqual(gw.items.count, 1, "задача выгружена")
            let r = gw.items.values.first!
            checkEqual(r.fields.title, "Сдать отчёт")
            checkEqual(r.fields.start, due)
            checkEqual(r.appID, id, "url указывает на запись")

            await tick(clock)
            gw.userEdit(r.externalID) { $0.isCompleted = true; $0.title = "Сдать отчёт (готово)"; $0.notes = "из Напоминаний" }
            await host.engine.syncNow()
            let rows = try await w.calendarRecords(db)
            checkEqual(rows.first?.title, "Сдать отчёт (готово)", "название пришло в запись")
            checkEqual(rows.first?.values[prop(db, .checkbox)], .checkbox(true), "флажок «Сделано»")
            checkEqual(rows.first?.values[prop(db, .text)], .text("из Напоминаний"), "заметки")

            let before = gw.upserts
            await host.engine.syncNow()
            await host.engine.syncNow()
            checkEqual(gw.upserts, before, "повторная сверка ничего не пишет")
        }
    }

    await atest("adapter: событие на весь день и диапазон дат не «скачут»") {
        try await withTempDir { dir in
            let (w, db, host, gw, _) = try await setup(dir, kind: .event)
            defer { w.close() }
            let id = UUID()
            try await w.createRecord(database: db.id, title: "Отпуск", id: id, now: 2)
            let a = LocalDate(iso: "2026-12-20")!, b = LocalDate(iso: "2026-12-27")!
            try await w.setValue(pages: [id], property: prop(db, .date), value: .date(DateValue(start: .day(a), end: .day(b))), now: 3)
            _ = await host.engine.enable(.event)
            checkEqual(gw.items.count, 1)
            check(gw.items.values.first!.fields.isAllDay, "на весь день")
            // EventKit хранит конец как 23:59:59 последнего дня.
            gw.userEdit(gw.items.keys.first!) { $0.end = Calendar.current.startOfDay(for: b.date(in: .current)).addingTimeInterval(86399) }
            let before = gw.upserts
            await host.engine.syncNow()
            checkEqual(gw.upserts, before, "23:59:59 не считается изменением")
            let rows = try await w.calendarRecords(db)
            checkEqual(rows.first?.values[prop(db, .date)], .date(DateValue(start: .day(a), end: .day(b))), "даты в базе прежние")
        }
    }

    await atest("adapter: запись в корзине удаляется из Календаря, удаление в Календаре кладёт запись в корзину") {
        try await withTempDir { dir in
            let (w, db, host, gw, clock) = try await setup(dir, kind: .reminder)
            defer { w.close() }
            let a = UUID(), b = UUID()
            try await w.createRecord(database: db.id, title: "A", id: a, now: 2)
            try await w.createRecord(database: db.id, title: "B", id: b, now: 2)
            _ = await host.engine.enable(.reminder)
            checkEqual(gw.items.count, 2)
            try await w.trashRecords([a], ids: RandomIDs(), now: 5)
            gw.userDelete(gw.items.values.first { $0.appID == b }!.externalID)
            await tick(clock)
            await host.engine.syncNow()
            checkEqual(gw.items.count, 0, "A удалена из Напоминаний")
            checkEqual(try await w.calendarRecords(db).count, 0, "B в корзине MindNotes")
        }
    }

    await atest("adapter: задача, созданная в Напоминаниях, становится записью базы") {
        try await withTempDir { dir in
            let (w, db, host, gw, clock) = try await setup(dir, kind: .reminder)
            defer { w.close() }
            _ = await host.engine.enable(.reminder)
            gw.userCreate(.reminder, container: host.engine.settings.reminderListID!, title: "Из Напоминаний", start: nil)
            await tick(clock)
            await host.engine.syncNow()
            let rows = try await w.calendarRecords(db)
            checkEqual(rows.map(\.title), ["Из Напоминаний"])
            checkEqual(gw.items.values.first?.appID, rows.first?.id, "url указывает на новую запись")
            await host.engine.syncNow()
            checkEqual(try await w.calendarRecords(db).count, 1, "без дублей")
        }
    }

    await atest("adapter: правка в MindNotes уходит в Календарь, приоритет из Напоминаний не стирается") {
        try await withTempDir { dir in
            let (w, db, host, gw, clock) = try await setup(dir, kind: .reminder)
            defer { w.close() }
            let id = UUID()
            try await w.createRecord(database: db.id, title: "Позвонить", id: id, now: 2)
            _ = await host.engine.enable(.reminder)
            let ext = gw.items.keys.first!
            await tick(clock)
            gw.userEdit(ext) { $0.priority = 1 }
            await host.engine.syncNow()
            await tick(clock)
            try await w.calendarRename(record: id, title: "Позвонить завтра")
            host.recordsChanged()
            await host.engine.syncNow()
            checkEqual(gw.items[ext]?.fields.title, "Позвонить завтра")
            checkEqual(gw.items[ext]?.fields.priority, 1, "приоритет сохранён")
        }
    }

    await atest("adapter: отвязка базы не удаляет элементы в Календаре") {
        try await withTempDir { dir in
            let (w, db, host, gw, _) = try await setup(dir, kind: .reminder)
            defer { w.close() }
            try await w.createRecord(database: db.id, title: "Оставить", id: UUID(), now: 2)
            _ = await host.engine.enable(.reminder)
            host.removeBinding(db.id)
            await host.engine.syncNow()
            checkEqual(gw.items.count, 1)
        }
    }
}
