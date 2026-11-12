import Foundation

@MainActor
func runPlannerTests() async {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let f = SyncFields(title: "Позвонить", start: t0.addingTimeInterval(3600))
    func remote(_ ext: String, _ id: UUID?, _ fields: SyncFields, _ m: Date) -> RemoteItem {
        RemoteItem(externalID: ext, appID: id, kind: .reminder, fields: fields, modifiedAt: m)
    }

    await atest("planner: новый элемент выгружается") {
        let a = LocalItem(kind: .reminder, fields: f, updatedAt: t0)
        checkEqual(SyncPlanner.plan(local: [a], remote: [], policy: .ask, window: nil), [.pushCreate(a.id)])
    }

    await atest("planner: изменение в приложении уходит в Календарь") {
        var a = LocalItem(kind: .reminder, fields: f, externalID: "x", updatedAt: t0, syncedAt: t0)
        let r = remote("x", a.id, f, t0)
        a.fields.title = "Позвонить завтра"; a.updatedAt = t0 + 10
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .ask, window: nil), [.pushUpdate(a.id)])
    }

    await atest("planner: изменение в Календаре приходит в приложение") {
        let a = LocalItem(kind: .reminder, fields: f, externalID: "x", updatedAt: t0, syncedAt: t0)
        var g = f; g.isCompleted = true
        let r = remote("x", a.id, g, t0 + 10)
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .ask, window: nil), [.pullUpdate(a.id, r)])
    }

    await atest("planner: изменения с двух сторон по политикам") {
        var a = LocalItem(kind: .reminder, fields: f, externalID: "x", updatedAt: t0 + 20, syncedAt: t0)
        a.fields.title = "А"
        var g = f; g.title = "Б"
        let r = remote("x", a.id, g, t0 + 10)
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .ask, window: nil), [.conflict(a.id, r)])
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .appWins, window: nil), [.pushUpdate(a.id)])
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .newerWins, window: nil), [.pushUpdate(a.id)], "приложение новее")
        let older = remote("x", a.id, g, t0 + 30)
        checkEqual(SyncPlanner.plan(local: [a], remote: [older], policy: .newerWins, window: nil), [.pullUpdate(a.id, older)], "Календарь новее")
    }

    await atest("planner: одинаковое содержимое не порождает действий") {
        let a = LocalItem(kind: .reminder, fields: f, externalID: "x", updatedAt: t0 + 5, syncedAt: t0 + 5)
        checkEqual(SyncPlanner.plan(local: [a], remote: [remote("x", a.id, f, t0)], policy: .ask, window: nil), [])
        var g = f; g.notes = ""
        g.start = f.start!.addingTimeInterval(0.4)
        checkEqual(SyncPlanner.plan(local: [a], remote: [remote("x", a.id, g, t0)], policy: .ask, window: nil), [],
                   "пустые заметки и доли секунды не считаются изменением")
    }

    await atest("planner: удалено в Календаре — удалить в приложении, но только внутри окна") {
        let a = LocalItem(kind: .event, fields: f, externalID: "x", updatedAt: t0, syncedAt: t0)
        let inside = DateInterval(start: t0 - 86400, duration: 86400 * 3)
        checkEqual(SyncPlanner.plan(local: [a], remote: [], policy: .ask, window: inside), [.pullDelete(a.id)])
        let outside = DateInterval(start: t0 + 86400 * 10, duration: 86400)
        checkEqual(SyncPlanner.plan(local: [a], remote: [], policy: .ask, window: outside), [], "вне окна не удаляется")
    }

    await atest("planner: удалено в приложении — удалить в Календаре") {
        let a = LocalItem(kind: .reminder, fields: f, externalID: "x", updatedAt: t0, syncedAt: t0, isDeleted: true)
        checkEqual(SyncPlanner.plan(local: [a], remote: [remote("x", a.id, f, t0)], policy: .ask, window: nil),
                   [.pushDelete(a.id, externalID: "x")])
        let gone = LocalItem(kind: .reminder, fields: f, updatedAt: t0, isDeleted: true)
        checkEqual(SyncPlanner.plan(local: [gone], remote: [], policy: .ask, window: nil), [], "не выгруженный удалённый элемент")
    }

    await atest("planner: новый элемент в Календаре импортируется, чужой UUID не воскрешается") {
        let r = remote("y", nil, f, t0)
        checkEqual(SyncPlanner.plan(local: [], remote: [r], policy: .ask, window: nil), [.importNew(r)])
        let known = LocalItem(kind: .reminder, fields: f, updatedAt: t0, syncEnabled: false)
        let linked = remote("z", known.id, f, t0)
        checkEqual(SyncPlanner.plan(local: [known], remote: [linked], policy: .ask, window: nil), [],
                   "элемент с выключенной синхронизацией не импортируется второй раз")
    }

    await atest("planner: смена id EventKit — перепривязка по UUID") {
        let a = LocalItem(kind: .reminder, fields: f, externalID: "old", updatedAt: t0, syncedAt: t0)
        let r = remote("new", a.id, f, t0)
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .ask, window: nil),
                   [.relink(a.id, externalID: "new"), .markSynced(a.id, modifiedAt: t0)])
    }

    await atest("planner: выключенная синхронизация элемента игнорируется") {
        let a = LocalItem(kind: .reminder, fields: f, updatedAt: t0, syncEnabled: false)
        checkEqual(SyncPlanner.plan(local: [a], remote: [], policy: .ask, window: nil), [])
    }
}

