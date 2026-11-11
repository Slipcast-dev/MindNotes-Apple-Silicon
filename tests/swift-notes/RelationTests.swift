import Foundation

private func base(_ w: SQLiteWorkspace, _ title: String) async throws -> Database {
    try await w.createDatabase(parent: nil, template: NewDatabase(title: title, titleProperty: "Название", statusProperty: "Статус",
                                                                  statusOptions: ["Новая", "Готово"], dateProperty: "Срок", viewName: "Таблица"),
                               ids: RandomIDs(), now: 1)
}

private func add(_ w: SQLiteWorkspace, _ d: Database, _ title: String, now: Int64 = 2) async throws -> UUID {
    let id = UUID()
    try await w.createRecord(database: d.id, title: title, id: id, now: now)
    return id
}

private func fresh(_ w: SQLiteWorkspace, _ d: Database) async throws -> Database {
    guard let x = try await w.database(d.id) else { throw WorkspaceError.corrupted("нет базы") }
    return x
}

private func names(_ value: PropertyValue?) -> [String] {
    guard case .relation(let links)? = value else { return [] }
    return links.map(\.title)
}

private func link(_ ids: UUID...) -> PropertyValue { .relation(ids.map { LinkedPage(id: $0, title: "") }) }

private func query(_ w: SQLiteWorkspace, _ d: Database, _ rule: FilterRule? = nil, sort: SortRule? = nil) async throws -> [String] {
    var state = DatabaseViewState()
    if let rule { state.filter.items = [.rule(rule)] }
    if let sort { state.sorts = [sort] }
    return try await w.queryRecords(database: d, state: state, limit: 100, offset: 0).rows.map(\.title)
}

private func withSpace(_ body: (SQLiteWorkspace) async throws -> Void) async throws {
    try await withTempDir { dir in
        let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
        defer { w.close() }
        try await body(w)
    }
}

/// Проекты и задачи с двусторонней связью «Проект» ↔ «Задачи».
private struct Pair {
    var projects: Database
    var tasks: Database
    var forward: PropertyDefinition
    var back: PropertyDefinition

    static func make(_ w: SQLiteWorkspace, twoWay: Bool = true) async throws -> Pair {
        let projects = try await base(w, "Проекты"), tasks = try await base(w, "Задачи")
        let id = UUID(), pairID = UUID()
        try await w.addRelation(database: tasks.id, name: "Проект", target: projects.id, twoWay: twoWay, pairName: "Задачи", id: id, pairID: pairID, now: 1)
        let t = try await fresh(w, tasks), p = try await fresh(w, projects)
        let back = p.property(pairID) ?? PropertyDefinition(id: pairID, databaseID: p.id, name: "", type: .relation, sortKey: "")
        return Pair(projects: p, tasks: t, forward: t.property(id)!, back: back)
    }
}

