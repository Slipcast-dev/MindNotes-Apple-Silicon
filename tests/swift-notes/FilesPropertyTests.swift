import Foundation

/// M10.2: свойство «Файлы и медиа».
func runFilesPropertyTests() async {
    await test("Файлы и медиа: порядок, проверки, фильтр «пусто», сортировка, копия базы, вложение защищено") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "Фото", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["Новая"], dateProperty: "Срок", viewName: "Таблица"), ids: RandomIDs(), now: 1)
            func file(_ name: String, _ bytes: [UInt8]) async throws -> AttachedFile {
                let url = dir.appendingPathComponent(name)
                try Data(bytes).write(to: url)
                let record = try await w.addAsset(copying: url, now: 2)
                return AttachedFile(id: record.id, name: record.originalName)
            }
            let photo = try await file("снимок.png", [0x89, 0x50]), doc = try await file("отчёт.pdf", [0x25, 0x50])
            check(photo.isImage && !doc.isImage, "картинка по расширению")
            let prop = UUID(), a = UUID(), b = UUID()
            try await w.addProperty(database: d.id, name: "Вложения", type: .files, id: prop, now: 3)
            try await w.createRecord(database: d.id, title: "С файлами", id: a, now: 3)
            try await w.createRecord(database: d.id, title: "Пустая", id: b, now: 3)
            try await w.setValue(pages: [a], property: prop, value: .files([doc, photo]), now: 4)
            let fresh = try await w.database(d.id)!
            checkEqual(try await w.recordValues(page: a, database: fresh)[prop], .files([doc, photo]), "порядок ячейки и имена")
            await checkThrows("файла нет в хранилище") { try await w.setValue(pages: [b], property: prop, value: .files([AttachedFile(id: UUID(), name: "x")]), now: 5) }
            await checkThrows("повтор") { try await w.setValue(pages: [b], property: prop, value: .files([doc, doc]), now: 5) }
            checkEqual(PropertyConversion.text(of: .files([doc, photo]), options: []), "отчёт.pdf, снимок.png", "CSV — имена")

            func titles(_ op: FilterOp?, sort: Bool = false) async throws -> [String] {
                var state = DatabaseViewState()
                if let op { state.filter.items = [.rule(FilterRule(property: prop, op: op, value: ""))] }
                if sort { state.sorts = [SortRule(property: prop, descending: true)] }
                return try await w.queryRecords(database: fresh, state: state, limit: 10, offset: 0).rows.map(\.title)
            }
            checkEqual(try await titles(.isEmpty), ["Пустая"])
            checkEqual(try await titles(.isNotEmpty), ["С файлами"])
            checkEqual(try await titles(nil, sort: true), ["С файлами", "Пустая"], "по числу файлов, пустые в конце")
            checkEqual(try await w.valueCount(property: prop), 1)

            await checkThrows("используемое вложение не удаляется") { try await w.deleteAsset(doc.id) }
            let copyPage = try await w.duplicatePage(d.pageID, title: "Копия", ids: RandomIDs(), now: 6)
            let copy = try await w.database(try await w.databaseIndex()[copyPage]!)!
            let copyProp = copy.properties.first { $0.type == .files }!
            let rows = try await w.queryRecords(database: copy, state: DatabaseViewState(), limit: 5, offset: 0).rows
            checkEqual(rows.first { $0.title == "С файлами" }?.values[copyProp.id], .files([doc, photo]), "копия ссылается на те же файлы")
        }
    }

    await test("Файлы и медиа: экспорт пространства копирует файлы, карточка ссылается на них, запись без текста тоже выгружается") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let d = try await w.createDatabase(parent: nil, template: NewDatabase(title: "Фото", titleProperty: "Название", statusProperty: "Статус",
                                                                                 statusOptions: ["Новая"], dateProperty: "Срок", viewName: "Таблица"), ids: RandomIDs(), now: 1)
            let src = dir.appendingPathComponent("снимок.png")
            try Data([1, 2, 3]).write(to: src)
            let asset = try await w.addAsset(copying: src, now: 2)
            let prop = UUID(), record = UUID()
            try await w.addProperty(database: d.id, name: "Вложения", type: .files, id: prop, now: 3)
            try await w.createRecord(database: d.id, title: "Кадр", id: record, now: 3)
            try await w.setValue(pages: [record], property: prop, value: .files([AttachedFile(id: asset.id, name: asset.originalName)]), now: 4)
            let out = dir.appendingPathComponent("out")
            let summary = try await WorkspaceExport.exportAll(source: w, to: out, untitled: "Без названия")
            let md = try String(contentsOf: out.appendingPathComponent("Фото/Кадр.md"), encoding: .utf8)
            check(md.contains("Вложения: [снимок.png](<Кадр_files/properties/снимок.png>)"), md)
            checkEqual(try Data(contentsOf: out.appendingPathComponent("Фото/Кадр_files/properties/снимок.png")), Data([1, 2, 3]))
            checkEqual(summary.assets, 1)
            let csv = try String(contentsOf: out.appendingPathComponent("Фото.csv"), encoding: .utf8)
            check(csv.contains("снимок.png"), "в CSV — имя файла")
        }
    }
}
