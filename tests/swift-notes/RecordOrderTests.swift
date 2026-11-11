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
