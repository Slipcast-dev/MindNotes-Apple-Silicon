import Foundation

private let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                                   statusOptions: ["Запланировано", "В работе", "Готово"], dateProperty: "Срок", viewName: "Таблица")

private func makeDatabase(_ w: SQLiteWorkspace) async throws -> Database {
    try await w.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
}

private func record(_ w: SQLiteWorkspace, _ d: Database, _ title: String) async throws -> UUID {
    let id = UUID()
    try await w.createRecord(database: d.id, title: title, id: id, now: 2)
    return id
}

private func titles(_ w: SQLiteWorkspace, _ d: Database, _ state: DatabaseViewState) async throws -> [String] {
    try await w.queryRecords(database: d, state: state, limit: 100, offset: 0).rows.map(\.title)
}

private func reload(_ w: SQLiteWorkspace, _ d: Database) async throws -> Database {
    guard let fresh = try await w.database(d.id) else { throw WorkspaceError.corrupted("нет базы") }
    return fresh
}

private func withWorkspace(_ body: (SQLiteWorkspace) async throws -> Void) async throws {
    try await withTempDir { dir in
        let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
        defer { w.close() }
        try await body(w)
    }
}

private func prop(_ d: Database, _ type: PropertyType) -> PropertyDefinition { d.properties.first { $0.type == type }! }

private func ruleState(_ rule: FilterRule) -> DatabaseViewState {
    var s = DatabaseViewState()
    s.filter.items = [.rule(rule)]
    return s
}