func runRelationTests() async {
    await test("Связи: двусторонняя связь видна с обеих сторон, порядок и фильтры") {
        try await withSpace { w in
            let s = try await Pair.make(w)
            checkEqual(s.forward.config.target, s.projects.id)
            checkEqual(s.forward.config.pair, s.back.id)
            check(s.back.config.isBackSide, "обратная сторона")
            checkEqual(s.back.config.target, s.tasks.id)
            let alpha = try await add(w, s.projects, "Альфа"), beta = try await add(w, s.projects, "Бета")
            let a = try await add(w, s.tasks, "Купить"), b = try await add(w, s.tasks, "Позвонить"), c = try await add(w, s.tasks, "Без проекта")
            try await w.setValue(pages: [a], property: s.forward.id, value: link(beta, alpha), now: 3)
            try await w.setValue(pages: [b], property: s.forward.id, value: link(alpha), now: 3)
            checkEqual(names(try await w.recordValues(page: a, database: s.tasks)[s.forward.id]), ["Бета", "Альфа"], "порядок связи сохраняется")
            checkEqual(names(try await w.recordValues(page: alpha, database: s.projects)[s.back.id]), ["Купить", "Позвонить"], "обратная сторона по заголовку")
            checkEqual(names(try await w.recordValues(page: beta, database: s.projects)[s.back.id]), ["Купить"])
            checkEqual(try await w.recordValues(page: c, database: s.tasks)[s.forward.id], nil, "пустая связь")

            // Правка с обратной стороны меняет прямую.
            try await w.setValue(pages: [beta], property: s.back.id, value: link(a, c), now: 4)
            checkEqual(names(try await w.recordValues(page: c, database: s.tasks)[s.forward.id]), ["Бета"])
            checkEqual(names(try await w.recordValues(page: a, database: s.tasks)[s.forward.id]), ["Бета", "Альфа"], "с обратной стороны порядок прямой не теряется")
            try await w.setValue(pages: [beta], property: s.back.id, value: link(c), now: 4)
            checkEqual(names(try await w.recordValues(page: a, database: s.tasks)[s.forward.id]), ["Альфа"], "снятая с обратной стороны связь исчезла")

            // Фильтры: часть заголовка, пусто, не пусто — с обеих сторон.
            checkEqual(try await query(w, s.tasks, FilterRule(property: s.forward.id, op: .contains, value: "альф")).sorted(), ["Купить", "Позвонить"])
            checkEqual(try await query(w, s.tasks, FilterRule(property: s.forward.id, op: .notContains, value: "альф")), ["Без проекта"])
            checkEqual(try await query(w, s.tasks, FilterRule(property: s.forward.id, op: .isEmpty, value: "")), [])
            checkEqual(try await query(w, s.projects, FilterRule(property: s.back.id, op: .contains, value: "ПОЗВОН")), ["Альфа"], "регистр не важен")
            checkEqual(try await query(w, s.projects, FilterRule(property: s.back.id, op: .isNotEmpty, value: "")).sorted(), ["Альфа", "Бета"])
            let blank = try await query(w, s.tasks, FilterRule(property: s.forward.id, op: .contains, value: "  "))
            checkEqual(blank.count, 3, "пустой текст пропускается")
            // Сортировка по числу связей: пустые в конце.
            let gamma = try await add(w, s.projects, "Гамма")
            checkEqual(try await query(w, s.projects, sort: SortRule(property: s.back.id, descending: true)), ["Альфа", "Бета", "Гамма"])
            checkEqual(try await query(w, s.projects, sort: SortRule(property: s.back.id)), ["Бета", "Альфа", "Гамма"])
            _ = gamma
        }
    }

    await test("Связи: неверные значения отклоняются целиком") {
        try await withSpace { w in
            let s = try await Pair.make(w)
            let p = try await add(w, s.projects, "Проект"), t = try await add(w, s.tasks, "Задача"), other = try await add(w, s.tasks, "Чужая")
            await checkThrows("запись не из целевой базы") { try await w.setValue(pages: [t], property: s.forward.id, value: link(other), now: 3) }
            await checkThrows("повтор записи") { try await w.setValue(pages: [t], property: s.forward.id, value: link(p, p), now: 3) }
            let many = (0...RelationLimits.maxLinks).map { _ in LinkedPage(id: UUID(), title: "") }
            await checkThrows("больше предела") { try await w.setValue(pages: [t], property: s.forward.id, value: .relation(many), now: 3) }
            await checkThrows("текст в связь") { try await w.setValue(pages: [t], property: s.forward.id, value: .text("x"), now: 3) }
            await checkThrows("несуществующая запись") { try await w.setValue(pages: [t], property: s.forward.id, value: link(UUID()), now: 3) }
            checkEqual(try await w.recordValues(page: t, database: s.tasks)[s.forward.id], nil, "ничего не записано")
            await checkThrows("связь создаётся отдельным действием") { try await w.addProperty(database: s.tasks.id, name: "x", type: .relation, id: UUID(), now: 1) }
            await checkThrows("смена типа связи") { try await w.changePropertyType(s.forward.id, to: .text, zone: "UTC", ids: RandomIDs(), now: 1) }
            await checkThrows("смена типа на связь") { try await w.previewTypeChange(property: s.tasks.properties.first { $0.type == .status }!.id, to: .relation, zone: "UTC") }
            await checkThrows("цель недоступна") {
                try await w.addRelation(database: s.tasks.id, name: "x", target: UUID(), twoWay: true, pairName: "y", id: UUID(), pairID: UUID(), now: 1)
            }
            checkEqual(try await fresh(w, s.tasks).properties.filter { $0.type == .relation }.count, 1, "неудачная связь не создала свойств")
        }
    }

    await test("Связи: корзина скрывает связь, восстановление возвращает, окончательное удаление убирает") {
        try await withSpace { w in
            let s = try await Pair.make(w)
            let p1 = try await add(w, s.projects, "Первый"), p2 = try await add(w, s.projects, "Второй")
            let t = try await add(w, s.tasks, "Задача")
            try await w.setValue(pages: [t], property: s.forward.id, value: link(p1, p2), now: 3)
            let batch = UUID()
            try await w.trashPage(p1, batch: batch, now: 4)
            checkEqual(names(try await w.recordValues(page: t, database: s.tasks)[s.forward.id]), ["Второй"], "запись из корзины не видна")
            checkEqual(try await query(w, s.tasks, FilterRule(property: s.forward.id, op: .contains, value: "перв")), [], "и не находится фильтром")
            // Правка ячейки не теряет скрытую связь.
            try await w.setValue(pages: [t], property: s.forward.id, value: link(p2), now: 5)
            _ = try await w.restoreTrash(batch: batch)
            checkEqual(names(try await w.recordValues(page: t, database: s.tasks)[s.forward.id]), ["Первый", "Второй"], "вернулась на прежнее место")
            let again = UUID()
            try await w.trashPage(p1, batch: again, now: 6)
            try await w.purgeTrash(batch: again)
            try await w.setValue(pages: [t], property: s.forward.id, value: nil, now: 7)
            _ = try await w.restoreTrash(batch: again)
            checkEqual(try await w.recordValues(page: t, database: s.tasks)[s.forward.id], nil, "после окончательного удаления связи нет")
            let rows = try w.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM relation_links") }
            checkEqual(rows, Optional(Int64(0)), "строки удалены каскадом")
        }
    }

    await test("Связи: удаление одной стороны оставляет другую односторонней со всеми строками") {
        try await withSpace { w in
            var s = try await Pair.make(w)
            let p = try await add(w, s.projects, "Проект"), t1 = try await add(w, s.tasks, "Один"), t2 = try await add(w, s.tasks, "Два")
            try await w.setValue(pages: [t1, t2], property: s.forward.id, value: link(p), now: 3)
            checkEqual(try await w.valueCount(property: s.forward.id), 0, "у пары удаление не теряет значений")
            try await w.deleteProperty(s.forward.id)
            let projects = try await fresh(w, s.projects)
            guard let back = projects.property(s.back.id) else { return check(false, "обратная сторона осталась") }
            checkEqual(back.config.pair, nil)
            check(!back.config.isBackSide, "стала прямой")
            checkEqual(names(try await w.recordValues(page: p, database: projects)[back.id]).sorted(), ["Два", "Один"], "строки перешли под оставшееся свойство")
            checkEqual(try await w.valueCount(property: back.id), 1)
            try await w.setValue(pages: [p], property: back.id, value: link(t2), now: 4)
            checkEqual(names(try await w.recordValues(page: p, database: projects)[back.id]), ["Два"], "односторонняя правится")

            // Удаление обратной стороны: прямая остаётся с теми же связями.
            s = try await Pair.make(w)
            let q = try await add(w, s.projects, "Другой"), u = try await add(w, s.tasks, "Три")
            try await w.setValue(pages: [u], property: s.forward.id, value: link(q), now: 5)
            try await w.deleteProperty(s.back.id)
            let tasks = try await fresh(w, s.tasks)
            checkEqual(tasks.property(s.forward.id)?.config.pair, nil)
            checkEqual(names(try await w.recordValues(page: u, database: tasks)[s.forward.id]), ["Другой"])
        }
    }

    await test("Связи: окончательное удаление парной базы оставляет самостоятельную связь") {
        try await withSpace { w in
            let s = try await Pair.make(w)
            let p = try await add(w, s.projects, "Проект"), t = try await add(w, s.tasks, "Задача")
            try await w.setValue(pages: [t], property: s.forward.id, value: link(p), now: 3)
            // Удаляется база задач, где лежат строки прямой стороны: у проектов остаётся бывшая обратная сторона.
            let batch = UUID()
            try await w.trashPage(s.tasks.pageID, batch: batch, now: 4)
            try await w.purgeTrash(batch: batch)
            let projects = try await fresh(w, s.projects)
            guard let rest = projects.property(s.back.id) else { return check(false, "свойство осталось") }
            checkEqual(rest.config.pair, nil, "пары нет")
            check(!rest.config.isBackSide, "читается как самостоятельная")
            checkEqual(try await w.recordValues(page: p, database: projects)[rest.id], nil, "строки ушли вместе с задачами")
            checkEqual(try await query(w, projects, FilterRule(property: rest.id, op: .isEmpty, value: "")), ["Проект"])
            await checkThrows("цели больше нет") { try await w.setValue(pages: [p], property: rest.id, value: link(UUID()), now: 5) }
            try await w.deleteProperty(rest.id)
            checkEqual(try await fresh(w, projects).properties.filter { $0.type == .relation }.count, 0)
        }
    }

    await test("Связи: односторонняя и связь базы с самой собой") {
        try await withSpace { w in
            let s = try await Pair.make(w, twoWay: false)
            checkEqual(s.forward.config.pair, nil)
            checkEqual(s.projects.properties.filter { $0.type == .relation }.count, 0, "в целевой базе свойства нет")
            let p = try await add(w, s.projects, "Проект"), t = try await add(w, s.tasks, "Задача")
            try await w.setValue(pages: [t], property: s.forward.id, value: link(p), now: 3)
            checkEqual(names(try await w.recordValues(page: t, database: s.tasks)[s.forward.id]), ["Проект"])

            let d = try await base(w, "Дерево")
            let parentID = UUID(), childrenID = UUID()
            try await w.addRelation(database: d.id, name: "Родитель", target: d.id, twoWay: true, pairName: "Подзадачи", id: parentID, pairID: childrenID, now: 1)
            let tree = try await fresh(w, d)
            let root = try await add(w, tree, "Корень"), leaf1 = try await add(w, tree, "Лист 1"), leaf2 = try await add(w, tree, "Лист 2")
            try await w.setValue(pages: [leaf1, leaf2], property: parentID, value: link(root), now: 3)
            checkEqual(names(try await w.recordValues(page: root, database: tree)[childrenID]), ["Лист 1", "Лист 2"])
            checkEqual(try await query(w, tree, FilterRule(property: parentID, op: .isEmpty, value: "")), ["Корень"])
            await checkThrows("запись из другой базы") { try await w.setValue(pages: [leaf1], property: parentID, value: link(p), now: 3) }
        }
    }

    await test("Связи: дублирование записи, базы и шаблоны записи сохраняют связи (FR-12)") {
        try await withSpace { w in
            let s = try await Pair.make(w)
            let p = try await add(w, s.projects, "Проект"), t = try await add(w, s.tasks, "Задача")
            try await w.setValue(pages: [t], property: s.forward.id, value: link(p), now: 3)

            // Копия записи — в той же базе и связана с тем же проектом с обеих сторон.
            let tc = try await w.duplicatePage(t, title: "Задача копия", ids: RandomIDs(), now: 4)
            checkEqual(names(try await w.recordValues(page: tc, database: s.tasks)[s.forward.id]), ["Проект"])
            checkEqual(names(try await w.recordValues(page: p, database: s.projects)[s.back.id]), ["Задача", "Задача копия"])

            // Копия базы задач: связь смотрит на прежние проекты, но становится односторонней; у проектов копий не прибавилось.
            let copyPage = try await w.duplicatePage(s.tasks.pageID, title: "Задачи 2", ids: RandomIDs(), now: 5)
            guard let copyID = try await w.databaseIndex()[copyPage], let copy = try await w.database(copyID),
                  let rel = copy.properties.first(where: { $0.type == .relation }) else { return check(false, "копия базы") }
            check(rel.id != s.forward.id, "своё свойство")
            checkEqual(rel.config.target, s.projects.id)
            checkEqual(rel.config.pair, nil, "копия без пары")
            let rows = try await w.queryRecords(database: copy, state: DatabaseViewState(), limit: 10, offset: 0).rows
            checkEqual(rows.map { names($0.values[rel.id]) }, [["Проект"], ["Проект"]])
            checkEqual(names(try await w.recordValues(page: p, database: s.projects)[s.back.id]).count, 2, "исходная связь не удвоилась")

            // Копия базы проектов: обратная сторона становится самостоятельной и сохраняет связи.
            let projectsCopy = try await w.duplicatePage(s.projects.pageID, title: "Проекты 2", ids: RandomIDs(), now: 6)
            guard let pcID = try await w.databaseIndex()[projectsCopy], let pc = try await w.database(pcID),
                  let own = pc.properties.first(where: { $0.type == .relation }) else { return check(false, "копия проектов") }
            check(!own.config.isBackSide, "стала прямой")
            checkEqual(own.config.target, s.tasks.id)
            let pcRows = try await w.queryRecords(database: pc, state: DatabaseViewState(), limit: 10, offset: 0).rows
            checkEqual(pcRows.map { names($0.values[own.id]).sorted() }, [["Задача", "Задача копия"]], "порядок у бывшей обратной стороны не задан")
            checkEqual(names(try await w.recordValues(page: t, database: s.tasks)[s.forward.id]), ["Проект"], "у задач копия проектов не появилась")

            // Шаблон записи: новая запись связана с тем же проектом, скрытая копия нигде не видна.
            let template = try await w.saveTemplate(from: t, name: "Шаблон задачи", ids: RandomIDs(), now: 7)
            checkEqual(names(try await w.recordValues(page: p, database: s.projects)[s.back.id]).count, 2, "скрытая копия не видна")
            let made = try await w.instantiate(template: template.id, parent: nil, ids: RandomIDs(), now: 8)
            checkEqual(names(try await w.recordValues(page: made, database: s.tasks)[s.forward.id]), ["Проект"])
            checkEqual(names(try await w.recordValues(page: p, database: s.projects)[s.back.id]).sorted(), ["Задача", "Задача копия", "Шаблон задачи"])
        }
    }

    await test("Связи: база, копия которой связана сама с собой, получает свою пару") {
        try await withSpace { w in
            let d = try await base(w, "Дерево")
            let parentID = UUID(), childrenID = UUID()
            try await w.addRelation(database: d.id, name: "Родитель", target: d.id, twoWay: true, pairName: "Подзадачи", id: parentID, pairID: childrenID, now: 1)
            let tree = try await fresh(w, d)
            let root = try await add(w, tree, "Корень"), leaf = try await add(w, tree, "Лист")
            try await w.setValue(pages: [leaf], property: parentID, value: link(root), now: 3)
            let copyPage = try await w.duplicatePage(d.pageID, title: "Дерево 2", ids: RandomIDs(), now: 4)
            guard let id = try await w.databaseIndex()[copyPage], let copy = try await w.database(id) else { return check(false, "копия") }
            let relations = copy.properties.filter { $0.type == .relation }
            guard let forward = relations.first(where: { !$0.config.isBackSide }), let back = relations.first(where: { $0.config.isBackSide }) else { return check(false, "обе стороны") }
            checkEqual(forward.config.target, copy.id, "цель — сама копия")
            checkEqual(forward.config.pair, back.id)
            checkEqual(back.config.pair, forward.id)
            let rows = try await w.queryRecords(database: copy, state: DatabaseViewState(), limit: 10, offset: 0).rows
            let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })
            checkEqual(names(byTitle["Лист"]?.values[forward.id]), ["Корень"])
            checkEqual(names(byTitle["Корень"]?.values[back.id]), ["Лист"])
            check(byTitle["Лист"].map { row in names(row.values[forward.id]).count == 1 && row.id != leaf } ?? false, "копия ссылается на копию")
            checkEqual(names(try await w.recordValues(page: root, database: tree)[childrenID]), ["Лист"], "оригинал не изменился")
        }
    }

    await test("Создано и Изменено: время из страницы, правка текста и свойства, фильтр по дню") {
        try await withSpace { w in
            var d = try await base(w, "Журнал")
            let created = UUID(), edited = UUID()
            try await w.addProperty(database: d.id, name: "Создано", type: .createdTime, id: created, now: 1)
            try await w.addProperty(database: d.id, name: "Изменено", type: .editedTime, id: edited, now: 1)
            d = try await fresh(w, d)
            let zone = TimeZone(identifier: "Europe/Moscow")!
            var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
            func ms(_ y: Int, _ m: Int, _ day: Int, _ h: Int) -> Int64 { Int64(cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!.timeIntervalSince1970 * 1000) }
            let old = try await add(w, d, "Старая", now: ms(2026, 3, 1, 23))
            let new = try await add(w, d, "Новая", now: ms(2026, 3, 2, 0))
            checkEqual(try await w.recordValues(page: old, database: d)[created], .time(ms(2026, 3, 1, 23)))
            checkEqual(try await w.recordValues(page: old, database: d)[edited], .time(ms(2026, 3, 1, 23)))
            await checkThrows("вручную не меняется") { try await w.setValue(pages: [old], property: created, value: .time(0), now: 5) }

            // Фильтр по дню в поясе пользователя: 23:00 и 00:00 — разные дни.
            func day(_ op: FilterOp, _ value: String) throws -> DatabaseQuerySQL.Fragment? {
                DatabaseQuerySQL.compile(FilterRule(property: created, op: op, value: value), properties: d.properties, zone: zone)
            }
            let good = try day(.equals, "2026-03-01"), bad = try day(.equals, "не дата")
            check(good != nil && bad == nil, "неполное правило пропускается")
            let (start, end) = DatabaseQuerySQL.dayBounds(LocalDate(year: 2026, month: 3, day: 1)!, zone: zone)
            checkEqual(start, ms(2026, 3, 1, 0))
            checkEqual(end, ms(2026, 3, 2, 0))
            let saved = NSTimeZone.default
            NSTimeZone.default = zone
            defer { NSTimeZone.default = saved }
            checkEqual(try await query(w, d, FilterRule(property: created, op: .equals, value: "2026-03-01")), ["Старая"])
            checkEqual(try await query(w, d, FilterRule(property: created, op: .greaterOrEqual, value: "2026-03-02")), ["Новая"])
            checkEqual(try await query(w, d, FilterRule(property: created, op: .lessOrEqual, value: "2026-03-01")), ["Старая"])
            checkEqual(try await query(w, d, FilterRule(property: created, op: .greater, value: "2026-03-01")), ["Новая"])
            checkEqual(try await query(w, d, FilterRule(property: created, op: .less, value: "2026-03-02")), ["Старая"])
            checkEqual(try await query(w, d, sort: SortRule(property: created, descending: true)), ["Новая", "Старая"])

            // Правка свойства и текста двигает «Изменено», «Создано» не меняется.
            let status = d.properties.first { $0.type == .status }!
            try await w.setValue(pages: [old], property: status.id, value: .options([status.options[0].id]), now: ms(2026, 4, 1, 12))
            checkEqual(try await w.recordValues(page: old, database: d)[edited], .time(ms(2026, 4, 1, 12)), "правка свойства")
            checkEqual(try await w.recordValues(page: old, database: d)[created], .time(ms(2026, 3, 1, 23)))
            checkEqual(try await query(w, d, sort: SortRule(property: edited, descending: true)), ["Старая", "Новая"])
            let before = SystemClock().nowMillis()
            var batch = SaveBatch()
            let block = UUID()
            batch.upserts[block] = Block(id: block, pageID: new, sortKey: "a0", content: BlockContent(text: "Текст"), createdAt: 1)
            batch.touchedPages = [new] // Так пакет собирает редактор.
            try await w.commit(batch)
            guard case .time(let touched)? = try await w.recordValues(page: new, database: d)[edited] else { return check(false, "время") }
            check(touched >= before, "правка текста")

            // Пустой абзац, который редактор ставит в новую страницу, — служебная правка: «Изменено» не двигается.
            var quiet = SaveBatch()
            let first = UUID()
            quiet.upserts[first] = Block(id: first, pageID: old, sortKey: "a0", content: BlockContent(text: ""), createdAt: 1)
            quiet.quietPages = [old]
            try await w.commit(quiet)
            checkEqual(try await w.recordValues(page: old, database: d)[edited], .time(ms(2026, 4, 1, 12)), "служебная правка")

            // Смена типа и удаление не трогают страницы.
            await checkThrows("смена типа времени") { try await w.changePropertyType(created, to: .date, zone: "UTC", ids: RandomIDs(), now: 1) }
            checkEqual(try await w.valueCount(property: created), 0)
            try await w.deleteProperty(created)
            checkEqual(try await w.allPages().filter { $0.databaseID == d.id }.count, 2)
        }
    }

    await test("Связи: текст значения для экспорта и запись схемы") {
        let links = PropertyValue.relation([LinkedPage(id: UUID(), title: "Альфа"), LinkedPage(id: UUID(), title: "Бета")])
        checkEqual(PropertyConversion.text(of: links, options: []), "Альфа, Бета")
        var config = PropertyConfig(target: UUID(), pair: UUID(), isBackSide: true)
        config.extra["future"] = .string("x")
        let back = PropertyConfig(json: try config.jsonString())
        checkEqual(back, config, "неизвестные поля сохраняются")
        checkEqual(PropertyConfig(json: "{испорчено"), PropertyConfig(), "испорченные настройки — пустые")
        checkEqual(PropertyConfig(json: nil), PropertyConfig())
        checkEqual(Migrations.supportedVersion, 10, "v10 — комментарии")
    }
}
