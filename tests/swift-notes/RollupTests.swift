import Foundation

private func base(_ w: SQLiteWorkspace, _ title: String) async throws -> Database {
    try await w.createDatabase(parent: nil, template: NewDatabase(title: title, titleProperty: "Название", statusProperty: "Статус",
                                                                  statusOptions: ["Новая", "Готово"], dateProperty: "Срок", viewName: "Таблица"),
                               ids: RandomIDs(), now: 1)
}

private func add(_ w: SQLiteWorkspace, _ d: Database, _ title: String) async throws -> UUID {
    let id = UUID()
    try await w.createRecord(database: d.id, title: title, id: id, now: 2)
    return id
}

private func fresh(_ w: SQLiteWorkspace, _ d: Database) async throws -> Database {
    guard let x = try await w.database(d.id) else { throw WorkspaceError.corrupted("нет базы") }
    return x
}

private func link(_ ids: UUID...) -> PropertyValue { .relation(ids.map { LinkedPage(id: $0, title: "") }) }

private func withSpace(_ body: (SQLiteWorkspace) async throws -> Void) async throws {
    try await withTempDir { dir in
        let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
        defer { w.close() }
        try await body(w)
    }
}

/// Проекты ← задачи: у задачи «Часы» и связь «Проект», у проекта обратная сторона «Задачи».
private struct Setup {
    var projects: Database
    var tasks: Database
    var forward: UUID
    var back: UUID
    var hours: UUID

    static func make(_ w: SQLiteWorkspace) async throws -> Setup {
        let projects = try await base(w, "Проекты"), tasks = try await base(w, "Задачи")
        let forward = UUID(), back = UUID(), hours = UUID()
        try await w.addRelation(database: tasks.id, name: "Проект", target: projects.id, twoWay: true, pairName: "Задачи", id: forward, pairID: back, now: 1)
        try await w.addProperty(database: tasks.id, name: "Часы", type: .number, id: hours, now: 1)
        return Setup(projects: try await fresh(w, projects), tasks: try await fresh(w, tasks), forward: forward, back: back, hours: hours)
    }

    func rollup(_ w: SQLiteWorkspace, _ aggregate: RollupAggregate, property: UUID? = nil, name: String = "Свёртка") async throws -> UUID {
        let id = UUID()
        try await w.addRollup(database: projects.id, name: name, relation: back, property: property ?? hours, aggregate: aggregate, id: id, now: 3)
        return id
    }
}

private func value(_ w: SQLiteWorkspace, _ d: Database, _ page: UUID, _ property: UUID) async throws -> PropertyValue? {
    try await w.recordValues(page: page, database: try await fresh(w, d))[property]
}