func runDatabaseTests() async {
    await test("Переименование: настройки и каталог копируются один раз, оригиналы целы") {
        try await withTempDir { dir in
            let fm = FileManager.default
            let oldName = "test.legacy.old.\(UUID().uuidString)", newName = "test.legacy.new.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: newName)!
            defer {
                defaults.removePersistentDomain(forName: oldName)
                defaults.removePersistentDomain(forName: newName)
            }
            defaults.setPersistentDomain(["theme": "grizzly", "language": "ru", "shared": "старое"], forName: oldName)
            defaults.set("новое", forKey: "shared")
            let old = dir.appendingPathComponent("Old"), new = dir.appendingPathComponent("sub/New")
            try fm.createDirectory(at: old.appendingPathComponent("Backups"), withIntermediateDirectories: true)
            try Data("архив".utf8).write(to: old.appendingPathComponent("Backups/a.grizzlybackup"))

            check(LegacyDataMigration.run(defaults: defaults, oldDomain: oldName, newDomain: newName, oldSupport: old, newSupport: new))
            checkEqual(defaults.string(forKey: "theme"), "grizzly", "настройка скопирована")
            checkEqual(defaults.string(forKey: "shared"), "новое", "новая настройка важнее")
            check(fm.fileExists(atPath: new.appendingPathComponent("Backups/a.grizzlybackup").path), "каталог скопирован")
            check(fm.fileExists(atPath: old.appendingPathComponent("Backups/a.grizzlybackup").path), "оригинал на месте")
            check(!fm.fileExists(atPath: new.path + ".partial"))
            checkEqual(defaults.persistentDomain(forName: oldName)?["theme"] as? String, "grizzly", "старые настройки на месте")

            // Повторный запуск ничего не трогает.
            defaults.set("выбрано потом", forKey: "theme")
            try fm.removeItem(at: new)
            check(LegacyDataMigration.run(defaults: defaults, oldDomain: oldName, newDomain: newName, oldSupport: old, newSupport: new))
            checkEqual(defaults.string(forKey: "theme"), "выбрано потом")
            check(!fm.fileExists(atPath: new.path), "отметка не даёт копировать снова")
        }
    }

    await test("Переименование: сбой копирования не ставит отметку, существующий каталог не перезаписывается") {
        try await withTempDir { dir in
            let fm = FileManager.default
            let name = "test.legacy.fail.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let old = dir.appendingPathComponent("Old")
            try fm.createDirectory(at: old, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: old.appendingPathComponent("f"))
            let locked = dir.appendingPathComponent("locked")
            try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            check(!LegacyDataMigration.run(defaults: defaults, oldDomain: "none", newDomain: name, oldSupport: old, newSupport: locked.appendingPathComponent("New")))
            check(!defaults.bool(forKey: LegacyDataMigration.marker), "повторится при следующем запуске")

            let existing = dir.appendingPathComponent("Existing")
            try fm.createDirectory(at: existing, withIntermediateDirectories: true)
            try Data("мои".utf8).write(to: existing.appendingPathComponent("mine"))
            check(LegacyDataMigration.run(defaults: defaults, oldDomain: "none", newDomain: name, oldSupport: old, newSupport: existing))
            check(fm.fileExists(atPath: existing.appendingPathComponent("mine").path))
            check(!fm.fileExists(atPath: existing.appendingPathComponent("f").path))
        }
    }

    await test("Базы: даты не сдвигаются при смене часового пояса (FR-10)") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let r = try await record(w, d, "Запись")
            let date = prop(d, .date)
            let day = LocalDate(year: 2026, month: 3, day: 8)!
            try await w.setValue(pages: [r], property: date.id, value: .date(DateValue(start: .day(day))), now: 3)
            let saved = NSTimeZone.default
            defer { NSTimeZone.default = saved }
            for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/New_York", "Europe/Moscow", "Asia/Tokyo", "UTC"] {
                let tz = TimeZone(identifier: zone)!
                NSTimeZone.default = tz
                let values = try await w.recordValues(page: r, database: d)
                checkEqual(values[date.id], .date(DateValue(start: .day(day))), zone)
                // Путь через календарь интерфейса тоже не меняет день.
                checkEqual(LocalDate(date: day.date(in: tz), in: tz), day, "календарь \(zone)")
                var on = DatabaseViewState()
                on.filter.items = [.rule(FilterRule(property: date.id, op: .equals, value: "2026-03-08"))]
                checkEqual(try await titles(w, d, on), ["Запись"], "фильтр \(zone)")
            }
            // Переход на летнее время в США приходится на этот день.
            checkEqual(LocalDate(date: day.date(in: TimeZone(identifier: "America/New_York")!), in: TimeZone(identifier: "America/New_York")!), day)
        }
    }

    await test("Базы: момент времени хранит пояс и не зависит от системного") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let r = try await record(w, d, "Встреча")
            let date = prop(d, .date)
            let value = PropertyValue.date(DateValue(start: .moment(ms: 1_800_000_000_000, zone: "Asia/Tokyo"), end: .moment(ms: 1_800_003_600_000, zone: "Asia/Tokyo")))
            try await w.setValue(pages: [r], property: date.id, value: value, now: 3)
            let saved = NSTimeZone.default
            defer { NSTimeZone.default = saved }
            NSTimeZone.default = TimeZone(identifier: "America/New_York")!
            checkEqual(try await w.recordValues(page: r, database: d)[date.id], value)
            let bad = PropertyValue.date(DateValue(start: .day(LocalDate(year: 2026, month: 5, day: 2)!), end: .day(LocalDate(year: 2026, month: 5, day: 1)!)))
            await checkThrows("конец раньше начала") { try await w.setValue(pages: [r], property: date.id, value: bad, now: 3) }
        }
    }

    await test("Базы: разбор дат и чисел") {
        check(LocalDate(iso: "2026-02-30") == nil)
        check(LocalDate(iso: "2026-2-3") == nil)
        check(LocalDate(iso: "2028-02-29") != nil)
        checkEqual(PropertyParse.date("09.11.2026", zone: "UTC"), DateValue(start: .day(LocalDate(year: 2026, month: 11, day: 9)!)))
        check(PropertyParse.date("31.02.2026", zone: "UTC") == nil)
        check(PropertyParse.date("2026-11-09 — 2026-11-01", zone: "UTC") == nil)
        checkEqual(PropertyParse.number("1 234,5"), 1234.5)
        check(PropertyParse.number("abc") == nil)
        check(PropertyParse.number("inf") == nil)
        check(PropertyParse.url("javascript:alert(1)") == nil)
        check(PropertyParse.url("file:///etc/passwd") == nil)
        check(PropertyParse.url("https://example.com/а") != nil)
        checkEqual(PropertyParse.openable("example.com")?.absoluteString, "https://example.com")
    }

    await test("Базы: запись открывается как обычная страница и живёт в корзине") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let r = try await record(w, d, "Запись")
            let page = try await w.page(r)
            checkEqual(page?.databaseID, d.id)
            checkEqual(page?.parentID, d.pageID)
            let blockID = UUID()
            var batch = SaveBatch()
            batch.upserts[blockID] = Block(id: blockID, pageID: r, sortKey: "a0", content: BlockContent(text: "Текст записи"), createdAt: 1)
            try await w.commit(batch)
            checkEqual(try await w.blocks(ofPage: r).count, 1)
            checkEqual(try await w.search("записи").first?.pageID, r)

            let batchID = UUID()
            try await w.trashPage(r, batch: batchID, now: 3)
            checkEqual(try await titles(w, d, DatabaseViewState()), [], "корзина скрывает запись")
            _ = try await w.restoreTrash(batch: batchID)
            checkEqual(try await titles(w, d, DatabaseViewState()), ["Запись"])
            await checkThrows("запись не перемещается из базы") { try await w.movePage(r, toParent: nil, afterSibling: nil, now: 4) }
            let other = try await w.createPage(parent: nil, title: "Страница", id: UUID(), now: 4)
            await checkThrows("в базу нельзя положить страницу") { try await w.movePage(other.id, toParent: d.pageID, afterSibling: nil, now: 4) }
        }
    }

    await test("Базы: запись дождётся восстановления базы; окончательное удаление чисто") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let r = try await record(w, d, "Запись")
            let keep = try await record(w, d, "Вторая")
            let date = prop(d, .date)
            try await w.setValue(pages: [r], property: date.id, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 1, day: 1)!))), now: 3)
            let recordBatch = UUID(), dbBatch = UUID()
            try await w.trashPage(r, batch: recordBatch, now: 3)
            try await w.trashPage(d.pageID, batch: dbBatch, now: 4)
            checkEqual(try await w.trashItems().count, 2)
            checkEqual(try await w.restoreTrash(batch: recordBatch), true, "родитель в корзине")
            checkEqual(try await w.page(r)?.parentID, nil)
            _ = try await w.restoreTrash(batch: dbBatch)
            checkEqual(try await w.page(r)?.parentID, d.pageID, "запись вернулась в базу")
            checkEqual(try await w.page(keep)?.deletedAt, nil)
            checkEqual(try await titles(w, d, DatabaseViewState()).sorted(), ["Вторая", "Запись"])

            let again = UUID()
            try await w.trashPage(d.pageID, batch: again, now: 5)
            try await w.purgeTrash(batch: again)
            let gone = try await w.database(d.id)
            check(gone == nil)
            let goneRecord = try await w.page(r)
            check(goneRecord == nil)
            let leftovers = try await w.reader.run { try $0.scalarInt("SELECT (SELECT count(*) FROM property_values) + (SELECT count(*) FROM property_definitions) + (SELECT count(*) FROM database_views)") }
            checkEqual(leftovers, 0, "значения не остаются")
        }
    }

    await test("Базы: фильтры по типам, группы И/ИЛИ, ё/е и регистр") {
        try await withWorkspace { w in
            var d = try await makeDatabase(w)
            let a = try await record(w, d, "Ёлка Новогодняя")
            let b = try await record(w, d, "Проект")
            let c = try await record(w, d, "Ремонт")
            let status = prop(d, .status), date = prop(d, .date), title = prop(d, .title)
            let n = UUID(), f = UUID()
            try await w.addProperty(database: d.id, name: "Часы", type: .number, id: n, now: 1)
            try await w.addProperty(database: d.id, name: "Важно", type: .checkbox, id: f, now: 1)
            d = try await reload(w, d)
            try await w.setValue(pages: [a], property: n, value: .number(5), now: 2)
            try await w.setValue(pages: [b], property: n, value: .number(10.5), now: 2)
            try await w.setValue(pages: [a], property: f, value: .checkbox(true), now: 2)
            try await w.setValue(pages: [b], property: f, value: .checkbox(false), now: 2)
            try await w.setValue(pages: [a, b], property: status.id, value: .options([status.options[1].id]), now: 2)
            try await w.setValue(pages: [c], property: status.id, value: .options([status.options[2].id]), now: 2)
            let range = DateValue(start: .day(LocalDate(year: 2026, month: 5, day: 10)!), end: .day(LocalDate(year: 2026, month: 5, day: 12)!))
            try await w.setValue(pages: [a], property: date.id, value: .date(range), now: 2)

            func run(_ rule: FilterRule) async throws -> Set<String> { Set(try await titles(w, d, ruleState(rule))) }
            checkEqual(try await run(FilterRule(property: title.id, op: .contains, value: "елка")), ["Ёлка Новогодняя"], "ё/е")
            checkEqual(try await run(FilterRule(property: title.id, op: .contains, value: "ПРОЕКТ")), ["Проект"], "регистр")
            checkEqual(try await run(FilterRule(property: title.id, op: .notContains, value: "проект")), ["Ёлка Новогодняя", "Ремонт"])
            checkEqual(try await run(FilterRule(property: title.id, op: .startsWith, value: "рем")), ["Ремонт"])
            checkEqual(try await run(FilterRule(property: n, op: .greater, value: "5")), ["Проект"])
            checkEqual(try await run(FilterRule(property: n, op: .lessOrEqual, value: "5,0")), ["Ёлка Новогодняя"])
            checkEqual(try await run(FilterRule(property: n, op: .isEmpty, value: "")), ["Ремонт"])
            checkEqual(try await run(FilterRule(property: f, op: .isTrue, value: "")), ["Ёлка Новогодняя"])
            checkEqual(try await run(FilterRule(property: f, op: .isFalse, value: "")), ["Проект", "Ремонт"], "нет значения — не отмечено")
            checkEqual(try await run(FilterRule(property: status.id, op: .equals, value: status.options[2].id.uuidString)), ["Ремонт"])
            checkEqual(try await run(FilterRule(property: status.id, op: .notEquals, value: status.options[2].id.uuidString)), ["Ёлка Новогодняя", "Проект"])
            checkEqual(try await run(FilterRule(property: date.id, op: .equals, value: "2026-05-11")), ["Ёлка Новогодняя"], "день внутри диапазона")
            checkEqual(try await run(FilterRule(property: date.id, op: .greater, value: "2026-05-12")), [], "конец диапазона")
            checkEqual(try await run(FilterRule(property: date.id, op: .greaterOrEqual, value: "2026-05-12")), ["Ёлка Новогодняя"])

            var or = DatabaseViewState()
            or.filter = FilterGroup(mode: .or, items: [
                .rule(FilterRule(property: title.id, op: .contains, value: "ремонт")),
                .group(FilterGroup(mode: .and, items: [
                    .rule(FilterRule(property: f, op: .isTrue, value: "")),
                    .rule(FilterRule(property: n, op: .equals, value: "5")),
                ])),
            ])
            checkEqual(Set(try await titles(w, d, or)), ["Ремонт", "Ёлка Новогодняя"], "вложенная группа")
        }
    }

    await test("Базы: значения фильтра не попадают в SQL, неполные правила пропускаются") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            _ = try await record(w, d, "Запись")
            let title = prop(d, .title), date = prop(d, .date), status = prop(d, .status)
            let attack = "'); DROP TABLE pages; --"
            checkEqual(try await titles(w, d, ruleState(FilterRule(property: title.id, op: .contains, value: attack))), [])
            checkEqual(try await w.allPages().count, 2, "таблица цела")
            // Подстановочные знаки LIKE не работают: поиск идёт по подстроке.
            checkEqual(try await titles(w, d, ruleState(FilterRule(property: title.id, op: .contains, value: "%"))), [])
            let all = ["Запись"]
            checkEqual(try await titles(w, d, ruleState(FilterRule(property: title.id, op: .contains, value: "  "))), all, "пустое значение")
            checkEqual(try await titles(w, d, ruleState(FilterRule(property: date.id, op: .equals, value: "вчера"))), all, "неверная дата")
            checkEqual(try await titles(w, d, ruleState(FilterRule(property: UUID(), op: .contains, value: "x"))), all, "неизвестное свойство")
            checkEqual(try await titles(w, d, ruleState(FilterRule(property: title.id, op: FilterOp(rawValue: "; DROP"), value: "x"))), all, "неизвестная операция")
            checkEqual(try await titles(w, d, ruleState(FilterRule(property: status.id, op: .equals, value: UUID().uuidString))), all, "удалённый вариант")
        }
    }

    await test("Базы: сортировка, пустые в конце, порядок статусов, страницы") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let status = prop(d, .status), date = prop(d, .date), title = prop(d, .title)
            let a = try await record(w, d, "Б"), b = try await record(w, d, "А"), c = try await record(w, d, "В")
            try await w.setValue(pages: [a], property: status.id, value: .options([status.options[2].id]), now: 2)
            try await w.setValue(pages: [b], property: status.id, value: .options([status.options[0].id]), now: 2)
            try await w.setValue(pages: [a], property: date.id, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 2, day: 1)!))), now: 2)
            try await w.setValue(pages: [c], property: date.id, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 1, day: 1)!))), now: 2)
            func order(_ rules: [SortRule]) async throws -> [String] {
                var s = DatabaseViewState()
                s.sorts = rules
                return try await titles(w, d, s)
            }
            checkEqual(try await order([SortRule(property: title.id)]), ["А", "Б", "В"])
            checkEqual(try await order([SortRule(property: title.id, descending: true)]), ["В", "Б", "А"])
            checkEqual(try await order([SortRule(property: date.id)]), ["В", "Б", "А"], "пустая дата в конце")
            checkEqual(try await order([SortRule(property: date.id, descending: true)]), ["Б", "В", "А"], "пустая дата в конце и при убывании")
            checkEqual(try await order([SortRule(property: status.id)]), ["А", "Б", "В"], "порядок вариантов, а не имён")
            try await w.reorderOptions(property: status.id, ordered: status.options.map(\.id).reversed())
            let fresh = try await reload(w, d)
            var s = DatabaseViewState()
            s.sorts = [SortRule(property: status.id)]
            checkEqual(try await titles(w, fresh, s), ["Б", "А", "В"], "порядок изменён")

            for i in 0..<25 { _ = try await record(w, d, "Запись \(i)") }
            let first = try await w.queryRecords(database: d, state: DatabaseViewState(), limit: 10, offset: 0)
            let second = try await w.queryRecords(database: d, state: DatabaseViewState(), limit: 10, offset: 10)
            checkEqual(first.total, 28)
            checkEqual(first.rows.count, 10)
            checkEqual(Set(first.rows.map(\.id)).intersection(second.rows.map(\.id)).count, 0, "страницы не пересекаются")
        }
    }

    await test("Базы: значение проверяется по типу, запись — по базе; массовое изменение целиком") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let other = try await w.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
            let r = try await record(w, d, "А"), r2 = try await record(w, d, "Б")
            let foreign = try await record(w, other, "Чужая")
            let status = prop(d, .status), date = prop(d, .date), title = prop(d, .title)
            await checkThrows("текст в дату") { try await w.setValue(pages: [r], property: date.id, value: .text("завтра"), now: 2) }
            await checkThrows("чужой вариант") { try await w.setValue(pages: [r], property: status.id, value: .options([UUID()]), now: 2) }
            await checkThrows("два варианта в одиночном выборе") { try await w.setValue(pages: [r], property: status.id, value: .options(status.options.prefix(2).map(\.id)), now: 2) }
            await checkThrows("заголовок хранится в странице") { try await w.setValue(pages: [r], property: title.id, value: .text("x"), now: 2) }
            let done = PropertyValue.options([status.options[2].id])
            await checkThrows("чужая запись отменяет весь пакет") { try await w.setValue(pages: [r, foreign], property: status.id, value: done, now: 2) }
            checkEqual(try await w.recordValues(page: r, database: d)[status.id], nil, "ничего не записано")
            try await w.setValue(pages: [r, r2], property: status.id, value: done, now: 3)
            checkEqual(try await w.recordValues(page: r2, database: d)[status.id], done)
            checkEqual(try await w.page(r)?.updatedAt, 3)
            try await w.setValue(pages: [r], property: status.id, value: nil, now: 4)
            checkEqual(try await w.recordValues(page: r, database: d)[status.id], nil, "очистка")
        }
    }

    await test("Базы: смена типа — просмотр совпадает с результатом, несовместимое не теряется") {
        try await withWorkspace { w in
            var d = try await makeDatabase(w)
            let a = try await record(w, d, "А"), b = try await record(w, d, "Б"), c = try await record(w, d, "В")
            let p = UUID()
            try await w.addProperty(database: d.id, name: "Заметка", type: .text, id: p, now: 1)
            try await w.setValue(pages: [a], property: p, value: .text("12,5"), now: 2)
            try await w.setValue(pages: [b], property: p, value: .text("много"), now: 2)
            try await w.setValue(pages: [c], property: p, value: .text("7"), now: 2)
            let before = try await w.reader.run { try $0.scalarInt("SELECT count(*) FROM property_values WHERE property_id=?", [SQLValue(p)]) }

            let preview = try await w.previewTypeChange(property: p, to: .number, zone: "UTC")
            checkEqual(preview.total, 3)
            checkEqual(preview.failed, 1)
            d = try await reload(w, d)
            checkEqual(d.property(p)?.type, .text, "просмотр ничего не меняет")
            checkEqual(try await w.reader.run { try $0.scalarInt("SELECT count(*) FROM property_values WHERE property_id=?", [SQLValue(p)]) }, before)

            var state = DatabaseViewState()
            state.filter.items = [.rule(FilterRule(property: p, op: .contains, value: "x"))]
            state.sorts = [SortRule(property: p)]
            try await w.saveViewState(d.views[0].id, state)

            try await w.changePropertyType(p, to: .number, zone: "UTC", ids: RandomIDs(), now: 3)
            d = try await reload(w, d)
            checkEqual(try await w.recordValues(page: a, database: d)[p], .number(12.5))
            checkEqual(try await w.recordValues(page: b, database: d)[p], .unconverted("много"), "значение сохранено")
            checkEqual(d.views[0].state.filter.ruleCount, 0, "правило прежнего типа снято")
            checkEqual(d.views[0].state.sorts.count, 1, "сортировка осталась")

            // Обратная смена возвращает исходный текст.
            try await w.changePropertyType(p, to: .text, zone: "UTC", ids: RandomIDs(), now: 4)
            d = try await reload(w, d)
            checkEqual(try await w.recordValues(page: b, database: d)[p], .text("много"))

            // В выбор: значения становятся вариантами с постоянными ID, одинаковые совпадают.
            try await w.setValue(pages: [c], property: p, value: .text("МНОГО"), now: 5)
            let toSelect = try await w.previewTypeChange(property: p, to: .select, zone: "UTC")
            checkEqual(toSelect.failed, 0)
            checkEqual(toSelect.newOptions.count, 2, "«много» и «МНОГО» — один вариант: \(toSelect.newOptions)")
            try await w.changePropertyType(p, to: .select, zone: "UTC", ids: RandomIDs(), now: 6)
            d = try await reload(w, d)
            let vb = try await w.recordValues(page: b, database: d)[p], vc = try await w.recordValues(page: c, database: d)[p]
            checkEqual(vb, vc)
            checkEqual(d.property(p)?.options.count, 2)
            let oldOption = d.property(p)!.options[0].id
            try await w.updateOption(oldOption, name: "Новое имя", color: "blue")
            d = try await reload(w, d)
            checkEqual(d.property(p)?.options[0].id, oldOption, "ID постоянен при переименовании")

            // Из множественного в текст и обратно.
            try await w.changePropertyType(p, to: .multiSelect, zone: "UTC", ids: RandomIDs(), now: 7)
            d = try await reload(w, d)
            if case .options(let ids)? = try await w.recordValues(page: b, database: d)[p] { checkEqual(ids.count, 1) } else { check(false, "варианты") }

            let title = prop(d, .title)
            await checkThrows("тип заголовка не меняется") { try await w.changePropertyType(title.id, to: .text, zone: "UTC", ids: RandomIDs(), now: 8) }
        }
    }

    await test("Базы: удаление свойства и варианта очищает представления; фильтры устойчивы") {
        try await withWorkspace { w in
            var d = try await makeDatabase(w)
            let r = try await record(w, d, "А")
            let status = prop(d, .status), date = prop(d, .date), title = prop(d, .title)
            try await w.setValue(pages: [r], property: status.id, value: .options([status.options[0].id]), now: 2)
            var state = DatabaseViewState()
            state.filter.items = [
                .rule(FilterRule(property: status.id, op: .equals, value: status.options[0].id.uuidString)),
                .group(FilterGroup(mode: .or, items: [.rule(FilterRule(property: date.id, op: .isEmpty, value: ""))])),
            ]
            state.sorts = [SortRule(property: date.id)]
            state.columns = [ColumnState(property: date.id, visible: false), ColumnState(property: title.id)]
            try await w.saveViewState(d.views[0].id, state)
            checkEqual(try await reload(w, d).views[0].state, state, "состояние переживает чтение")
            checkEqual(try await w.valueCount(option: status.options[0].id), 1)

            try await w.deleteOption(status.options[0].id)
            d = try await reload(w, d)
            checkEqual(d.views[0].state.filter.ruleCount, 1, "правило удалённого варианта снято")
            checkEqual(try await w.recordValues(page: r, database: d)[status.id], nil)
            checkEqual(d.property(status.id)?.options.count, 2, "другие варианты целы")

            try await w.deleteProperty(date.id)
            d = try await reload(w, d)
            checkEqual(d.views[0].state.filter.ruleCount, 0)
            checkEqual(d.views[0].state.sorts.count, 0)
            check(!d.views[0].state.columns.contains { $0.property == date.id })
            checkEqual(try await titles(w, d, d.views[0].state), ["А"])
            await checkThrows("заголовок не удаляется") { try await w.deleteProperty(title.id) }
            await checkThrows("последнее представление") { try await w.deleteView(d.views[0].id, database: d.id) }
            let board = UUID()
            try await w.createView(database: d.id, name: "Доска", kind: "board", state: DatabaseViewState(), id: board)
            await checkThrows("другой вид не заменяет последнюю таблицу") { try await w.deleteView(d.views[0].id, database: d.id) }
            let foreign = try await makeDatabase(w)
            try await w.deleteView(board, database: foreign.id)
            checkEqual(try await reload(w, d).views.count, 2, "чужая база не удаляет представление")
            try await w.deleteView(board, database: d.id)
            checkEqual(try await reload(w, d).views.count, 1)
        }
    }

    await test("Базы: состояние представления хранит неизвестные поля и столбцы") {
        let id = UUID(), other = UUID()
        let json = "{\"future\":{\"a\":1},\"kindData\":\"x\",\"sorts\":[{\"property\":\"\(id.uuidString)\",\"descending\":true}]}"
        let state = DatabaseViewState(json: json)
        checkEqual(state.sorts.first?.descending, true)
        let round = DatabaseViewState(json: try state.jsonString())
        checkEqual(round, state, "неизвестные поля пережили запись")
        check(round.extra["future"] != nil)
        checkEqual(DatabaseViewState(json: "не json"), DatabaseViewState())

        let unknownOp = "{\"filter\":{\"mode\":\"or\",\"items\":[{\"rule\":{\"_0\":{\"property\":\"\(id.uuidString)\",\"op\":\"future_op\",\"value\":\"1\"}}}]}}"
        checkEqual(DatabaseViewState(json: unknownOp).filter.mode, .or, "неизвестная операция не ломает разбор")

        let db = UUID()
        let props = [PropertyDefinition(id: id, databaseID: db, name: "Т", type: .title, sortKey: "a"),
                     PropertyDefinition(id: other, databaseID: db, name: "Н", type: .text, sortKey: "b")]
        var columns = DatabaseViewState()
        columns.columns = [ColumnState(property: other), ColumnState(property: id, visible: false), ColumnState(property: UUID())]
        let ordered = columns.orderedColumns(props)
        checkEqual(ordered.map(\.property), [other, id], "порядок, удалённое убрано")
        checkEqual(ordered[1].visible, true, "заголовок нельзя скрыть")
        checkEqual(DatabaseViewState().orderedColumns(props).map(\.property), [id, other], "новое свойство появляется само")
    }

    await test("Базы: дублирование копирует базу и записи; копия записи остаётся в базе") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let r = try await record(w, d, "Запись")
            let status = prop(d, .status), date = prop(d, .date)
            let chosen = PropertyValue.options([status.options[1].id])
            let day = PropertyValue.date(DateValue(start: .day(LocalDate(year: 2026, month: 1, day: 2)!)))
            try await w.setValue(pages: [r], property: status.id, value: chosen, now: 2)
            try await w.setValue(pages: [r], property: date.id, value: day, now: 2)
            var state = DatabaseViewState()
            state.filter.items = [.rule(FilterRule(property: status.id, op: .equals, value: status.options[1].id.uuidString))]
            try await w.saveViewState(d.views[0].id, state)

            let recordCopy = try await w.duplicatePage(r, title: "Копия", ids: RandomIDs(), now: 3)
            checkEqual(try await w.page(recordCopy)?.databaseID, d.id)
            checkEqual(try await w.recordValues(page: recordCopy, database: d)[status.id], chosen)
            checkEqual(try await titles(w, d, state).count, 2)

            let pageCopy = try await w.duplicatePage(d.pageID, title: "Задачи копия", ids: RandomIDs(), now: 4)
            let index = try await w.databaseIndex()
            guard let copyID = index[pageCopy], let copy = try await w.database(copyID) else { return check(false, "копия базы") }
            check(copy.id != d.id)
            check(prop(copy, .status).id != status.id, "свои свойства")
            let copyRows = try await w.queryRecords(database: copy, state: copy.views[0].state, limit: 10, offset: 0)
            checkEqual(copyRows.total, 2, "фильтр копии смотрит на её варианты")
            checkEqual(copyRows.rows.first?.values[prop(copy, .status).id], .options([prop(copy, .status).options[1].id]))
            try await w.setValue(pages: [copyRows.rows[0].id], property: prop(copy, .date).id, value: nil, now: 5)
            checkEqual(try await w.recordValues(page: r, database: d)[date.id], day, "оригинал не зависит от копии")
            let violations = try await w.reader.run { try $0.query("PRAGMA foreign_key_check") { $0.text(0) } }
            checkEqual(violations, [])
        }
    }

    await test("Базы: копия и восстановление сохраняют свойства; миграция с v1") {
        try await withTempDir { dir in
            let root = dir.appendingPathComponent("w")
            let w = try SQLiteWorkspace.create(at: root, name: "T")
            let d = try await makeDatabase(w)
            let r = try await record(w, d, "Запись")
            let status = prop(d, .status)
            let value = PropertyValue.options([status.options[2].id])
            try await w.setValue(pages: [r], property: status.id, value: value, now: 2)
            let archive = dir.appendingPathComponent("a.minervabackup")
            _ = try BackupService.create(workspaceRoot: root, snapshotter: w, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 3)
            w.close()
            let target = dir.appendingPathComponent("r")
            _ = try RestoreService.restore(archive: archive, to: target, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 4)
            let restored = try SQLiteWorkspace.open(at: target)
            defer { restored.close() }
            guard let fresh = try await restored.database(d.id) else { return check(false, "база в копии") }
            checkEqual(try await restored.recordValues(page: r, database: fresh)[status.id], value)

            let old = dir.appendingPathComponent("old")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            let c = try SQLiteConnection(path: WorkspaceLayout(root: old).database.path, create: true)
            try c.execute("PRAGMA application_id=\(Migrations.applicationID)")
            try c.execute(try String(contentsOfFile: "tests/fixtures/notes/schema_v1.sql"))
            try c.execute("PRAGMA user_version=1")
            let page = UUID()
            try c.run("INSERT INTO workspace_meta(key, value) VALUES('workspace_id', ?), ('name', 'Старое')", [SQLValue(UUID())])
            try c.run("INSERT INTO pages(id, sort_key, title, created_at, updated_at) VALUES(?, 'a0', 'Страница v1', 1, 1)", [SQLValue(page)])
            c.close()
            let migrated = try SQLiteWorkspace.open(at: old)
            defer { migrated.close() }
            checkEqual(try await migrated.page(page)?.title, "Страница v1")
            checkEqual(try await migrated.page(page)?.databaseID, nil)
            let db2 = try await makeDatabase(migrated)
            _ = try await record(migrated, db2, "Новая")
            checkEqual(try await titles(migrated, db2, DatabaseViewState()), ["Новая"])
        }
    }

    await test("Базы: 5000 записей, запрос страницы не читает всё") {
        try await withWorkspace { w in
            let d = try await makeDatabase(w)
            let status = prop(d, .status), date = prop(d, .date), title = prop(d, .title)
            try await w.writer.run { db in
                try db.transaction {
                    for i in 0..<5000 {
                        let id = UUID()
                        try db.run("INSERT INTO pages(id, parent_id, database_id, sort_key, title, created_at, updated_at) VALUES(?,?,?,?,?,1,1)",
                                   [SQLValue(id), SQLValue(d.pageID), SQLValue(d.id), .text(String(format: "k%05d", i)), .text("Запись \(i)")])
                        try db.run("INSERT INTO property_values(page_id, property_id, value_date, updated_at) VALUES(?,?,?,1)",
                                   [SQLValue(id), SQLValue(date.id), .text(String(format: "2026-%02d-%02d", i % 12 + 1, i % 28 + 1))])
                        try db.run("INSERT INTO property_value_options(page_id, property_id, option_id) VALUES(?,?,?)",
                                   [SQLValue(id), SQLValue(status.id), SQLValue(status.options[i % 3].id)])
                    }
                }
            }
            var state = DatabaseViewState()
            state.filter.items = [.rule(FilterRule(property: status.id, op: .equals, value: status.options[1].id.uuidString)),
                                  .rule(FilterRule(property: title.id, op: .contains, value: "запись 1"))]
            state.sorts = [SortRule(property: date.id, descending: true)]
            let start = Date()
            let page = try await w.queryRecords(database: d, state: state, limit: 100, offset: 0)
            let ms = Date().timeIntervalSince(start) * 1000
            check(page.total > 100)
            checkEqual(page.rows.count, 100)
            print("  запрос 5000 записей: \(Int(ms)) мс (не приёмочный замер, -Onone)")
        }
    }
}
