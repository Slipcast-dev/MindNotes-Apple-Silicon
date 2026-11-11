import Foundation

/// M10.3: ручной порядок записей у каждого представления.
func runRecordOrderTests() async {
    await test("Ручной порядок: перенос, у каждого вида свой, сортировка его отключает, новые — в конце, копия базы") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["Новая"], dateProperty: "Срок", viewName: "Таблица",
                                                                                 extraViews: [("Доска", DatabaseView.boardKind)]), ids: RandomIDs(), now: 1)
            var ids: [String: UUID] = [:]
            for (i, title) in ["А", "Б", "В", "Г"].enumerated() {
                let id = UUID()
                ids[title] = id
                try await w.createRecord(database: d.id, title: title, id: id, now: Int64(2 + i))
            }
            let fresh = try await w.database(d.id)!
            let table = fresh.views[0].id, board = fresh.views[1].id
            func order(_ view: UUID?, _ state: DatabaseViewState = DatabaseViewState()) async throws -> [String] {
                try await w.queryRecords(database: fresh, state: state, limit: 50, offset: 0, manualView: view).rows.map(\.title)
            }
            checkEqual(try await order(table), ["А", "Б", "В", "Г"], "до переноса — порядок добавления")
            try await w.moveRecord(ids["В"]!, before: ids["А"]!, view: table)
            checkEqual(try await order(table), ["В", "А", "Б", "Г"])
            try await w.moveRecord(ids["В"]!, before: nil, view: table)
            checkEqual(try await order(table), ["А", "Б", "Г", "В"], "в конец")
            try await w.moveRecord(ids["Г"]!, before: ids["Б"]!, view: table)
            checkEqual(try await order(table), ["А", "Г", "Б", "В"])
            checkEqual(try await order(board), ["А", "Б", "В", "Г"], "у другого вида свой порядок")

            var sorted = DatabaseViewState()
            sorted.sorts = [SortRule(property: fresh.titleProperty!.id, descending: true)]
            checkEqual(try await order(table, sorted), ["Г", "В", "Б", "А"], "сортировка важнее ручного порядка")

            let late = UUID()
            try await w.createRecord(database: d.id, title: "Д", id: late, now: 10)
            checkEqual(try await order(table), ["А", "Г", "Б", "В", "Д"], "новая запись — в конце")
            try await w.moveRecord(late, before: ids["А"]!, view: table)
            checkEqual(try await order(table), ["Д", "А", "Г", "Б", "В"], "запись без места тоже переносится")
            try await w.trashRecords([ids["А"]!], ids: RandomIDs(), now: 11)
            checkEqual(try await order(table), ["Д", "Г", "Б", "В"], "запись в корзине не мешает")
            try await w.moveRecord(ids["В"]!, before: ids["Г"]!, view: table)
            checkEqual(try await order(table), ["Д", "В", "Г", "Б"])

            await checkThrows("встроенное или чужое представление") { try await w.moveRecord(ids["Б"]!, before: nil, view: UUID()) }
            await checkThrows("запись из корзины") { try await w.moveRecord(ids["А"]!, before: nil, view: table) }

            let copyPage = try await w.duplicatePage(d.pageID, title: "Копия", ids: RandomIDs(), now: 12)
            let copy = try await w.database(try await w.databaseIndex()[copyPage]!)!
            let copyTable = copy.views.first { $0.kind == DatabaseView.tableKind }!.id
            checkEqual(try await w.queryRecords(database: copy, state: DatabaseViewState(), limit: 50, offset: 0, manualView: copyTable).rows.map(\.title),
                       ["Д", "В", "Г", "Б"], "копия базы сохраняет ручной порядок")
        }
    }

    await test("Ручной порядок: первый перенос в базе на 5000 записей — быстро") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.importDatabase(parent: nil, title: "Много", viewName: "Таблица",
                                               properties: [PropertyDefinition(id: UUID(), databaseID: UUID(), name: "Название", type: .title, sortKey: "")],
                                               records: (0..<5000).map { ImportedRecord(id: UUID(), title: "Запись \($0)", values: [:]) }, now: 1)
            let rows = try await w.queryRecords(database: d, state: DatabaseViewState(), limit: 5000, offset: 0, manualView: d.views[0].id).rows
            let started = Date()
            try await w.moveRecord(rows.last!.id, before: rows.first!.id, view: d.views[0].id)
            let first = Date().timeIntervalSince(started)
            let again = Date()
            try await w.moveRecord(rows[100].id, before: rows[5].id, view: d.views[0].id)
            let second = Date().timeIntervalSince(again)
            check(first < 3 && second < 1, "первый \(first) с, следующий \(second) с")
            print("  первый перенос: \(String(format: "%.3f", first)) с, следующий: \(String(format: "%.3f", second)) с")
            let after = try await w.queryRecords(database: d, state: DatabaseViewState(), limit: 3, offset: 0, manualView: d.views[0].id).rows.map(\.id)
            checkEqual(after.first, rows.last!.id)
        }
    }
}