func runRollupTests() async {
    await test("Свёртки: агрегаты над значениями") {
        let n: [PropertyValue?] = [.number(4), nil, .number(1), .number(10), .text("")]
        checkEqual(RollupMath.compute(.count, values: n), .number(5))
        checkEqual(RollupMath.compute(.countValues, values: n), .number(3))
        checkEqual(RollupMath.compute(.countEmpty, values: n), .number(2))
        checkEqual(RollupMath.compute(.percentEmpty, values: n), .number(40))
        checkEqual(RollupMath.compute(.sum, values: n), .number(15))
        checkEqual(RollupMath.compute(.average, values: n), .number(5))
        checkEqual(RollupMath.compute(.median, values: n), .number(4))
        checkEqual(RollupMath.compute(.median, values: [.number(1), .number(2), .number(3), .number(10)]), .number(2.5), "чётное число")
        checkEqual(RollupMath.compute(.min, values: n), .number(1))
        checkEqual(RollupMath.compute(.max, values: n), .number(10))
        checkEqual(RollupMath.compute(.range, values: n), .number(9))
        checkEqual(RollupMath.compute(.average, values: [.number(1), .number(2), .number(2)]), .number(1.67), "округление до сотых")
        // Пусто: счётчики и сумма дают 0, остальное — ничего.
        checkEqual(RollupMath.compute(.count, values: []), .number(0))
        checkEqual(RollupMath.compute(.sum, values: []), .number(0))
        checkEqual(RollupMath.compute(.average, values: []), nil)
        checkEqual(RollupMath.compute(.percentEmpty, values: []), nil)
        checkEqual(RollupMath.compute(.earliest, values: []), nil)
        checkEqual(RollupMath.compute(.showOriginal, values: [nil]), nil)

        let d1 = LocalDate(year: 2026, month: 3, day: 5)!, d2 = LocalDate(year: 2026, month: 3, day: 9)!, d3 = LocalDate(year: 2026, month: 3, day: 12)!
        let dates: [PropertyValue?] = [.date(DateValue(start: .day(d2))), .date(DateValue(start: .day(d1), end: .day(d3))), nil]
        checkEqual(RollupMath.compute(.earliest, values: dates), .date(DateValue(start: .day(d1))))
        checkEqual(RollupMath.compute(.latest, values: dates), .date(DateValue(start: .day(d3))), "конец диапазона")
        checkEqual(RollupMath.compute(.dateRange, values: dates), .number(7))

        checkEqual(RollupMath.compute(.percentChecked, values: [.checkbox(true), .checkbox(false), nil, .checkbox(true)]), .number(50))
        checkEqual(RollupMath.compute(.countEmpty, values: [.checkbox(true), .checkbox(false), nil]), .number(2), "снятый флажок пуст")
        // Моменты сравниваются по времени, а не по настенным часам своих поясов.
        let tokyo = DatePoint.moment(ms: 1_000_000_000_000, zone: "Asia/Tokyo"), ny = DatePoint.moment(ms: 1_000_000_000_000 + 3_600_000, zone: "America/New_York")
        checkEqual(RollupMath.compute(.earliest, values: [.date(DateValue(start: ny)), .date(DateValue(start: tokyo))]), .date(DateValue(start: tokyo)))
        let a = PropertyOption(id: UUID(), name: "Альфа", sortKey: "a"), b = PropertyOption(id: UUID(), name: "Бета", sortKey: "b")
        let opts: [PropertyValue?] = [.options([a.id]), .options([b.id]), .options([a.id]), .options([])]
        checkEqual(RollupMath.compute(.countUnique, values: opts, options: [a, b]), .number(2))
        checkEqual(RollupMath.compute(.showOriginal, values: opts, options: [a, b]), .text("Альфа, Бета, Альфа"))
        check(RollupAggregate.available(for: .text).contains(.sum) == false, "сумма текста недоступна")
        check(RollupAggregate.available(for: .createdTime).contains(.earliest), "дата создания — дата")
        checkEqual(RollupAggregate.sum.resultType, .number)
        checkEqual(RollupAggregate.latest.resultType, .date)
        checkEqual(RollupAggregate(rawValue: "будущий").resultType, nil, "неизвестный агрегат не считается")
    }

    await test("Свёртки: сумма пересчитывается при правке значения, связи, корзине и восстановлении") {
        try await withSpace { w in
            let s = try await Setup.make(w)
            let site = try await add(w, s.projects, "Сайт"), move = try await add(w, s.projects, "Переезд")
            let t1 = try await add(w, s.tasks, "Вёрстка"), t2 = try await add(w, s.tasks, "Тексты"), t3 = try await add(w, s.tasks, "Коробки")
            try await w.setValue(pages: [t1], property: s.hours, value: .number(5), now: 4)
            try await w.setValue(pages: [t2], property: s.hours, value: .number(3), now: 4)
            try await w.setValue(pages: [t3], property: s.hours, value: .number(2), now: 4)
            try await w.setValue(pages: [t1, t2], property: s.forward, value: link(site), now: 4)
            try await w.setValue(pages: [t3], property: s.forward, value: link(move), now: 4)

            // Свёртка считается сразу для всех записей.
            let sum = try await s.rollup(w, .sum, name: "Всего часов")
            let count = try await s.rollup(w, .count, name: "Задач")
            checkEqual(try await value(w, s.projects, site, sum), .number(8))
            checkEqual(try await value(w, s.projects, move, sum), .number(2))
            checkEqual(try await value(w, s.projects, site, count), .number(2))

            // Правка значения у связанной записи.
            try await w.setValue(pages: [t1], property: s.hours, value: .number(7), now: 5)
            checkEqual(try await value(w, s.projects, site, sum), .number(10))
            // Перенос задачи в другой проект: меняются оба.
            try await w.setValue(pages: [t2], property: s.forward, value: link(move), now: 6)
            checkEqual(try await value(w, s.projects, site, sum), .number(7))
            checkEqual(try await value(w, s.projects, move, sum), .number(5))
            // Правка с обратной стороны.
            try await w.setValue(pages: [site], property: s.back, value: link(t1, t3), now: 7)
            checkEqual(try await value(w, s.projects, site, sum), .number(9))
            checkEqual(try await value(w, s.projects, move, sum), .number(5), "задача может быть в двух проектах")
            // Корзина и восстановление.
            let batch = UUID()
            try await w.trashPage(t1, batch: batch, now: 8)
            checkEqual(try await value(w, s.projects, site, sum), .number(2), "запись в корзине не считается")
            checkEqual(try await value(w, s.projects, site, count), .number(1))
            _ = try await w.restoreTrash(batch: batch)
            checkEqual(try await value(w, s.projects, site, sum), .number(9))
            try await w.trashRecords([t3], ids: RandomIDs(), now: 9)
            checkEqual(try await value(w, s.projects, move, sum), .number(3))
            // Окончательное удаление.
            guard let item = try await w.trashItems().first(where: { $0.page.id == t3 }) else { return check(false, "в корзине") }
            try await w.purgeTrash(batch: item.batchID)
            checkEqual(try await value(w, s.projects, site, sum), .number(7))

            // Новая запись сразу получает 0, а не пустую ячейку.
            let empty = try await add(w, s.projects, "Пустой")
            checkEqual(try await value(w, s.projects, empty, count), .number(0))
            checkEqual(try await value(w, s.projects, empty, sum), .number(0))

            // «Изменено» у проекта пересчёт не двигает.
            let d = try await fresh(w, s.projects)
            let edited = UUID()
            try await w.addProperty(database: d.id, name: "Изменено", type: .editedTime, id: edited, now: 1)
            let before = try await value(w, s.projects, move, edited)
            try await w.setValue(pages: [t2], property: s.hours, value: .number(30), now: 99_999)
            checkEqual(try await value(w, s.projects, move, sum), .number(30))
            checkEqual(try await value(w, s.projects, move, edited), before, "свёртка не правка пользователя")

            await checkThrows("свёртку не меняют руками") { try await w.setValue(pages: [site], property: sum, value: .number(1), now: 10) }
            await checkThrows("свёртка создаётся отдельным действием") { try await w.addProperty(database: d.id, name: "x", type: .rollup, id: UUID(), now: 1) }
        }
    }

    await test("Свёртки: фильтр и сортировка по готовому значению") {
        try await withSpace { w in
            let s = try await Setup.make(w)
            var projects: [UUID] = []
            for (i, name) in ["А", "Б", "В"].enumerated() {
                let p = try await add(w, s.projects, name)
                projects.append(p)
                for j in 0..<i {
                    let t = try await add(w, s.tasks, "\(name)\(j)")
                    try await w.setValue(pages: [t], property: s.hours, value: .number(Double(10 * (i + 1))), now: 4)
                    try await w.setValue(pages: [t], property: s.forward, value: link(p), now: 4)
                }
            }
            let sum = try await s.rollup(w, .sum)
            let earliest = try await s.rollup(w, .earliest, property: s.tasks.properties.first { $0.type == .date }!.id, name: "Первый срок")
            let d = try await fresh(w, s.projects)
            checkEqual(d.property(sum)?.valueType, .number)
            checkEqual(d.property(earliest)?.valueType, .date)
            var state = DatabaseViewState()
            state.filter.items = [.rule(FilterRule(property: sum, op: .greater, value: "25"))]
            checkEqual(try await w.queryRecords(database: d, state: state, limit: 10, offset: 0).rows.map(\.title), ["В"], "В: 2 × 30")
            state.filter.items = [.rule(FilterRule(property: earliest, op: .isEmpty, value: ""))]
            checkEqual(try await w.queryRecords(database: d, state: state, limit: 10, offset: 0).rows.count, 3, "сроков нет")
            state.filter.items = []
            state.sorts = [SortRule(property: sum, descending: true)]
            checkEqual(try await w.queryRecords(database: d, state: state, limit: 10, offset: 0).rows.map(\.title), ["В", "Б", "А"])
        }
    }

    await test("Свёртки: заголовки и варианты, «показать значения» и уникальные") {
        try await withSpace { w in
            let s = try await Setup.make(w)
            let p = try await add(w, s.projects, "Проект")
            let t1 = try await add(w, s.tasks, "Первая"), t2 = try await add(w, s.tasks, "Вторая")
            try await w.setValue(pages: [t1, t2], property: s.forward, value: link(p), now: 4)
            let title = s.tasks.titleProperty!.id, status = s.tasks.properties.first { $0.type == .status }!
            let names = try await s.rollup(w, .showOriginal, property: title, name: "Задачи текстом")
            let states = try await s.rollup(w, .showOriginal, property: status.id, name: "Статусы")
            let unique = try await s.rollup(w, .countUnique, property: status.id, name: "Разных статусов")
            guard case .text(let initial)? = try await value(w, s.projects, p, names) else { return check(false, "текст") }
            checkEqual(Set(initial.components(separatedBy: ", ")), ["Первая", "Вторая"])
            // Переименование записи через пакет редактора.
            var batch = SaveBatch()
            batch.titles[t1] = "Главная"
            try await w.commit(batch)
            guard case .text(let renamed)? = try await value(w, s.projects, p, names) else { return check(false, "текст") }
            check(renamed.contains("Главная") && !renamed.contains("Первая"), "новый заголовок: \(renamed)")
            try await w.setValue(pages: [t1, t2], property: status.id, value: .options([status.options[0].id]), now: 5)
            checkEqual(try await value(w, s.projects, p, states), .text("Новая, Новая"))
            checkEqual(try await value(w, s.projects, p, unique), .number(1))
            try await w.updateOption(status.options[0].id, name: "Начата", color: nil)
            checkEqual(try await value(w, s.projects, p, states), .text("Начата, Начата"), "переименование варианта")
            try await w.deleteOption(status.options[0].id)
            checkEqual(try await value(w, s.projects, p, states), nil, "вариант удалён")
            checkEqual(try await value(w, s.projects, p, unique), .number(0))
        }
    }

    await test("Свёртки: цепочка свёртка свёртки, удаление и смена типа источника") {
        try await withSpace { w in
            let s = try await Setup.make(w)
            let portfolios = try await base(w, "Портфели")
            let pf = UUID(), pb = UUID()
            try await w.addRelation(database: portfolios.id, name: "Проекты", target: s.projects.id, twoWay: true, pairName: "Портфель", id: pf, pairID: pb, now: 1)
            let p1 = try await add(w, s.projects, "Сайт"), p2 = try await add(w, s.projects, "Переезд")
            let t1 = try await add(w, s.tasks, "А"), t2 = try await add(w, s.tasks, "Б")
            try await w.setValue(pages: [t1], property: s.hours, value: .number(4), now: 4)
            try await w.setValue(pages: [t2], property: s.hours, value: .number(6), now: 4)
            try await w.setValue(pages: [t1], property: s.forward, value: link(p1), now: 4)
            try await w.setValue(pages: [t2], property: s.forward, value: link(p2), now: 4)
            let sum = try await s.rollup(w, .sum)
            let pfRecords = try await fresh(w, portfolios)
            let all = try await add(w, pfRecords, "Всё")
            try await w.setValue(pages: [all], property: pf, value: link(p1, p2), now: 4)
            let total = UUID()
            try await w.addRollup(database: portfolios.id, name: "Итого часов", relation: pf, property: sum, aggregate: .sum, id: total, now: 5)
            checkEqual(try await value(w, portfolios, all, total), .number(10))
            // Правка в задаче доходит через две свёртки.
            try await w.setValue(pages: [t2], property: s.hours, value: .number(16), now: 6)
            checkEqual(try await value(w, portfolios, all, total), .number(20), "цепочка пересчитана")
            try await w.setValue(pages: [t1], property: s.forward, value: nil, now: 7)
            checkEqual(try await value(w, portfolios, all, total), .number(16))

            // Неподходящие сочетания отклоняются, свойство не создаётся.
            let title = s.tasks.titleProperty!.id
            await checkThrows("сумма текста") {
                try await w.addRollup(database: s.projects.id, name: "x", relation: s.back, property: title, aggregate: .sum, id: UUID(), now: 8)
            }
            let edited = UUID()
            try await w.addProperty(database: s.tasks.id, name: "Изменено", type: .editedTime, id: edited, now: 1)
            await checkThrows("время изменения как источник") {
                try await w.addRollup(database: s.projects.id, name: "x", relation: s.back, property: edited, aggregate: .latest, id: UUID(), now: 8)
            }
            await checkThrows("связь другой базы") {
                try await w.addRollup(database: s.projects.id, name: "x", relation: s.forward, property: s.hours, aggregate: .sum, id: UUID(), now: 8)
            }
            checkEqual(try await fresh(w, s.projects).properties.filter { $0.type == .rollup }.count, 1)

            // Смена типа источника: сумма текста невозможна, значения очищаются, цепочка тоже.
            try await w.changePropertyType(s.hours, to: .text, zone: "UTC", ids: RandomIDs(), now: 9)
            checkEqual(try await value(w, s.projects, p2, sum), nil, "свёртка без источника пуста")
            checkEqual(try await value(w, portfolios, all, total), .number(0), "сумма пустых — 0")
            // Обратно в число: свёртка снова действует.
            try await w.changePropertyType(s.hours, to: .number, zone: "UTC", ids: RandomIDs(), now: 10)
            checkEqual(try await value(w, s.projects, p2, sum), .number(16))
            checkEqual(try await value(w, portfolios, all, total), .number(16))
            // Удаление связи, на которой стоит свёртка.
            try await w.deleteProperty(s.back)
            checkEqual(try await value(w, s.projects, p2, sum), nil, "связь удалена")
            checkEqual(try await value(w, portfolios, all, total), .number(0))
            checkEqual(try await fresh(w, s.projects).property(sum)?.type, .rollup, "свойство остаётся, его можно удалить")
        }
    }

    await test("Свёртки: источник — обратная сторона связи, незнакомый агрегат, флажки") {
        try await withSpace { w in
            let s = try await Setup.make(w)
            // Клиенты → проекты; у клиента свёртка по обратной стороне «Задачи» проектов.
            let clients = try await base(w, "Клиенты")
            let cf = UUID(), cb = UUID()
            try await w.addRelation(database: clients.id, name: "Проекты", target: s.projects.id, twoWay: true, pairName: "Клиент", id: cf, pairID: cb, now: 1)
            let c = try await add(w, try await fresh(w, clients), "Клиент")
            let p = try await add(w, s.projects, "Проект"), t1 = try await add(w, s.tasks, "Один"), t2 = try await add(w, s.tasks, "Два")
            try await w.setValue(pages: [c], property: cf, value: link(p), now: 4)
            let filled = UUID()
            try await w.addRollup(database: clients.id, name: "С задачами", relation: cf, property: s.back, aggregate: .countValues, id: filled, now: 5)
            checkEqual(try await value(w, clients, c, filled), .number(0))
            // Правка прямой стороны у задачи меняет обратную сторону проекта — свёртка клиента пересчитывается.
            try await w.setValue(pages: [t1, t2], property: s.forward, value: link(p), now: 6)
            checkEqual(try await value(w, clients, c, filled), .number(1), "обратная сторона как источник")

            // Флажок: снятый считается пустым.
            let flag = UUID()
            try await w.addProperty(database: s.tasks.id, name: "Готово", type: .checkbox, id: flag, now: 1)
            try await w.setValue(pages: [t1], property: flag, value: .checkbox(true), now: 7)
            try await w.setValue(pages: [t2], property: flag, value: .checkbox(false), now: 7)
            let empty = try await s.rollup(w, .countEmpty, property: flag, name: "Не готово")
            checkEqual(try await value(w, s.projects, p, empty), .number(1))

            // Незнакомый агрегат более новой версии: значения не стираются при чужих изменениях.
            let future = try await s.rollup(w, .sum, name: "Будущая")
            checkEqual(try await value(w, s.projects, p, future), .number(0))
            _ = try w.maintenanceWrite { db in
                try db.run("UPDATE property_definitions SET config_json = replace(config_json, '\"sum\"', '\"future_agg\"') WHERE id=?", [SQLValue(future)])
                try db.run("UPDATE property_values SET value_num = 42 WHERE property_id=?", [SQLValue(future)])
            }
            try await w.deleteProperty(flag)
            // Показать такое значение нельзя (тип результата неизвестен), но в базе оно остаётся.
            let kept = try w.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM property_values WHERE property_id=? AND value_num=42", [SQLValue(future)]) }
            checkEqual(kept, Optional(Int64(1)), "значение незнакомой свёртки сохранено")
            checkEqual(try await value(w, s.projects, p, empty), nil, "свёртка по удалённому флажку очищена")
        }
    }

    await test("Свёртки: копия базы и шаблон записи") {
        try await withSpace { w in
            let s = try await Setup.make(w)
            let p = try await add(w, s.projects, "Проект"), t = try await add(w, s.tasks, "Задача")
            try await w.setValue(pages: [t], property: s.hours, value: .number(3), now: 4)
            try await w.setValue(pages: [t], property: s.forward, value: link(p), now: 4)
            let sum = try await s.rollup(w, .sum)
            // Копия задачи привязана к тому же проекту: сумма проекта растёт.
            _ = try await w.duplicatePage(t, title: "Задача 2", ids: RandomIDs(), now: 5)
            checkEqual(try await value(w, s.projects, p, sum), .number(6))
            // Копия базы проектов: своя свёртка по своей связи.
            let copyPage = try await w.duplicatePage(s.projects.pageID, title: "Проекты 2", ids: RandomIDs(), now: 6)
            guard let id = try await w.databaseIndex()[copyPage], let copy = try await w.database(id),
                  let rollup = copy.properties.first(where: { $0.type == .rollup }), let rel = copy.properties.first(where: { $0.type == .relation }) else { return check(false, "копия") }
            checkEqual(rollup.config.rollupRelation, rel.id, "связь копии")
            checkEqual(rollup.config.rollupProperty, s.hours, "цель вне копии сохраняется")
            let rows = try await w.queryRecords(database: copy, state: DatabaseViewState(), limit: 10, offset: 0).rows
            checkEqual(rows.map { $0.values[rollup.id] }, [.number(6)])
            // Шаблон задачи: новая запись добавляет часы проекту.
            let template = try await w.saveTemplate(from: t, name: "Шаблон", ids: RandomIDs(), now: 7)
            checkEqual(try await value(w, s.projects, p, sum), .number(6), "скрытая копия не считается")
            _ = try await w.instantiate(template: template.id, parent: nil, ids: RandomIDs(), now: 8)
            checkEqual(try await value(w, s.projects, p, sum), .number(9))
        }
    }

    // Только по явному запуску: `./scripts/test-notes.sh "Замер свёрток"`.
    if TestRun.filter.map({ "Замер свёрток".contains($0) && !$0.isEmpty }) == true {
        await test("Замер свёрток: 20 000 задач, 200 проектов") {
            try await withSpace { w in
                let s = try await Setup.make(w)
                var projects: [UUID] = []
                for i in 0..<200 { projects.append(try await add(w, s.projects, "П\(i)")) }
                var t0 = DispatchTime.now().uptimeNanoseconds
                var tasks: [UUID] = []
                for i in 0..<20_000 {
                    let t = try await add(w, s.tasks, "З\(i)")
                    tasks.append(t)
                }
                for (i, t) in tasks.enumerated() {
                    try await w.setValue(pages: [t], property: s.hours, value: .number(Double(i % 9)), now: 4)
                    try await w.setValue(pages: [t], property: s.forward, value: link(projects[i % 200]), now: 4)
                }
                print(String(format: "заполнение: %.0f мс", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
                t0 = DispatchTime.now().uptimeNanoseconds
                let sum = try await s.rollup(w, .sum)
                print(String(format: "создание свёртки (200 проектов × 100 задач): %.0f мс", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
                var times: [Double] = []
                for i in 0..<50 {
                    let t = DispatchTime.now().uptimeNanoseconds
                    try await w.setValue(pages: [tasks[i * 37]], property: s.hours, value: .number(Double(i)), now: 5)
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
                }
                times.sort()
                print(String(format: "правка часов с пересчётом: p50=%.1f p95=%.1f мс", times[25], times[47]))
                t0 = DispatchTime.now().uptimeNanoseconds
                try await w.setValue(pages: Array(tasks.prefix(1000)), property: s.hours, value: .number(1), now: 6)
                print(String(format: "массовая правка 1000 задач: %.0f мс", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
                // Создание свёртки на базе задач: 20 000 записей по одной связи.
                t0 = DispatchTime.now().uptimeNanoseconds
                try await w.addRollup(database: s.tasks.id, name: "Задач в проекте", relation: s.forward, property: s.projects.titleProperty!.id,
                                      aggregate: .count, id: UUID(), now: 7)
                print(String(format: "создание свёртки на 20 000 записей: %.0f мс", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
                let last = try await value(w, s.projects, projects[0], sum)
                check(last != nil)
            }
        }
    }
}
