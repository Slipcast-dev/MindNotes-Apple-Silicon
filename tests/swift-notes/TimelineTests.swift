import Foundation

/// M11: окно шкалы, полосы, перенос и растягивание дат, состояние вида и выборка записей окна.
func runTimelineTests() async {
    func day(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d)! }

    await test("Хронология: окно каждого масштаба и положение дня") {
        let anchor = day(2026, 11, 11) // среда
        let days = TimelineWindow(scale: .day, anchor: anchor)
        checkEqual(days.start, day(2026, 11, 4))
        checkEqual(days.count, 42)
        let weeks = TimelineWindow(scale: .week, anchor: anchor)
        checkEqual(weeks.start, day(2026, 10, 26), "понедельник за две недели до недели опорного дня")
        checkEqual(weeks.start.weekdayFromMonday, 0)
        checkEqual(weeks.count, 182)
        let months = TimelineWindow(scale: .month, anchor: anchor)
        checkEqual(months.start, day(2026, 10, 1))
        checkEqual(months.end, day(2027, 9, 30), "двенадцать месяцев целиком")
        checkEqual(days.x(of: day(2026, 11, 5)), 36)
        checkEqual(days.day(atX: 37), day(2026, 11, 5))
        checkEqual(days.day(atX: -50), days.start, "левее окна — первый день")
        checkEqual(days.day(atX: 1_000_000), days.end, "правее окна — последний день")
        checkEqual(weeks.ticks.count, 26, "деление на каждый понедельник")
        checkEqual(months.ticks.count, 12, "деление на каждое первое число")
        checkEqual(TimelineScale.month.step(day(2026, 1, 31), forward: true), day(2026, 4, 30), "шаг в месяцах не теряет конец месяца")
        checkEqual(TimelineScale.day.step(anchor, forward: false), day(2026, 10, 28))
    }

    await test("Хронология: полоса обрезается краями окна, вне окна не рисуется") {
        let w = TimelineWindow(scale: .day, anchor: day(2026, 3, 8)) // 1 марта … 11 апреля
        let inside = w.bar(DateValue(start: .day(day(2026, 3, 2)), end: .day(day(2026, 3, 4))))
        checkEqual(inside?.x, 36)
        checkEqual(inside?.width, 108, "три дня")
        check(inside?.clippedStart == false && inside?.clippedEnd == false)
        let single = w.bar(DateValue(start: .day(day(2026, 3, 1))))
        checkEqual(single?.width, 36, "одна дата — один день")
        let across = w.bar(DateValue(start: .day(day(2026, 2, 20)), end: .day(day(2026, 5, 1))))
        checkEqual(across?.x, 0)
        checkEqual(across?.width, 42 * 36, "диапазон шире окна занимает его целиком")
        check(across?.clippedStart == true && across?.clippedEnd == true)
        check(w.bar(DateValue(start: .day(day(2026, 2, 1)), end: .day(day(2026, 2, 28)))) == nil, "целиком раньше окна")
        check(w.bar(DateValue(start: .day(day(2026, 4, 12)))) == nil, "целиком позже окна")
    }

    await test("Хронология: перенос и растягивание дат") {
        let a = day(2026, 3, 10), b = day(2026, 3, 12)
        let range = DateValue(start: .day(a), end: .day(b))
        checkEqual(range.moved(byDays: 5), DateValue(start: .day(day(2026, 3, 15)), end: .day(day(2026, 3, 17))), "длина сохраняется")
        checkEqual(range.resized(startBy: -2), DateValue(start: .day(day(2026, 3, 8)), end: .day(b)))
        checkEqual(range.resized(startBy: 9), DateValue(start: .day(b), end: .day(b)), "начало не заходит за конец")
        checkEqual(range.resized(endBy: -9), DateValue(start: .day(a), end: .day(a)), "конец не раньше начала")
        let single = DateValue(start: .day(a))
        checkEqual(single.resized(endBy: 3), DateValue(start: .day(a), end: .day(day(2026, 3, 13))), "одна дата становится диапазоном")
        checkEqual(single.resized(endBy: -3), single, "сжатая одна дата остаётся одной датой")
        checkEqual(single.resized(startBy: -1), DateValue(start: .day(day(2026, 3, 9)), end: .day(a)))
        check(range.resized(startBy: 9).isValid && range.resized(endBy: -9).isValid)

        // Момент: час по часам пояса сохраняется и через переход на летнее время (29 марта 2026 в Берлине).
        let zone = "Europe/Berlin"
        let start = PropertyParse.date("2026-03-27T09:30", zone: zone)!.start
        let shifted = start.adding(days: 3)
        checkEqual(shifted.localText, "2026-03-30T09:30")
        let moment = DateValue(start: start, end: PropertyParse.date("2026-03-27T11:00", zone: zone)!.start)
        let longer = moment.resized(endBy: 2)
        checkEqual(longer.end?.localText, "2026-03-29T11:00")
        check(longer.isValid)
    }

    await test("Хронология: масштаб хранится в состоянии вида, старое состояние не меняется") {
        var state = DatabaseViewState()
        checkEqual(state.timelineScale, .week, "по умолчанию недели")
        let plain = try state.jsonString()
        check(!plain.contains("timelineScale"), "масштаб по умолчанию не пишется: JSON прежних видов тот же")
        state.timelineScale = .month
        let json = try state.jsonString()
        checkEqual(DatabaseViewState(json: json).timelineScale, .month)
        let filterProp = UUID()
        var withFilter = DatabaseViewState()
        withFilter.filter = FilterGroup(mode: .and, items: [.rule(FilterRule(property: filterProp, op: .isEmpty, value: ""))])
        withFilter.sorts = [SortRule(property: filterProp)]
        var raw = try withFilter.jsonString()
        raw.removeLast()
        raw += #","timelineScale":"quarter"}"#
        let future = DatabaseViewState(json: raw)
        checkEqual(future.timelineScale, .week, "незнакомый масштаб показывается неделями")
        checkEqual(future.filter, withFilter.filter, "незнакомый масштаб не стирает фильтр")
        checkEqual(future.sorts, withFilter.sorts, "и сортировку")
        let futureJSON = try future.jsonString()
        check(futureJSON.contains(#""timelineScale":"quarter""#), "незнакомый масштаб записывается обратно как был")
        var chosen = future
        chosen.timelineScale = .day
        checkEqual(DatabaseViewState(json: try chosen.jsonString()).timelineScale, .day, "выбранный масштаб важнее сохранённого незнакомого")
        check(DatabaseView.knownKinds.contains(DatabaseView.timelineKind))
        check(DatabaseView.usesDate(DatabaseView.timelineKind) && DatabaseView.usesDate(DatabaseView.calendarKind))
        check(!DatabaseView.usesDate(DatabaseView.boardKind))
    }

    await test("Хронология: вид новой базы, выборка окна, группы и записи без даты") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "Проекты", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["План", "Готово"], dateProperty: "Срок", viewName: "Таблица",
                                                                                 extraViews: [("Хронология", DatabaseView.timelineKind)]), ids: RandomIDs(), now: 1)
            checkEqual(d.views.map(\.kind), [DatabaseView.tableKind, DatabaseView.timelineKind])
            let date = d.properties.first { $0.type == .date }!, status = d.properties.first { $0.type == .status }!
            func add(_ title: String, _ value: DateValue?, _ option: Int) async throws {
                let id = UUID()
                try await w.createRecord(database: d.id, title: title, id: id, now: 2)
                if let value { try await w.setValue(pages: [id], property: date.id, value: .date(value), now: 3) }
                try await w.setValue(pages: [id], property: status.id, value: .options([status.options[option].id]), now: 3)
            }
            try await add("Внутри", DateValue(start: .day(day(2026, 3, 5)), end: .day(day(2026, 3, 9))), 0)
            try await add("Через левый край", DateValue(start: .day(day(2026, 2, 1)), end: .day(day(2026, 3, 2))), 1)
            try await add("Через всё окно", DateValue(start: .day(day(2025, 1, 1)), end: .day(day(2027, 1, 1))), 0)
            try await add("Раньше", DateValue(start: .day(day(2026, 1, 1))), 0)
            try await add("Позже", DateValue(start: .day(day(2026, 6, 1))), 1)
            try await add("Без даты", nil, 1)
            let fresh = try await w.database(d.id)!
            let window = TimelineWindow(scale: .day, anchor: day(2026, 3, 8))
            let state = fresh.views[1].state
            let inWindow = state.narrowed(by: [FilterRule(property: date.id, op: .greaterOrEqual, value: window.start.iso),
                                               FilterRule(property: date.id, op: .lessOrEqual, value: window.end.iso)])
            let all = try await w.queryRecords(database: fresh, state: inWindow, limit: 1000, offset: 0)
            checkEqual(Set(all.rows.map(\.title)), ["Внутри", "Через левый край", "Через всё окно"], "диапазон, задевающий окно, попадает в выборку")
            let property = state.groupProperty(fresh.properties, kind: DatabaseView.timelineKind)
            checkEqual(property?.id, nil, "без выбора хронология не группируется")
            var grouped: [String: Set<String>] = [:]
            for group in RecordGroup.groups(for: status, people: []) {
                let page = try await w.queryRecords(database: fresh, state: inWindow.narrowed(by: [group.rule]), limit: 1000, offset: 0)
                grouped[group.option?.name ?? "—"] = Set(page.rows.map(\.title))
            }
            checkEqual(grouped["План"], ["Внутри", "Через всё окно"])
            checkEqual(grouped["Готово"], ["Через левый край"])
            let undated = try await w.queryRecords(database: fresh, state: state.narrowed(by: [FilterRule(property: date.id, op: .isEmpty, value: "")]), limit: 100, offset: 0)
            checkEqual(undated.rows.map(\.title), ["Без даты"])
            let capped = try await w.queryRecords(database: fresh, state: inWindow, limit: 2, offset: 0)
            checkEqual(capped.rows.count, 2)
            checkEqual(capped.total, 3, "предел режет строки, но общее число известно — для предупреждения")
        }
    }
}
