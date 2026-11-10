import Foundation

func runExportTests() async {
    await test("CSV: кавычки, переносы, разделители, метка порядка байтов, круговой проход") {
        let rows = [["Название", "Заметка"], ["а, б", "строка 1\nстрока 2"], ["кавычки \"вот\"", ""], [" пробел", "ё;ж"]]
        for delimiter in CSV.delimiters {
            checkEqual(CSV.parse(CSV.write(rows, delimiter: delimiter), delimiter: delimiter), rows, "разделитель \(delimiter.unicodeScalars.first!.value)")
        }
        checkEqual(CSV.parse("\u{FEFF}a,b\r\n1,2\r\n\r\n3,4"), [["a", "b"], ["1", "2"], ["3", "4"]], "BOM, CRLF и пустая строка")
        checkEqual(CSV.parse("a,\"\"\n"), [["a", ""]], "пустое поле в кавычках")
        checkEqual(CSV.parse("a,b\n1,"), [["a", "b"], ["1", ""]], "пустое последнее поле")
        checkEqual(CSV.parse("x\"y,z"), [["x\"y", "z"]], "кавычка в середине — обычный символ")
        checkEqual(CSV.parse(""), [])
        check(CSV.detectDelimiter("a;b;c\n1;2;3\n") == ";")
        check(CSV.detectDelimiter("a\tb\n1\t2\n") == "\t")
        check(CSV.detectDelimiter("имя,значение\n\"а;б\",2\n") == ",")
        check(CSV.detectDelimiter("один столбец\n") == ",")
    }

    await test("Экспорт пространства: дерево, одинаковые имена, база с записями, вложения, существующая папка") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            func page(_ title: String, parent: UUID? = nil, text: String? = nil) async throws -> UUID {
                let id = UUID()
                _ = try await ws.createPage(parent: parent, title: title, id: id, now: 1)
                if let text {
                    var batch = SaveBatch()
                    let block = Block(id: UUID(), pageID: id, sortKey: "a0", content: BlockContent(text: text), createdAt: 1)
                    batch.upserts[block.id] = block
                    try await ws.commit(batch)
                }
                return id
            }
            let projects = try await page("Проекты", text: "Обзор")
            let plan = try await page("План: A/B", parent: projects, text: "Шаги")
            _ = try await page("Заметка", text: "первая")
            _ = try await page("заметка", text: "вторая")
            _ = try await page("", text: "без названия")
            var folder = try await ws.page(try await page("Папка"))!
            folder.icon = Page.folderIcon
            try await ws.updatePage(folder)
            _ = try await page("Внутри", parent: folder.id, text: "текст")

            let file = dir.appendingPathComponent("фото.png")
            try Data("png".utf8).write(to: file)
            let asset = try await ws.addAsset(copying: file, now: 1)
            let fragment = AtomData.attachment(type: .image, asset: asset)
            var batch = SaveBatch()
            let image = Block(id: UUID(), pageID: plan, parentID: nil, sortKey: "a1", type: .image, contentVersion: 1,
                              contentJSON: fragment.json, plainText: fragment.plain, createdAt: 1, updatedAt: 1)
            batch.upserts[image.id] = image
            try await ws.commit(batch)

            let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                                       statusOptions: ["Запланировано", "Готово"], dateProperty: "Срок", viewName: "Таблица")
            let database = try await ws.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
            let status = database.properties.first { $0.type == .status }!, date = database.properties.first { $0.type == .date }!
            let first = UUID(), second = UUID()
            try await ws.createRecord(database: database.id, title: "Первая, с запятой", id: first, now: 2)
            try await ws.createRecord(database: database.id, title: "Вторая", id: second, now: 3)
            try await ws.setValue(pages: [first], property: status.id, value: .options([status.options[1].id]), now: 4)
            try await ws.setValue(pages: [first], property: date.id, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 3, day: 8)!))), now: 4)
            var note = SaveBatch()
            let recordBlock = Block(id: UUID(), pageID: second, sortKey: "a0", content: BlockContent(text: "Описание записи"), createdAt: 1)
            note.upserts[recordBlock.id] = recordBlock
            try await ws.commit(note)

            let root = dir.appendingPathComponent("out")
            let summary = try await WorkspaceExport.exportAll(source: ws, to: root, untitled: "Без названия")
            let fm = FileManager.default
            func exists(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }
            func text(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }

            check(exists("Проекты.md") && exists("Проекты/План_ A_B.md"), "подстраница в папке родителя, опасные символы заменены")
            check(text("Проекты/План_ A_B.md").contains("![фото.png](<План_ A_B_files/фото.png>)"), "ссылка на вложение")
            checkEqual(try Data(contentsOf: root.appendingPathComponent("Проекты/План_ A_B_files/фото.png")), Data("png".utf8), "вложение скопировано")
            check(exists("Заметка.md") && exists("заметка 2.md"), "одинаковые имена без учёта регистра различаются")
            check(exists("Без названия.md"))
            check(!exists("Папка.md") && exists("Папка/Внутри.md"), "пустая папка — только каталог")
            let csv = CSV.parse(text("Задачи.csv"))
            checkEqual(csv, [["Название", "Статус", "Срок"], ["Первая, с запятой", "Готово", "2026-03-08"], ["Вторая", "", ""]], "таблица базы")
            let csvData = try Data(contentsOf: root.appendingPathComponent("Задачи.csv"))
            check(csvData.starts(with: [0xEF, 0xBB, 0xBF]), "метка порядка байтов для Excel")
            check(exists("Задачи/Вторая.md") && !exists("Задачи/Первая, с запятой.md"), "страница записи пишется, только если в ней есть текст")
            check(!exists("Вторая.md"), "записи нет в дереве страниц")
            checkEqual(summary.databases, 1)
            checkEqual(summary.records, 2)
            checkEqual(summary.assets, 1)
            checkEqual(summary.pages, 6)

            await checkThrows("существующая папка не перезаписывается") { try await WorkspaceExport.exportAll(source: ws, to: root, untitled: "x") }
            check(text("Заметка.md").contains("первая"), "прежний экспорт не тронут")
        }
    }
}
