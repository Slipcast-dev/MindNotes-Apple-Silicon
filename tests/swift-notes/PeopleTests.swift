import Foundation

/// M10.1: справочник людей и свойство «Человек».
func runPeopleTests() async {
    func space(_ body: (SQLiteWorkspace, Database) async throws -> Void) async throws {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["Новая"], dateProperty: "Срок", viewName: "Таблица"), ids: RandomIDs(), now: 1)
            try await body(w, d)
        }
    }
    func names(_ v: PropertyValue?) -> [String] { if case .people(let p)? = v { return p.map(\.name) }; return [] }

    await test("Люди: справочник — добавление, проверка имени, порядок, переименование видно в записях") {
        try await space { w, d in
            let anna = try await w.addPerson(name: "  Анна ", color: "blue", emoji: "🦊x", id: UUID(), now: 2)
            checkEqual(anna.name, "Анна", "пробелы по краям сняты")
            checkEqual(anna.emoji, "🦊", "эмодзи — один символ")
            checkEqual(anna.label, "🦊 Анна")
            let boris = try await w.addPerson(name: "Борис", color: nil, emoji: nil, id: UUID(), now: 3)
            await checkThrows("пустое имя") { _ = try await w.addPerson(name: "  ", color: nil, emoji: nil, id: UUID(), now: 4) }
            await checkThrows("длинное имя") { _ = try await w.addPerson(name: String(repeating: "я", count: 201), color: nil, emoji: nil, id: UUID(), now: 4) }
            checkEqual(try await w.people().map(\.name), ["Анна", "Борис"], "порядок добавления")

            let prop = UUID(), record = UUID()
            try await w.addProperty(database: d.id, name: "Ответственный", type: .person, id: prop, now: 5)
            try await w.createRecord(database: d.id, title: "Отчёт", id: record, now: 5)
            try await w.setValue(pages: [record], property: prop, value: .people([boris, anna]), now: 6)
            let fresh = try await w.database(d.id)!
            checkEqual(names(try await w.recordValues(page: record, database: fresh)[prop]), ["Борис", "Анна"], "порядок ячейки")
            var renamed = anna
            renamed.name = "Анна К."
            try await w.updatePerson(renamed, now: 7)
            checkEqual(names(try await w.recordValues(page: record, database: fresh)[prop]), ["Борис", "Анна К."], "переименование сразу во всех записях")
            await checkThrows("человек не из справочника") {
                try await w.setValue(pages: [record], property: prop, value: .people([Person(id: UUID(), name: "Чужой")]), now: 8)
            }
            await checkThrows("повтор человека") { try await w.setValue(pages: [record], property: prop, value: .people([boris, boris]), now: 8) }
            await checkThrows("текст в свойство «Человек»") { try await w.setValue(pages: [record], property: prop, value: .unconverted("x"), now: 8) }
            checkEqual(PropertyConversion.text(of: .people([boris, renamed]), options: []), "Борис, Анна К.", "CSV и карточка — имена")
            let card = MarkdownExport.propertyCard(fresh, values: try await w.recordValues(page: record, database: fresh), untitled: "—")
            check(card.contains("Ответственный: Борис, Анна К."), "\(card)")
        }
    }

    await test("Люди: фильтры «содержит», «не содержит», «пусто», сортировка по имени, группы доски") {
        try await space { w, d in
            let anna = try await w.addPerson(name: "Анна", color: nil, emoji: nil, id: UUID(), now: 2)
            let boris = try await w.addPerson(name: "Борис", color: nil, emoji: nil, id: UUID(), now: 2)
            let prop = UUID()
            try await w.addProperty(database: d.id, name: "Кто", type: .person, id: prop, now: 3)
            var ids: [String: UUID] = [:]
            for (title, people) in [("Первая", [boris]), ("Вторая", [anna, boris]), ("Третья", [])] {
                let id = UUID()
                ids[title] = id
                try await w.createRecord(database: d.id, title: title, id: id, now: 4)
                if !people.isEmpty { try await w.setValue(pages: [id], property: prop, value: .people(people), now: 5) }
            }
            let fresh = try await w.database(d.id)!
            func titles(_ rule: FilterRule?, sort: SortRule? = nil) async throws -> [String] {
                var state = DatabaseViewState()
                if let rule { state.filter.items = [.rule(rule)] }
                if let sort { state.sorts = [sort] }
                return try await w.queryRecords(database: fresh, state: state, limit: 10, offset: 0).rows.map(\.title)
            }
            checkEqual(Set(try await titles(FilterRule(property: prop, op: .contains, value: anna.id.uuidString))), ["Вторая"])
            checkEqual(Set(try await titles(FilterRule(property: prop, op: .notContains, value: anna.id.uuidString))), ["Первая", "Третья"])
            checkEqual(try await titles(FilterRule(property: prop, op: .isEmpty, value: "")), ["Третья"])
            checkEqual(Set(try await titles(FilterRule(property: prop, op: .isNotEmpty, value: ""))), ["Первая", "Вторая"])
            checkEqual(try await titles(nil, sort: SortRule(property: prop, descending: false)), ["Вторая", "Первая", "Третья"], "по первому имени, пустые в конце")
            checkEqual(FilterOp.available(for: .person), [.contains, .notContains, .isEmpty, .isNotEmpty])

            let def = fresh.property(prop)!
            check(RecordGroup.isGroupable(.person))
            let groups = RecordGroup.groups(for: def, people: [anna, boris])
            checkEqual(groups.map(\.id), [anna.id.uuidString, boris.id.uuidString, "empty"])
            checkEqual(names(groups[0].value(replacing: .people([anna, boris]), from: groups[0], type: .person)), ["Анна", "Борис"], "внутри своей группы ничего не теряется")
            checkEqual(names(groups[1].value(replacing: .people([anna]), from: groups[0], type: .person)), ["Борис"], "заменяется только человек исходной группы")
            checkEqual(names(groups[1].value(replacing: .people([anna, boris]), from: groups[0], type: .person)), ["Борис"])
            check(groups[2].value(replacing: .people([anna]), from: groups[0], type: .person) == nil, "в «пусто» — без людей")
        }
    }

    await test("Люди: удаление человека снимает его из записей и фильтров, копия базы и формула") {
        try await space { w, d in
            let anna = try await w.addPerson(name: "Анна", color: nil, emoji: nil, id: UUID(), now: 2)
            let boris = try await w.addPerson(name: "Борис", color: nil, emoji: nil, id: UUID(), now: 2)
            let prop = UUID(), record = UUID(), formula = UUID()
            try await w.addProperty(database: d.id, name: "Кто", type: .person, id: prop, now: 3)
            try await w.createRecord(database: d.id, title: "Задача", id: record, now: 4)
            try await w.setValue(pages: [record], property: prop, value: .people([anna, boris]), now: 5)
            try await w.addFormula(database: d.id, name: "Подпись", source: "\"Для: \" + prop(\"Кто\")", id: formula, now: 6)
            var fresh = try await w.database(d.id)!
            checkEqual(try await w.recordValues(page: record, database: fresh)[formula], .text("Для: Анна, Борис"), "формула видит имена")

            // Копия страницы базы: люди те же, свойство — копии.
            let copyPage = try await w.duplicatePage(d.pageID, title: "Копия", ids: RandomIDs(), now: 7)
            let index = try await w.databaseIndex()
            let copy = try await w.database(index[copyPage]!)!
            let copyProp = copy.properties.first { $0.name == "Кто" }!
            let copyRow = try await w.queryRecords(database: copy, state: DatabaseViewState(), limit: 5, offset: 0).rows.first!
            checkEqual(names(copyRow.values[copyProp.id]), ["Анна", "Борис"], "копия хранит людей под своим свойством")

            var state = DatabaseViewState()
            state.filter.items = [.rule(FilterRule(property: prop, op: .contains, value: anna.id.uuidString))]
            try await w.saveViewState(fresh.views[0].id, state)
            checkEqual(try await w.personUsage(anna.id), 2, "запись и её копия")
            try await w.deletePerson(anna.id, now: 8)
            fresh = try await w.database(d.id)!
            checkEqual(names(try await w.recordValues(page: record, database: fresh)[prop]), ["Борис"])
            checkEqual(try await w.recordValues(page: record, database: fresh)[formula], .text("Для: Борис"), "формула пересчитана")
            checkEqual(fresh.views[0].state.filter.ruleCount, 0, "правило с удалённым человеком снято")
            checkEqual(try await w.people().map(\.name), ["Борис"])
        }
    }

    await test("Миграция v7 → v8: данные баз целы, таблицы M10 появились, люди работают") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("w")
            var old = SQLiteWorkspace.Options()
            old.migrations = Array(Migrations.all.prefix { $0.version <= 7 })
            let v7 = try SQLiteWorkspace.create(at: url, name: "Старое", options: old)
            let d = try await v7.createDatabase(parent: nil, template: NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                                                                                  statusOptions: ["Новая"], dateProperty: "Срок", viewName: "Таблица"), ids: RandomIDs(), now: 1)
            let record = UUID()
            try await v7.createRecord(database: d.id, title: "Старая запись", id: record, now: 2)
            let status = d.properties.first { $0.type == .status }!
            try await v7.setValue(pages: [record], property: status.id, value: .options([status.options[0].id]), now: 3)
            checkEqual(try v7.maintenanceWrite { try $0.scalarInt("PRAGMA user_version") }, 7)
            v7.close()

            let w = try SQLiteWorkspace.open(at: url)
            defer { w.close() }
            checkEqual(try w.maintenanceWrite { try $0.scalarInt("PRAGMA user_version") }, 10, "открытие доводит до последней версии")
            for table in ["page_sections", "page_section_members", "comments"] {
                let found = try w.maintenanceWrite { try $0.scalarInt("SELECT 1 FROM sqlite_master WHERE name=?", [.text(table)]) }
                check(found != nil, "таблица v9 \(table)")
            }
            for table in ["people", "property_value_people", "property_value_assets", "view_record_order"] {
                checkEqual(try w.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]) }, 1, table)
            }
            let fresh = try await w.database(d.id)!
            checkEqual(try await w.recordValues(page: record, database: fresh)[status.id], .options([status.options[0].id]), "значение пережило миграцию")
            let anna = try await w.addPerson(name: "Анна", color: nil, emoji: nil, id: UUID(), now: 4)
            let prop = UUID()
            try await w.addProperty(database: d.id, name: "Кто", type: .person, id: prop, now: 5)
            try await w.setValue(pages: [record], property: prop, value: .people([anna]), now: 6)
            checkEqual(names(try await w.recordValues(page: record, database: try await w.database(d.id)!)[prop]), ["Анна"])
        }
    }
}
