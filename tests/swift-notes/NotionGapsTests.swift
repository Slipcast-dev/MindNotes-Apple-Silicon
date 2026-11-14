import Foundation

// Итоги под таблицей, скрытые группы, таблица хронологии и каталог шаблонов.

private func space(_ body: (SQLiteWorkspace) async throws -> Void) async throws {
    try await withTempDir { dir in
        let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
        defer { w.close() }
        try await body(w)
    }
}

private func plainBase(_ w: SQLiteWorkspace) async throws -> Database {
    try await w.createDatabase(parent: nil, template: NewDatabase(title: "Учёт", titleProperty: "Название", statusProperty: "Статус",
                                                                  statusOptions: ["Новая", "Готово"], dateProperty: "Срок", viewName: "Таблица"),
                               ids: RandomIDs(), now: 1)
}

func runNotionGapsTests() async {
    await test("Вид: скрытые группы, итоги и таблица хронологии сохраняются") {
        var state = DatabaseViewState()
        let p = UUID()
        state.setGroup("a", hidden: true)
        state.setGroup("b", hidden: true)
        state.setGroup("a", hidden: false)
        state.hideEmptyGroups = true
        state.showTimelineTable = true
        state.setCalculation(p, .sum, properties: [PropertyDefinition(id: p, databaseID: UUID(), name: "Сумма", type: .number, sortKey: "a")])
        let back = DatabaseViewState(json: try state.jsonString())
        checkEqual(back.hiddenGroups, ["b"])
        check(back.hideEmptyGroups && back.showTimelineTable)
        checkEqual(back.calculation(p), .sum)
        check(back.extra.isEmpty, "новые поля не уходят в extra")
        // Старое состояние без новых полей читается со значениями по умолчанию; незнакомые поля сохраняются.
        let old = DatabaseViewState(json: #"{"groupBy":null,"future":1}"#)
        check(old.hiddenGroups.isEmpty && !old.hideEmptyGroups && !old.showTimelineTable)
        let oldJSON = try old.jsonString(), emptyJSON = try DatabaseViewState().jsonString()
        check(oldJSON.contains("future"))
        check(!emptyJSON.contains("hiddenGroups"), "пустые значения не пишутся")
    }

    await test("Итоги: считаются по всем записям вида с фильтром, а не по загруженной странице") {
        try await space { w in
            var base = try await plainBase(w)
            let amount = UUID(), flag = UUID()
            try await w.addProperty(database: base.id, name: "Сумма", type: .number, id: amount, now: 1)
            try await w.addProperty(database: base.id, name: "Флаг", type: .checkbox, id: flag, now: 1)
            for i in 0..<150 {
                let id = UUID()
                try await w.createRecord(database: base.id, title: i % 10 == 0 ? "" : "Запись \(i)", id: id, now: 2)
                try await w.setValue(pages: [id], property: amount, value: .number(Double(i)), now: 2)
                if i % 4 == 0 { try await w.setValue(pages: [id], property: flag, value: .checkbox(true), now: 2) }
            }
            base = try await w.database(base.id)!
            let title = base.titleProperty!.id
            var state = DatabaseViewState()
            let all = try await w.columnCalculations(database: base, state: state,
                                                     [amount: .sum, flag: .percentChecked, title: .count, UUID(): .count])
            checkEqual(all[amount], .number(Double((0..<150).reduce(0, +))))
            checkEqual(all[title], .number(150))
            checkEqual(all[flag], .number(25.33))
            let empty = try await w.columnCalculations(database: base, state: state, [title: .countEmpty])
            checkEqual(empty[title], .number(15))
            state.filter = FilterGroup(mode: .and, items: [.rule(FilterRule(property: amount, op: .greaterOrEqual, value: "100"))])
            let filtered = try await w.columnCalculations(database: base, state: state, [amount: .average, title: .count])
            checkEqual(filtered[title], .number(50))
            checkEqual(filtered[amount], .number(124.5))
            checkEqual(try await w.columnCalculations(database: base, state: state, [:]).count, 0)
        }
    }

    await test("Каталог: каждый шаблон проходит проверку описания") {
        for template in TemplateCatalog.all {
            checkEqual(CatalogValidation.problems(template), [], template.id)
        }
        checkEqual(Set(TemplateCatalog.all.map(\.id)).count, TemplateCatalog.all.count, "id шаблонов не повторяются")
        var broken = TemplateCatalog.crm
        broken.relations[0].to = "nowhere"
        broken.databases[0].views[0].groupBy = "Нет такого"
        checkEqual(CatalogValidation.problems(broken).count, 3) // база, вид и свёртка по пропавшей связи
    }

    await test("Каталог: каждый шаблон устанавливается целиком") {
        try await space { w in
            let today = LocalDate(iso: "2026-11-14")!
            for template in TemplateCatalog.all {
                let page = try await w.install(template, today: today, now: 10)
                let index = try await w.databaseIndex()
                var bases: [Database] = []
                if let id = index[page] {
                    bases = [try await w.database(id)!]
                } else {
                    let children = try await w.allPages().filter { $0.parentID == page }
                    for child in children { if let id = index[child.id] { bases.append(try await w.database(id)!) } }
                }
                checkEqual(bases.count, template.databases.count, "\(template.id): базы")
                for spec in template.databases {
                    guard let base = bases.first(where: { b in b.views.contains { $0.name == spec.views[0].name } && b.properties.contains { $0.name == spec.titleProperty && $0.type == .title } }) else {
                        check(false, "\(template.id): нет базы \(spec.key)"); continue
                    }
                    for p in spec.properties { check(base.properties.contains { $0.name == p.name }, "\(template.id): свойство \(p.name)") }
                    check(!base.properties.contains { $0.name.hasSuffix("·tmp") }, "\(template.id): временные свойства убраны")
                    checkEqual(base.views.map(\.name), spec.views.map(\.name), "\(template.id): виды")
                    checkEqual(base.views.map(\.kind), spec.views.map(\.kind), "\(template.id): типы видов")
                    let records = try await w.queryRecords(database: base, state: DatabaseViewState(), limit: 100, offset: 0)
                    checkEqual(records.total, spec.records.count, "\(template.id): записи \(spec.key)")
                    for view in spec.views {
                        guard let stored = base.views.first(where: { $0.name == view.name }) else { continue }
                        if let g = view.groupBy { checkEqual(stored.state.groupBy, base.properties.first { $0.name == g }?.id, "\(template.id): группировка") }
                        checkEqual(stored.state.showTimelineTable, view.showTimelineTable)
                        for (name, aggregate) in view.calculations {
                            let id = base.properties.first { $0.name == name }?.id
                            checkEqual(stored.state.columns.first { $0.property == id }?.calculation, aggregate, "\(template.id): итог \(name)")
                        }
                        for name in view.hidden {
                            let id = base.properties.first { $0.name == name }?.id
                            checkEqual(stored.state.columns.first { $0.property == id }?.visible, false, "\(template.id): скрыто \(name)")
                        }
                    }
                }
            }
        }
    }

    await test("Каталог: CRM — связи, свёртка суммы и цвета статусов") {
        try await space { w in
            let root = try await w.install(TemplateCatalog.crm, today: LocalDate(iso: "2026-11-14")!, now: 10)
            let index = try await w.databaseIndex()
            let children = try await w.allPages().filter { $0.parentID == root }
            checkEqual(children.count, 3)
            var byTitle: [String: Database] = [:]
            for child in children { if let id = index[child.id] { byTitle[child.title] = try await w.database(id)! } }
            guard let clients = byTitle["Клиенты"], let orders = byTitle["Заказы"] else { check(false, "нет баз CRM"); return }
            let status = orders.properties.first { $0.type == .status }!
            checkEqual(status.options.map(\.name), ["Принят", "В работе", "Выполнен", "Отменён"])
            checkEqual(status.options.map(\.color), ["orange", "blue", "green", "red"])
            let total = clients.properties.first { $0.name == "Сумма заказов" }!
            checkEqual(total.type, .rollup)
            let rows = try await w.queryRecords(database: clients, state: DatabaseViewState(), limit: 10, offset: 0).rows
            let north = rows.first { $0.title == "ООО «Север»" }
            checkEqual(north?.values[total.id], .number(13200))
            let link = orders.properties.first { $0.name == "Клиент" }!
            let order = try await w.queryRecords(database: orders, state: DatabaseViewState(), limit: 10, offset: 0).rows.first { $0.title == "1001" }
            if case .relation(let pages)? = order?.values[link.id] { checkEqual(pages.map(\.title), ["ИП Иванов"]) } else { check(false, "нет связи заказа") }
        }
    }

    await test("Каталог: формула длительности и даты относительно дня установки") {
        try await space { w in
            let page = try await w.install(TemplateCatalog.projectSchedule, today: LocalDate(iso: "2026-11-14")!, now: 10)
            let id = try await w.databaseIndex()[page]!
            let base = try await w.database(id)!
            let days = base.properties.first { $0.type == .formula }!
            let dates = base.properties.first { $0.type == .date }!
            let rows = try await w.queryRecords(database: base, state: DatabaseViewState(), limit: 20, offset: 0).rows
            let audit = rows.first { $0.title == "Аудит процессов" }
            checkEqual(audit?.values[days.id], .number(14))
            checkEqual(audit?.values[dates.id], .date(DateValue(start: .day(LocalDate(iso: "2026-11-15")!), end: .day(LocalDate(iso: "2026-11-29")!))))
            checkEqual(audit?.icon, "📦")
        }
    }

    await test("Каталог: ошибка на середине убирает созданное в корзину") {
        try await space { w in
            var template = TemplateCatalog.crm
            // Свёртка по связи, которой в хранилище не окажется: проверка описания её пропускает, установка падает.
            template.databases[1].properties.append(.rollup("Сломано", relation: "Заказы с товаром", property: "Нет свойства", .sum))
            _ = await checkThrows("свёртка по несуществующему свойству") { try await w.install(template, today: LocalDate(iso: "2026-11-14")!, now: 10) }
            checkEqual(try await w.allPages().count, 0, "в пространстве ничего не осталось")
        }
    }
}