@MainActor
func runLayoutTests() async {
    let t = Date(timeIntervalSinceReferenceDate: 0)
    func h(_ x: Double) -> Date { t.addingTimeInterval(x * 3600) }

    await atest("layout: непересекающиеся события занимают всю ширину") {
        let s = DayLayout.layout([(h(9), h(10)), (h(10), h(11))])
        checkEqual(s.map(\.columns), [1, 1])
        checkEqual(s.map(\.column), [0, 0])
    }

    await atest("layout: пересечения делят ширину, свободная колонка переиспользуется") {
        let s = DayLayout.layout([(h(9), h(11)), (h(9.5), h(10)), (h(10), h(10.5)), (h(12), h(13))])
        let byIndex = Dictionary(uniqueKeysWithValues: s.map { ($0.index, $0) })
        checkEqual(byIndex[0]!.columns, 2)
        checkEqual(byIndex[1]!.column, 1)
        checkEqual(byIndex[2]!.column, 1, "колонка второго события освободилась")
        checkEqual(byIndex[3]!.columns, 1, "отдельная группа")
    }
}

@MainActor
func runEngineTests() async {
    func make() -> (CalendarSyncEngine, FakeGateway, MemoryItemStore, TestClock) {
        let clock = TestClock()
        let gw = FakeGateway(clock: { clock.now })
        let store = MemoryItemStore()
        let defaults = UserDefaults(suiteName: "lab-test-\(UUID().uuidString)")!
        let engine = CalendarSyncEngine(gateway: gw, store: store, defaults: defaults, containerTitle: "Test", now: { clock.now })
        return (engine, gw, store, clock)
    }

    await atest("engine: включение создаёт календарь и выгружает элементы") {
        let (e, gw, store, clock) = make()
        let item = LocalItem(kind: .reminder, fields: SyncFields(title: "Отчёт", start: clock.now + 3600), updatedAt: clock.now)
        store.save(item)
        let enabled = await e.enable(.reminder)
        check(enabled)
        checkEqual(gw.containers(.reminder).count, 1)
        checkEqual(gw.items.count, 1)
        check(store.item(item.id)?.externalID != nil, "id EventKit сохранён")
        check(e.settings.remindersEnabled)
    }

    await atest("engine: отказ в доступе не ломает работу") {
        let (e, gw, store, clock) = make()
        gw.access[.event] = .notDetermined
        gw.grantOnRequest = false
        store.save(LocalItem(kind: .event, fields: SyncFields(title: "Встреча", start: clock.now), updatedAt: clock.now))
        let enabled = await e.enable(.event)
        check(!enabled)
        check(!e.settings.eventsEnabled)
        checkEqual(gw.items.count, 0)
        checkEqual(e.log.first?.level, .warning)
    }

    await atest("engine: 10 циклов правок в обе стороны без дублей") {
        let (e, gw, store, clock) = make()
        _ = await e.enable(.reminder)
        var item = LocalItem(kind: .reminder, fields: SyncFields(title: "v0", start: clock.now + 3600), updatedAt: clock.now)
        store.save(item)
        await e.syncNow()
        for i in 1...10 {
            clock.tick()
            item = store.item(item.id)!
            item.fields.title = "app \(i)"; item.updatedAt = clock.now
            store.save(item)
            await e.syncNow()
            checkEqual(gw.items.values.first?.fields.title, "app \(i)")

            clock.tick()
            gw.userEdit(store.item(item.id)!.externalID!) { $0.title = "cal \(i)"; $0.isCompleted = i % 2 == 0 }
            await e.syncNow()
            checkEqual(store.item(item.id)?.fields.title, "cal \(i)")
            checkEqual(store.item(item.id)?.fields.isCompleted, i % 2 == 0)
        }
        checkEqual(gw.items.count, 1, "в Календаре один элемент")
        checkEqual(store.items.count, 1, "в приложении один элемент")
        let before = gw.upserts
        await e.syncNow()
        await e.syncNow()
        checkEqual(gw.upserts, before, "повторная сверка ничего не пишет")
    }

    await atest("engine: удаление в обе стороны") {
        let (e, gw, store, clock) = make()
        _ = await e.enable(.reminder)
        let a = LocalItem(kind: .reminder, fields: SyncFields(title: "A"), updatedAt: clock.now)
        let b = LocalItem(kind: .reminder, fields: SyncFields(title: "B"), updatedAt: clock.now)
        store.save(a); store.save(b)
        await e.syncNow()
        checkEqual(gw.items.count, 2)

        var da = store.item(a.id)!; da.isDeleted = true; store.save(da)
        gw.userDelete(store.item(b.id)!.externalID!)
        clock.tick()
        await e.syncNow()
        checkEqual(gw.items.count, 0)
        check(store.item(a.id) == nil, "удалённый в приложении элемент забыт")
        checkEqual(store.item(b.id)?.isDeleted, true, "удалённый в Календаре помечен удалённым")
        await e.syncNow()
        checkEqual(gw.items.count, 0, "удалённое не воскресает")
    }

    await atest("engine: импорт созданного в Календаре и привязка по UUID") {
        let (e, gw, store, clock) = make()
        _ = await e.enable(.reminder)
        let list = e.settings.reminderListID!
        let ext = gw.userCreate(.reminder, container: list, title: "Из Напоминаний", start: nil)
        clock.tick()
        await e.syncNow()
        checkEqual(store.items.count, 1)
        checkEqual(store.items.first?.fields.title, "Из Напоминаний")
        check(gw.items[ext]?.appID == store.items.first?.id, "UUID записан обратно в url")

        gw.renameID(ext, to: "renamed")
        await e.syncNow()
        checkEqual(store.items.first?.externalID, "renamed")
        checkEqual(store.items.count, 1, "без дублей после смены id")
    }

    await atest("engine: конфликт и его решение") {
        let (e, gw, store, clock) = make()
        _ = await e.enable(.reminder)
        var item = LocalItem(kind: .reminder, fields: SyncFields(title: "Исходная"), updatedAt: clock.now)
        store.save(item)
        await e.syncNow()
        clock.tick()
        item = store.item(item.id)!
        item.fields.title = "Приложение"; item.updatedAt = clock.now
        store.save(item)
        gw.userEdit(item.externalID!) { $0.title = "Календарь" }
        await e.syncNow()
        checkEqual(e.conflicts.count, 1)
        checkEqual(gw.items.values.first?.fields.title, "Календарь", "до решения ничего не перезаписано")
        await e.resolve(e.conflicts[0], keepApp: false)
        checkEqual(store.item(item.id)?.fields.title, "Календарь")
        checkEqual(e.conflicts.count, 0)
        await e.syncNow()
        checkEqual(e.conflicts.count, 0, "после решения конфликт не повторяется")
    }

    await atest("engine: календарь удалён снаружи — создаётся заново и элементы перевыгружаются") {
        let (e, gw, store, clock) = make()
        _ = await e.enable(.event)
        let item = LocalItem(kind: .event, fields: SyncFields(title: "Встреча", start: clock.now + 3600, end: clock.now + 7200),
                             updatedAt: clock.now)
        store.save(item)
        await e.syncNow()
        let old = e.settings.eventCalendarID!
        try gw.removeContainer(old)
        clock.tick()
        await e.syncNow()
        check(e.settings.eventCalendarID != old, "новый календарь")
        checkEqual(gw.items.count, 1, "событие выгружено заново")
        checkEqual(store.item(item.id)?.isDeleted, false, "событие не удалено в приложении")
    }

    await atest("engine: сбой записи учитывается и повторяется в следующий раз") {
        let (e, gw, store, clock) = make()
        _ = await e.enable(.reminder)
        store.save(LocalItem(kind: .reminder, fields: SyncFields(title: "X"), updatedAt: clock.now))
        gw.failNextUpsert = true
        await e.syncNow()
        checkEqual(e.lastSummary.failures, 1)
        checkEqual(gw.items.count, 0)
        await e.syncNow()
        checkEqual(gw.items.count, 1)
    }
}