/// M10.4: ширина столбцов в состоянии представления.
func runColumnWidthTests() async {
    await test("Ширина столбцов: пределы, старое состояние без ширины, сохранение в виде, копия базы") {
        checkEqual(ColumnState.clamp(10), 60)
        checkEqual(ColumnState.clamp(5000), 800)
        checkEqual(ColumnState.clamp(201.6), 202)
        check(ColumnState.clamp(.nan) == nil && ColumnState.clamp(.infinity) == nil, "нечисло не сохраняется")
        let p = UUID(), q = UUID()
        let old = DatabaseViewState(json: #"{"columns":[{"property":"\#(p.uuidString)","visible":false}]}"#)
        checkEqual(old.columns.first?.visible, false, "старое состояние читается")
        checkEqual(old.columnWidth(p), nil)
        let props = [PropertyDefinition(id: p, databaseID: UUID(), name: "A", type: .title, sortKey: "a"),
                     PropertyDefinition(id: q, databaseID: UUID(), name: "B", type: .text, sortKey: "b")]
        var state = old
        state.setColumnWidth(q, 333, properties: props)
        checkEqual(state.columnWidth(q), 333, "столбец без записи в списке получает ширину")
        checkEqual(state.columns.map(\.property), [p, q])
        let back = DatabaseViewState(json: try state.jsonString())
        checkEqual(back.columnWidth(q), 333, "ширина переживает JSON")
        state.setColumnWidth(q, nil, properties: props)
        checkEqual(state.columnWidth(q), nil, "сброс к ширине по типу")

        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "База", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["Новая"], dateProperty: "Срок", viewName: "Таблица"), ids: RandomIDs(), now: 1)
            var s = d.views[0].state
            let status = d.properties.first { $0.type == .status }!
            s.setColumnWidth(status.id, 420, properties: d.properties)
            try await w.saveViewState(d.views[0].id, s)
            checkEqual(try await w.database(d.id)!.views[0].state.columnWidth(status.id), 420)
            let copyPage = try await w.duplicatePage(d.pageID, title: "Копия", ids: RandomIDs(), now: 2)
            let copy = try await w.database(try await w.databaseIndex()[copyPage]!)!
            let copyStatus = copy.properties.first { $0.type == .status }!
            checkEqual(copy.views[0].state.columnWidth(copyStatus.id), 420, "копия базы — та же ширина у своего свойства")
        }
    }
}

/// M10.5: отмена возвращает каждой записи её значение одной транзакцией.
func runUndoStoreTests() async {
    await test("Отмена в базе: setValues пишет разные значения разом, неверное значение не пишет ничего") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "База", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["Новая", "Готово"], dateProperty: "Срок", viewName: "Таблица"), ids: RandomIDs(), now: 1)
            let a = UUID(), b = UUID(), note = UUID()
            try await w.addProperty(database: d.id, name: "Заметка", type: .text, id: note, now: 1)
            try await w.createRecord(database: d.id, title: "А", id: a, now: 2)
            try await w.createRecord(database: d.id, title: "Б", id: b, now: 2)
            try await w.setValues(property: note, [(a, .text("первая")), (b, nil)], now: 3)
            let fresh = try await w.database(d.id)!
            checkEqual(try await w.recordValues(page: a, database: fresh)[note], .text("первая"))
            checkEqual(try await w.recordValues(page: b, database: fresh)[note], nil)
            await checkThrows("неверный тип во второй записи") { try await w.setValues(property: note, [(a, .text("вторая")), (b, .number(1))], now: 4) }
            checkEqual(try await w.recordValues(page: a, database: fresh)[note], .text("первая"), "транзакция целиком откатилась")
        }
    }
}
