import Foundation

/// M11: окно шкалы, полосы, перенос и растягивание дат, состояние вида и выборка записей окна.
func runTimelineTests() async {
    func day(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d)! }

    await test("Хронология: шкала растёт порциями в обе стороны и не бесконечно") {
        let anchor = day(2026, 11, 11)
        let w = TimelineWindow(scale: .day, anchor: anchor)
        checkEqual(w.start, day(2026, 8, 13), "порция до опорного дня")
        checkEqual(w.count, 270, "и две после")
        checkEqual(w.x(of: anchor), 90 * 36)
        let left = w.extended(before: true)
        checkEqual(left.window.start, day(2026, 5, 15))
        checkEqual(left.shift, 90 * 36, "прокрутка сдвигается на ширину порции — видимый день на месте")
        checkEqual(left.window.x(of: anchor) - left.shift, w.x(of: anchor))
        let right = w.extended(before: false)
        checkEqual(right.window.start, w.start)
        checkEqual(right.shift, 0)
        checkEqual(right.window.count, 360)
        var grown = w
        while grown.canGrow { grown = grown.extended(before: false).window }
        checkEqual(grown.count, TimelineScale.day.maxDays, "у предела шкала перестаёт расти")
        checkEqual(w.day(atX: 37), day(2026, 8, 14))
        checkEqual(w.day(atX: -50), w.start, "левее шкалы — первый день")
        checkEqual(w.day(atX: 1_000_000), w.end, "правее — последний")
        let weeks = TimelineWindow(scale: .week, anchor: anchor)
        check(weeks.ticks.allSatisfy { $0.day.weekdayFromMonday == 0 }, "деления недель — понедельники")
        let months = TimelineWindow(scale: .month, anchor: anchor)
        check(months.ticks.allSatisfy { $0.day.day == 1 }, "деления месяцев — первые числа")
        let hours = TimelineWindow(scale: .hour, anchor: anchor)
        checkEqual(hours.ticks.count, hours.count * 24, "в масштабе «Часы» деление на каждый час")
        checkEqual(TimelineScale.hour.snapMinutes(moment: true), 15)
        checkEqual(TimelineScale.hour.snapMinutes(moment: false), 1440, "день без времени прилипает к дням")
        checkEqual(TimelineScale.day.snapMinutes(moment: true), 1440)
    }

    await test("Хронология: полоса обрезается краями шкалы, вне её не рисуется") {
        let w = TimelineWindow(scale: .day, start: day(2026, 3, 1), count: 42) // 1 марта … 11 апреля
        let inside = w.bar(DateValue(start: .day(day(2026, 3, 2)), end: .day(day(2026, 3, 4))))
        checkEqual(inside?.x, 36)
        checkEqual(inside?.width, 108, "три дня")
        check(inside?.clippedStart == false && inside?.clippedEnd == false)
        let single = w.bar(DateValue(start: .day(day(2026, 3, 1))))
        checkEqual(single?.width, 36, "одна дата — один день")
        let across = w.bar(DateValue(start: .day(day(2026, 2, 20)), end: .day(day(2026, 5, 1))))
        checkEqual(across?.x, 0)
        checkEqual(across?.width, 42 * 36, "диапазон шире шкалы занимает её целиком")
        check(across?.clippedStart == true && across?.clippedEnd == true)
        check(w.bar(DateValue(start: .day(day(2026, 2, 1)), end: .day(day(2026, 2, 28)))) == nil, "целиком раньше")
        check(w.bar(DateValue(start: .day(day(2026, 4, 12)))) == nil, "целиком позже")
    }

    await test("Хронология: время суток — полоса момента стоит по часам") {
        let zone = TimeZone.current.identifier
        let hours = TimelineWindow(scale: .hour, start: day(2026, 3, 10), count: 3)
        let meeting = PropertyParse.date("2026-03-11T09:30 — 2026-03-11T11:00", zone: zone)!
        let bar = hours.bar(meeting)!
        let perHour = TimelineScale.hour.dayWidth / 24
        checkEqual(bar.x, TimelineScale.hour.dayWidth + 9.5 * perHour, "начало — 9:30 второго дня")
        checkEqual(bar.width, 1.5 * perHour, "полтора часа")
        let point = PropertyParse.date("2026-03-11T09:30", zone: zone)!
        checkEqual(hours.bar(point)?.width, 6, "момент без конца — узкая метка")
        let days = TimelineWindow(scale: .day, start: day(2026, 3, 10), count: 3)
        let dayBar = days.bar(meeting)!
        checkEqual(dayBar.x, 36 + 36 * 9.5 / 24, "и в масштабе «Дни» полоса начинается с 9:30")
        checkEqual(point.start.dayFraction, 9.5 / 24)
        checkEqual(DatePoint.day(day(2026, 3, 11)).dayFraction, 0)
        let late = meeting.moved(byMinutes: 45)
        checkEqual(late.start.localText, "2026-03-11T10:15")
        checkEqual(late.end?.localText, "2026-03-11T11:45", "длина сохраняется")
        checkEqual(meeting.resized(endByMinutes: 30).end?.localText, "2026-03-11T11:30")
        checkEqual(meeting.resized(startByMinutes: 600).start, meeting.end!, "начало не уходит за конец")
        let plain = DateValue(start: .day(day(2026, 3, 11)))
        checkEqual(plain.moved(byMinutes: 2 * 1440), DateValue(start: .day(day(2026, 3, 13))), "день сдвигается целыми сутками")
        checkEqual(DatePoint.day(day(2026, 3, 11)).adding(minutes: 90), .day(day(2026, 3, 11)), "день без времени минуты не берёт")
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
        var remembered = DatabaseViewState()
        remembered.timelineDay = day(2026, 5, 4)
        let dep = UUID()
        remembered.dependencyProperty = dep
        let back = DatabaseViewState(json: try remembered.jsonString())
        checkEqual(back.timelineDay, day(2026, 5, 4), "положение шкалы запоминается")
        checkEqual(back.dependencyProperty, dep)
        checkEqual(DatabaseViewState(json: #"{"timelineDay":"2026-02-30"}"#).timelineDay, nil, "несуществующий день не читается")
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
            let window = TimelineWindow(scale: .day, start: day(2026, 3, 1), count: 42)
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

    await test("Хронология: раскладка строк и место переноса строки") {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let layout = TimelineLayout(sections: [("plan", true, [a, b]), ("done", true, [c]), ("none", true, [d])])
        checkEqual(layout.height, 36 * 3 + 30 * 4)
        checkEqual(layout.midY(a), 36 + 15)
        checkEqual(layout.midY(c), 36 + 60 + 36 + 15)
        checkEqual(layout.record(atY: 40), a)
        checkEqual(layout.record(atY: 10), nil, "заголовок группы — не запись")
        func drop(_ id: UUID, _ y: Double) -> String {
            guard let r = layout.drop(id, atY: y) else { return "nil" }
            return "\(r.section):\(r.before.map { [a: "a", b: "b", c: "c", d: "d"][$0]! } ?? "end")"
        }
        checkEqual(drop(b, 40), "plan:a", "верхняя половина строки — перед ней")
        checkEqual(drop(a, 36 + 30 + 20), "plan:end", "нижняя половина последней строки — в конец группы")
        checkEqual(drop(a, 140), "done:c", "на заголовок другой группы — в её начало")
        checkEqual(drop(c, 36 + 60 + 36 + 25), "done:end", "своя строка не считается местом")
        checkEqual(drop(d, -20), "plan:a", "выше всего — в начало первой группы")
        checkEqual(drop(a, 10_000), "none:end", "ниже всего — в конец последней")
        let plain = TimelineLayout(sections: [("all", false, [a, b])])
        checkEqual(plain.midY(a), 15, "без группировки заголовков нет")
    }

    await test("Хронология: стрелки зависимостей и конфликт сроков") {
        let a = UUID(), b = UUID(), c = UUID(), gone = UUID()
        let values: [UUID: DateValue] = [
            a: DateValue(start: .day(day(2026, 3, 1)), end: .day(day(2026, 3, 5))),
            b: DateValue(start: .day(day(2026, 3, 5))),
            c: DateValue(start: .day(day(2026, 3, 3))),
        ]
        let arrows = TimelineDependency.arrows(values: values, links: [b: [a], c: [a, gone, c]])
        checkEqual(arrows.count, 2, "запись вне шкалы и ссылка на себя пропускаются")
        checkEqual(arrows.first { $0.to == b }?.conflict, false, "начало в день окончания — не конфликт")
        checkEqual(arrows.first { $0.to == c }?.conflict, true, "начало раньше окончания — конфликт")
        let zone = "Europe/Moscow"
        let m1 = PropertyParse.date("2026-03-01T10:00 — 2026-03-01T12:00", zone: zone)!
        let m2 = PropertyParse.date("2026-03-01T11:00", zone: zone)!
        checkEqual(TimelineDependency.arrows(values: [a: m1, b: m2], links: [b: [a]]).first?.conflict, true, "моменты сравниваются по времени")
    }

    await test("Хронология: зависимости хранятся связью базы с самой собой") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "План", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["План"], dateProperty: "Срок", viewName: "Таблица"), ids: RandomIDs(), now: 1)
            let dep = UUID(), pair = UUID(), x = UUID(), y = UUID()
            try await w.addRelation(database: d.id, name: "Зависит от", target: d.id, twoWay: true, pairName: "Блокирует", id: dep, pairID: pair, now: 2)
            try await w.createRecord(database: d.id, title: "Фундамент", id: x, now: 3)
            try await w.createRecord(database: d.id, title: "Стены", id: y, now: 3)
            try await w.setValue(pages: [y], property: dep, value: .relation([LinkedPage(id: x, title: "")]), now: 4)
            let fresh = try await w.database(d.id)!
            var state = DatabaseViewState()
            state.dependencyProperty = dep
            checkEqual(state.dependencyProperty(fresh.properties, database: d.id)?.id, dep)
            state.dependencyProperty = fresh.properties.first { $0.type == .date }!.id
            checkEqual(state.dependencyProperty(fresh.properties, database: d.id)?.id, nil, "не связь — стрелок нет")
            if case .relation(let back)? = try await w.recordValues(page: x, database: fresh)[pair] {
                checkEqual(back.map(\.id), [y], "обратная сторона: «Фундамент» блокирует «Стены»")
            } else { check(false, "обратная сторона пуста") }
        }
    }
}