@MainActor
func runFixTests() async {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let f = SyncFields(title: "Планёрка", start: t0 + 3600, end: t0 + 5400)

    await atest("planner: связь восстанавливается по содержимому, если url стёрт и id сменился") {
        let a = LocalItem(kind: .event, fields: f, externalID: "old", updatedAt: t0, syncedAt: t0)
        let r = RemoteItem(externalID: "new", appID: nil, kind: .event, fields: f, modifiedAt: t0)
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .ask, window: nil),
                   [.relink(a.id, externalID: "new"), .pushUpdate(a.id)], "без дубля и без удаления, url записывается заново")
    }

    await atest("planner: несохранённая связь после сбоя не даёт дубля при выгрузке") {
        let a = LocalItem(kind: .event, fields: f, updatedAt: t0)
        let r = RemoteItem(externalID: "x", appID: nil, kind: .event, fields: f, modifiedAt: t0)
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .ask, window: nil),
                   [.relink(a.id, externalID: "x"), .pushUpdate(a.id)])
    }

    await atest("planner: повтор входит в содержимое") {
        var g = f; g.recurrence = SyncRecurrence(frequency: .weekly)
        let a = LocalItem(kind: .event, fields: f, externalID: "x", updatedAt: t0, syncedAt: t0)
        let r = RemoteItem(externalID: "x", appID: a.id, kind: .event, fields: g, modifiedAt: t0 + 10)
        checkEqual(SyncPlanner.plan(local: [a], remote: [r], policy: .ask, window: nil), [.pullUpdate(a.id, r)])
        var h = g; h.recurrence?.until = Calendar.current.date(byAdding: .hour, value: 5, to: Calendar.current.startOfDay(for: t0))
        var k = g; k.recurrence?.until = Calendar.current.startOfDay(for: t0)
        check(h.sameContent(as: k), "время в дате окончания повтора не считается изменением")
    }

    await atest("engine: удаление вне окна замечается, событие в другом календаре не удаляется") {
        let clock = TestClock()
        let gw = FakeGateway(clock: { clock.now })
        let store = MemoryItemStore()
        let e = CalendarSyncEngine(gateway: gw, store: store, defaults: UserDefaults(suiteName: "lab-\(UUID())")!,
                                   containerTitle: "T", now: { clock.now })
        _ = await e.enable(.event)
        let far = LocalItem(kind: .event, fields: SyncFields(title: "Через 2 года", start: clock.now + 86400 * 730,
                                                             end: clock.now + 86400 * 730 + 3600), updatedAt: clock.now)
        let moved = LocalItem(kind: .event, fields: SyncFields(title: "Перенесённое", start: clock.now + 3600, end: clock.now + 7200),
                              updatedAt: clock.now)
        store.save(far); store.save(moved)
        await e.syncNow()
        checkEqual(gw.items.count, 2)
        gw.userDelete(store.item(far.id)!.externalID!)
        gw.moveOut(store.item(moved.id)!.externalID!)
        clock.tick()
        await e.syncNow()
        checkEqual(store.item(far.id)?.isDeleted, true, "удаление далеко в будущем замечено")
        checkEqual(store.item(moved.id)?.isDeleted, false, "событие, перенесённое в другой календарь, живо")
    }

    await atest("engine: стёртый url не плодит дублей") {
        let clock = TestClock()
        let gw = FakeGateway(clock: { clock.now })
        let store = MemoryItemStore()
        let e = CalendarSyncEngine(gateway: gw, store: store, defaults: UserDefaults(suiteName: "lab-\(UUID())")!,
                                   containerTitle: "T", now: { clock.now })
        _ = await e.enable(.reminder)
        let a = LocalItem(kind: .reminder, fields: SyncFields(title: "Купить", start: clock.now + 3600), updatedAt: clock.now)
        store.save(a)
        await e.syncNow()
        let ext = store.item(a.id)!.externalID!
        gw.wipeURL(ext)
        gw.renameID(ext, to: "fresh")
        clock.tick()
        await e.syncNow()
        checkEqual(store.items.count, 1)
        checkEqual(gw.items.count, 1)
        checkEqual(store.item(a.id)?.externalID, "fresh")
        checkEqual(gw.items["fresh"]?.appID, a.id, "url записан заново")
    }
}

