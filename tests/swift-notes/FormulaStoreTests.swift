import Foundation

private func base(_ w: SQLiteWorkspace, _ title: String) async throws -> Database {
    try await w.createDatabase(parent: nil, template: NewDatabase(title: title, titleProperty: "Название", statusProperty: "Статус",
                                                                  statusOptions: ["Новая", "Готово"], dateProperty: "Срок", viewName: "Таблица"),
                               ids: RandomIDs(), now: 1)
}

private func fresh(_ w: SQLiteWorkspace, _ d: Database) async throws -> Database {
    guard let x = try await w.database(d.id) else { throw WorkspaceError.corrupted("нет базы") }
    return x
}

private func add(_ w: SQLiteWorkspace, _ d: Database, _ title: String, now: Int64 = 2) async throws -> UUID {
    let id = UUID()
    try await w.createRecord(database: d.id, title: title, id: id, now: now)
    return id
}

private func value(_ w: SQLiteWorkspace, _ d: Database, _ page: UUID, _ property: UUID) async throws -> PropertyValue? {
    try await w.recordValues(page: page, database: try await fresh(w, d))[property]
}

/// Часы: фиксированное время для today() и «Изменено».
private final class Clock: WallClock {
    var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
    func nowMillis() -> Int64 { ms }
}

private func withSpace(clock: Clock? = nil, _ body: (SQLiteWorkspace) async throws -> Void) async throws {
    try await withTempDir { dir in
        let w: SQLiteWorkspace
        if let clock {
            let root = dir.appendingPathComponent("w")
            let first = try SQLiteWorkspace.create(at: root, name: "T")
            first.close()
            var options = SQLiteWorkspace.Options()
            options.clock = clock
            w = try SQLiteWorkspace.open(at: root, options: options)
        } else {
            w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
        }
        defer { w.close() }
        try await body(w)
    }
}

private func ms(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    return Int64(cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!.timeIntervalSince1970 * 1000)
}