@MainActor
func runCalendarMathTests() async {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    cal.firstWeekday = 2
    let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 15))!

    await atest("math: неделя с понедельника, сетка месяца 6×7") {
        let w = CalendarMath.weekDays(d, calendar: cal)
        checkEqual(w.count, 7)
        checkEqual(cal.component(.weekday, from: w[0]), 2, "понедельник")
        checkEqual(cal.component(.day, from: w[0]), 9)
        let m = CalendarMath.monthGrid(d, calendar: cal)
        checkEqual(m.count, 42)
        checkEqual(cal.component(.day, from: m[0]), 26, "сетка ноября 2026 начинается 26 октября")
        check(m.contains { cal.component(.day, from: $0) == 30 && cal.component(.month, from: $0) == 11 })
    }

    await atest("math: шаг 15 минут и границы суток") {
        checkEqual(CalendarMath.snap(minutes: 607), 600)
        checkEqual(CalendarMath.snap(minutes: 608), 615)
        checkEqual(CalendarMath.snap(minutes: -20), 0)
        checkEqual(CalendarMath.snap(minutes: 2000), 1440)
    }

    await atest("math: перенос сохраняет длительность, растяжение не короче шага") {
        let s = cal.date(bySettingHour: 10, minute: 0, second: 0, of: d)!
        let e = s.addingTimeInterval(5400)
        let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d))!
        let (ns, ne) = CalendarMath.moved(start: s, end: e, toDay: next, minutes: 14 * 60, calendar: cal)
        checkEqual(cal.component(.hour, from: ns), 14)
        checkEqual(ne.timeIntervalSince(ns), 5400)
        let r = CalendarMath.resized(start: s, toEndMinutes: 9 * 60, day: d, calendar: cal)
        checkEqual(r.timeIntervalSince(s), 900, "конец раньше начала → минимум 15 минут")
    }

    await atest("math: летнее время — часы по циферблату, а не по секундам") {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let day = ny.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let noon = ny.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        checkEqual(CalendarMath.minutes(of: noon, in: day, calendar: ny), 720)
        checkEqual(ny.component(.hour, from: CalendarMath.moment(day, minutes: 720, calendar: ny)), 12)
    }
}