func runFormulaStoreTests() async {
    await test("Формулы в базе: сохранение, вычисление, пересчёт при правке, фильтр и сортировка") {
        try await withSpace { w in
            var d = try await base(w, "Покупки")
            let price = UUID(), qty = UUID(), total = UUID(), big = UUID(), label = UUID()
            try await w.addProperty(database: d.id, name: "Цена", type: .number, id: price, now: 1)
            try await w.addProperty(database: d.id, name: "Количество", type: .number, id: qty, now: 1)
            let a = try await add(w, d, "Коробки"), b = try await add(w, d, "Скотч")
            try await w.setValue(pages: [a], property: price, value: .number(250), now: 3)
            try await w.setValue(pages: [a], property: qty, value: .number(4), now: 3)
            try await w.setValue(pages: [b], property: price, value: .number(90), now: 3)
            try await w.addFormula(database: d.id, name: "Сумма", source: "prop(\"Цена\") * prop(\"Количество\")", id: total, now: 4)
            try await w.addFormula(database: d.id, name: "Крупная", source: "prop(\"Сумма\") >= 500", id: big, now: 4)
            try await w.addFormula(database: d.id, name: "Подпись", source: "prop(\"Название\") + \": \" + format(prop(\"Сумма\"))", id: label, now: 4)
            d = try await fresh(w, d)
            checkEqual(d.property(total)?.valueType, .number)
            checkEqual(d.property(big)?.valueType, .checkbox)
            check(d.property(total)?.config.formula?.contains(price.uuidString) == true, "в хранении ID")
            checkEqual(try await value(w, d, a, total), .number(1000))
            checkEqual(try await value(w, d, b, total), nil, "пустое количество — пусто")
            checkEqual(try await value(w, d, a, big), .checkbox(true), "формула от формулы")
            checkEqual(try await value(w, d, a, label), .text("Коробки: 1000"))
            // Правка входа пересчитывает цепочку.
            try await w.setValue(pages: [b], property: qty, value: .number(10), now: 5)
            checkEqual(try await value(w, d, b, total), .number(900))
            checkEqual(try await value(w, d, b, big), .checkbox(true))
            // Заголовок через пакет редактора.
            var batch = SaveBatch()
            batch.titles[a] = "Большие коробки"
            try await w.commit(batch)
            checkEqual(try await value(w, d, a, label), .text("Большие коробки: 1000"))
            // Фильтр и сортировка по готовому значению.
            var state = DatabaseViewState()
            state.filter.items = [.rule(FilterRule(property: total, op: .greater, value: "950"))]
            checkEqual(try await w.queryRecords(database: d, state: state, limit: 10, offset: 0).rows.map(\.title), ["Большие коробки"])
            state.filter.items = [.rule(FilterRule(property: big, op: .isTrue, value: ""))]
            checkEqual(try await w.queryRecords(database: d, state: state, limit: 10, offset: 0).rows.count, 2)
            state.filter.items = []
            state.sorts = [SortRule(property: total)]
            checkEqual(try await w.queryRecords(database: d, state: state, limit: 10, offset: 0).rows.map(\.title), ["Скотч", "Большие коробки"])
            // Новая запись сразу получает результат формулы.
            let c = try await add(w, d, "Пустая")
            checkEqual(try await value(w, d, c, label), .text("Пустая: "))
            // Переименование свойства не ломает формулу.
            try await w.renameProperty(price, to: "Стоимость")
            try await w.setValue(pages: [a], property: price, value: .number(100), now: 6)
            checkEqual(try await value(w, d, a, total), .number(400))
            let shown = w.formulaDisplayText(try await fresh(w, d).property(total)!, in: try await fresh(w, d))
            checkEqual(shown, "prop(\"Стоимость\") * prop(\"Количество\")")
            // Смена текста формулы.
            try await w.updateFormula(total, source: "prop(\"Стоимость\") * prop(\"Количество\") * 2", now: 7)
            checkEqual(try await value(w, d, a, total), .number(800))
            checkEqual(try await value(w, d, a, big), .checkbox(true), "зависимая формула пересчитана")
            await checkThrows("ручная правка") { try await w.setValue(pages: [a], property: total, value: .number(1), now: 8) }
            await checkThrows("тип формулы обычной правкой") { try await w.addProperty(database: d.id, name: "x", type: .formula, id: UUID(), now: 1) }
        }
    }

    await test("AT-18: цикл отклоняется без зависания, удалённый источник даёт явную ошибку без порчи данных") {
        try await withSpace { w in
            var d = try await base(w, "Учёт")
            let x = UUID(), f1 = UUID(), f2 = UUID()
            try await w.addProperty(database: d.id, name: "Икс", type: .number, id: x, now: 1)
            let r = try await add(w, d, "Запись")
            try await w.setValue(pages: [r], property: x, value: .number(2), now: 2)
            try await w.addFormula(database: d.id, name: "Один", source: "prop(\"Икс\") + 1", id: f1, now: 3)
            try await w.addFormula(database: d.id, name: "Два", source: "prop(\"Один\") * 10", id: f2, now: 3)
            checkEqual(try await value(w, d, r, f2), .number(30))
            // Замыкание: «Один» начинает ссылаться на «Два».
            let started = Date()
            let error = await checkThrows("цикл") { try await w.updateFormula(f1, source: "prop(\"Два\") + 1", now: 4) }
            check(Date().timeIntervalSince(started) < 5, "без зависания")
            check((error as? LocalizedError)?.errorDescription?.contains("Один → Два → Один") == true, "путь цикла: \(String(describing: (error as? LocalizedError)?.errorDescription))")
            d = try await fresh(w, d)
            check(d.property(f1)?.config.formula?.contains(x.uuidString) == true, "формула не изменилась")
            checkEqual(try await value(w, d, r, f1), .number(3), "значения не испорчены")
            checkEqual(try await value(w, d, r, f2), .number(30))
            // Предпросмотр показывает тот же цикл, ничего не записывая.
            let preview = try await w.previewFormula(database: d.id, source: "prop(\"Два\") + 1", editing: f1)
            check(preview.error?.message.contains("Циклическая") == true, "предпросмотр видит цикл")
            // Ссылка на себя.
            await checkThrows("ссылка на себя") { try await w.updateFormula(f2, source: "prop(\"Два\")", now: 5) }

            // Цикл через свёртку и связь: проект ← задачи, формула проекта ссылается на свёртку, свёртка — на формулу задачи,
            // которая ссылается на свёртку задачи по формуле проекта.
            let projects = try await base(w, "Проекты"), tasks = try await base(w, "Задачи")
            let fwd = UUID(), back = UUID()
            try await w.addRelation(database: tasks.id, name: "Проект", target: projects.id, twoWay: true, pairName: "Задачи", id: fwd, pairID: back, now: 1)
            let pf = UUID(), tf = UUID(), pr = UUID(), tr = UUID()
            try await w.addFormula(database: projects.id, name: "Ф проекта", source: "1", id: pf, now: 1)
            try await w.addRollup(database: tasks.id, name: "Из проекта", relation: fwd, property: pf, aggregate: .sum, id: tr, now: 1)
            try await w.addFormula(database: tasks.id, name: "Ф задачи", source: "prop(\"Из проекта\") + 1", id: tf, now: 1)
            try await w.addRollup(database: projects.id, name: "Из задач", relation: back, property: tf, aggregate: .sum, id: pr, now: 1)
            await checkThrows("цикл через две базы") { try await w.updateFormula(pf, source: "prop(\"Из задач\")", now: 2) }

            // Удалённое свойство: формула не падает, ячейка показывает ошибку, остальное цело.
            try await w.deleteProperty(x)
            d = try await fresh(w, d)
            guard case .error(let message)? = try await value(w, d, r, f1) else { return check(false, "ожидалась ошибка в ячейке") }
            check(message.contains("Нет свойства"), message)
            if case .error? = try await value(w, d, r, f2) { check(false, "пустой вход — пусто, а не ошибка") }
            checkEqual(try await w.allPages().filter { $0.databaseID == d.id }.map(\.title), ["Запись"])
            // Удалённая связь под свёрткой: свёртка очищена, формула от неё — пусто, а не падение.
            try await w.deleteProperty(fwd)
            let projectRecord = try await add(w, projects, "П")
            _ = try await value(w, projects, projectRecord, pr)
            check(true, "без падения")
        }
    }

    await test("Формулы в базе: today() раз в день, «Изменено», копия базы, смена типа источника") {
        let clock = Clock(ms(2026, 3, 1))
        try await withSpace(clock: clock) { w in
            var d = try await base(w, "Дела")
            let due = d.properties.first { $0.type == .date }!.id
            let edited = UUID(), left = UUID(), stale = UUID()
            try await w.addProperty(database: d.id, name: "Изменено", type: .editedTime, id: edited, now: 1)
            let r = try await add(w, d, "Сдать отчёт", now: ms(2026, 2, 20))
            try await w.setValue(pages: [r], property: due, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 3, day: 10)!))), now: ms(2026, 2, 20))
            try await w.addFormula(database: d.id, name: "Осталось", source: "dateBetween(prop(\"Срок\"), today(), \"days\")", id: left, now: clock.ms)
            try await w.addFormula(database: d.id, name: "Не трогали", source: "dateBetween(today(), prop(\"Изменено\"), \"days\")", id: stale, now: clock.ms)
            checkEqual(try await value(w, d, r, left), .number(9))
            checkEqual(try await value(w, d, r, stale), .number(9))
            // Новый день: пересчёт один раз.
            let first = try await w.refreshDailyFormulas(), second = try await w.refreshDailyFormulas()
            check(first, "первый вызов пересчитывает")
            check(!second, "второй в тот же день — нет")
            clock.ms = ms(2026, 3, 4)
            let third = try await w.refreshDailyFormulas()
            check(third, "новый день")
            checkEqual(try await value(w, d, r, left), .number(6))
            checkEqual(try await value(w, d, r, stale), .number(12))
            // Правка записи меняет «Изменено» и формулу от него.
            let status = d.properties.first { $0.type == .status }!
            try await w.setValue(pages: [r], property: status.id, value: .options([status.options[0].id]), now: clock.ms)
            checkEqual(try await value(w, d, r, stale), .number(0))

            // Смена типа источника: формула получает ошибку «тип результата изменился» или «ожидалось число».
            let n = UUID(), twice = UUID()
            try await w.addProperty(database: d.id, name: "Число", type: .number, id: n, now: 1)
            try await w.setValue(pages: [r], property: n, value: .number(5), now: clock.ms)
            try await w.addFormula(database: d.id, name: "Дважды", source: "prop(\"Число\") * 2", id: twice, now: clock.ms)
            checkEqual(try await value(w, d, r, twice), .number(10))
            try await w.changePropertyType(n, to: .text, zone: "UTC", ids: RandomIDs(), now: clock.ms)
            guard case .error? = try await value(w, d, r, twice) else { return check(false, "ошибка после смены типа") }
            try await w.changePropertyType(n, to: .number, zone: "UTC", ids: RandomIDs(), now: clock.ms)
            checkEqual(try await value(w, d, r, twice), .number(10), "обратная смена — формула снова считается")

            // Копия базы: формула копии ссылается на свойства копии.
            d = try await fresh(w, d)
            let copyPage = try await w.duplicatePage(d.pageID, title: "Дела 2", ids: RandomIDs(), now: clock.ms)
            guard let copyID = try await w.databaseIndex()[copyPage], let copy = try await w.database(copyID),
                  let copiedNumber = copy.properties.first(where: { $0.name == "Число" }), let copiedTwice = copy.properties.first(where: { $0.name == "Дважды" }) else {
                return check(false, "копия")
            }
            check(copiedTwice.config.formula?.contains(copiedNumber.id.uuidString) == true && copiedTwice.config.formula?.contains(n.uuidString) == false, "ID копии")
            let row = try await w.queryRecords(database: copy, state: DatabaseViewState(), limit: 5, offset: 0).rows[0]
            try await w.setValue(pages: [row.id], property: copiedNumber.id, value: .number(21), now: clock.ms)
            checkEqual(try await w.recordValues(page: row.id, database: copy)[copiedTwice.id], .number(42))
            checkEqual(try await value(w, d, r, twice), .number(10), "оригинал не затронут")
        }
    }

    await test("Формулы в базе: свёртка по формуле и формула по свёртке") {
        try await withSpace { w in
            let projects = try await base(w, "Проекты"), tasks = try await base(w, "Задачи")
            let fwd = UUID(), back = UUID(), hours = UUID(), cost = UUID(), sum = UUID(), budget = UUID()
            try await w.addRelation(database: tasks.id, name: "Проект", target: projects.id, twoWay: true, pairName: "Задачи", id: fwd, pairID: back, now: 1)
            try await w.addProperty(database: tasks.id, name: "Часы", type: .number, id: hours, now: 1)
            try await w.addFormula(database: tasks.id, name: "Стоимость", source: "prop(\"Часы\") * 1500", id: cost, now: 1)
            let p = try await add(w, projects, "Сайт"), t = try await add(w, tasks, "Вёрстка")
            try await w.setValue(pages: [t], property: fwd, value: .relation([LinkedPage(id: p, title: "")]), now: 2)
            try await w.addRollup(database: projects.id, name: "Итого", relation: back, property: cost, aggregate: .sum, id: sum, now: 3)
            try await w.addFormula(database: projects.id, name: "Бюджет", source: "if(prop(\"Итого\") > 10000, \"превышен\", \"в норме\")", id: budget, now: 3)
            checkEqual(try await value(w, projects, p, budget), .text("в норме"))
            try await w.setValue(pages: [t], property: hours, value: .number(8), now: 4)
            checkEqual(try await value(w, projects, p, sum), .number(12000))
            checkEqual(try await value(w, projects, p, budget), .text("превышен"), "часы → формула → свёртка → формула")
        }
    }
}
