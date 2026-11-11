import Foundation

/// M9.5: связи в Markdown-карточке записи и импорт связей из экспорта Notion.
func runRelationTransferTests() async {
    await test("Связи Notion: разбор ячейки, ID, столбец целиком из ссылок") {
        let h = String(repeating: "a", count: 32)
        checkEqual(NotionRelations.references("Купить (Задачи%20x/Купить%20\(h).md), Отчёт, итоги (Задачи%20x/Отчёт%20\(h).md)"),
                   [.init(title: "Купить", target: "Задачи%20x/Купить%20\(h).md"), .init(title: "Отчёт, итоги", target: "Задачи%20x/Отчёт%20\(h).md")],
                   "запятая в заголовке не режет ссылку")
        checkEqual(NotionRelations.references("Сайт (https://www.notion.so/Sajt-\(h)?pvs=21)")?.first?.title, "Сайт", "адрес notion.so с ID")
        checkEqual(NotionRelations.references("Задача (с пометкой) (x/Задача%20\(h).md)")?.first?.title, "Задача (с пометкой)", "скобки в заголовке")
        check(NotionRelations.references("Просто текст (заметка)") == nil, "скобки без пути — не связь")
        check(NotionRelations.references("A (a.md) и ещё") == nil, "хвост после ссылки — не связь")
        checkEqual(NotionRelations.references("  "), [])
        check(NotionRelations.references(" (a.md)") == nil, "без заголовка — не связь")
        let hostile = "A (" + String(repeating: "), ", count: 60_000) + "x"
        let started = Date()
        check(NotionRelations.references(hostile) == nil && NotionRelations.references(String(repeating: "x (", count: 60_000)) == nil)
        check(Date().timeIntervalSince(started) < 1, "длинная враждебная ячейка разбирается за линейное время")
        check(NotionRelations.references(String(repeating: "a", count: NotionRelations.maxCell + 1) + " (a.md)") == nil, "предел длины")
        checkEqual(NotionRelations.id(in: "x/Купить%20\(h.uppercased()).md"), h)
        check(NotionRelations.isRelationColumn(["", "A (a.md)"]))
        check(!NotionRelations.isRelationColumn(["", ""]), "пустой столбец — не связь")
        check(!NotionRelations.isRelationColumn(["A (a.md)", "просто"]), "одна обычная ячейка — весь столбец текст")
        let card = [BlockFragment(type: .paragraph, content: BlockContent(text: "Статус: Done\nПроект: X")),
                    BlockFragment(type: .paragraph, content: BlockContent(text: "Цена: 5")),
                    BlockFragment(type: .paragraph, content: BlockContent(text: "Статус: на самом деле текст\nи вторая строка"))]
        checkEqual(NotionRelations.dropPropertyCard(card, names: ["статус", "проект", "цена"]).map(\.plain), ["Статус: на самом деле текст\nи вторая строка"],
                   "снимаются только ведущие абзацы из строк свойств")
        checkEqual(NotionRelations.dropPropertyCard(card, names: []).count, 3)
    }

    await test("Импорт Notion: двусторонняя связь из двух столбцов, односторонняя, ссылки не из архива, карточка свойств снята") {
        try await withTempDir { dir in
            let fm = FileManager.default
            let src = dir.appendingPathComponent("Export")
            func hex(_ c: Character) -> String { String(repeating: c, count: 32) }
            func put(_ path: String, _ text: String) throws {
                let url = src.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            let p = hex("1"), t = hex("2"), alpha = hex("a"), beta = hex("b"), buy = hex("c"), call = hex("d"), report = hex("e"), ghost = hex("f")
            func taskRef(_ title: String, _ id: String) -> String { "\(title) (Задачи%20\(t)/\(title.replacingOccurrences(of: " ", with: "%20"))%20\(id).md)" }
            func projectRef(_ title: String, _ id: String) -> String { "\(title) (../Проекты%20\(p)/\(title)%20\(id).md)" }
            // Проекты лежат рядом с задачами; связь записана с обеих сторон, как выгружает Notion.
            try put("Проекты \(p)_all.csv", """
            Name,Задачи,Ссылка
            Альфа,"\(taskRef("Купить молоко", buy)), \(taskRef("Позвонить", call))",https://example.com
            Бета,"\(taskRef("Отчёт", report))",
            Гамма,,
            """)
            try put("Задачи \(t)_all.csv", """
            Name,Проект,Похожие,Внешнее
            Купить молоко,"\(projectRef("Альфа", alpha))","Позвонить (Позвонить%20\(call).md)",Чужое (https://www.notion.so/x-\(ghost))
            Позвонить,"\(projectRef("Альфа", alpha))",,
            Отчёт,"\(projectRef("Бета", beta))","Купить молоко (Купить%20молоко%20\(buy).md), Удалённая (Удалённая%20\(ghost).md)",
            """)
            try put("Проекты \(p)/Альфа \(alpha).md", "# Альфа\n\nЗадачи: \(taskRef("Купить молоко", buy))\nСсылка: https://example.com\n\nТекст проекта\n")
            try put("Проекты \(p)/Бета \(beta).md", "# Бета\n")
            try put("Задачи \(t)/Купить молоко \(buy).md", "# Купить молоко\n\nПроект: Альфа\n\nОписание\n")
            try put("Задачи \(t)/Позвонить \(call).md", "# Позвонить\n")
            try put("Задачи \(t)/Отчёт \(report).md", "# Отчёт\n")

            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let (_, rep) = try await FolderImport.run(try FolderImport.scan(src), into: ws, title: "Импорт", untitled: "Без названия", viewName: "Таблица", zone: "UTC", now: 10)
            checkEqual(rep.databases, 2)
            checkEqual(rep.relations, 2, "пара «Задачи/Проект» и односторонние «Похожие»")
            checkEqual(rep.textRelations, 1, "«Внешнее» указывает не в архив: остаётся текстом")
            checkEqual(rep.unresolvedRelationLinks, 1, "удалённая запись не найдена")

            let pages = try await ws.allPages()
            let index = try await ws.databaseIndex()
            func database(_ title: String) async throws -> Database {
                let page = pages.first { $0.title == title && $0.databaseID == nil }!
                return try await ws.database(index[page.id]!)!
            }
            let projects = try await database("Проекты"), tasks = try await database("Задачи")
            let forward = projects.properties.first { $0.name == "Задачи" }!, back = tasks.properties.first { $0.name == "Проект" }!
            checkEqual(forward.type, .relation)
            checkEqual(back.type, .relation)
            checkEqual(forward.config.pair, back.id, "две колонки Notion стали одной двусторонней связью")
            checkEqual(back.config.pair, forward.id)
            checkEqual([forward.config.isBackSide, back.config.isBackSide].filter { $0 }.count, 1, "ровно одна сторона обратная")
            checkEqual(tasks.properties.first { $0.name == "Похожие" }?.config.target, tasks.id, "связь базы с собой")
            checkEqual(tasks.properties.first { $0.name == "Похожие" }?.config.pair, nil)
            checkEqual(tasks.properties.first { $0.name == "Внешнее" }?.type, .text)
            checkEqual(projects.properties.map(\.name), ["Name", "Задачи", "Ссылка"], "порядок свойств сохранён")

            func row(_ d: Database, _ title: String) async throws -> RecordRow {
                try await ws.queryRecords(database: d, state: DatabaseViewState(), limit: 10, offset: 0).rows.first { $0.title == title }!
            }
            func titles(_ value: PropertyValue?) -> [String] { if case .relation(let l)? = value { return l.map(\.title) }; return [] }
            checkEqual(titles(try await row(projects, "Альфа").values[forward.id]), ["Купить молоко", "Позвонить"], "порядок ячейки")
            checkEqual(titles(try await row(tasks, "Отчёт").values[back.id]), ["Бета"], "обратная сторона")
            checkEqual(titles(try await row(tasks, "Отчёт").values[tasks.properties.first { $0.name == "Похожие" }!.id]), ["Купить молоко"])
            checkEqual(try await row(projects, "Гамма").values[forward.id] ?? .relation([]), .relation([]))

            let alphaPage = pages.first { $0.title == "Альфа" && $0.databaseID != nil }!
            checkEqual(try await ws.blocks(ofPage: alphaPage.id).map(\.plainText), ["Текст проекта"], "строки свойств Notion не попали в текст")
            let buyPage = pages.first { $0.title == "Купить молоко" && $0.databaseID != nil }!
            checkEqual(try await ws.blocks(ofPage: buyPage.id).map(\.plainText), ["Описание"])
        }
    }

    await test("Markdown-экспорт записи: карточка свойств, связи ссылками [[…]], обратный импорт её снимает") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус", statusOptions: ["Новая", "Готово"],
                                       dateProperty: "Срок", viewName: "Таблица")
            let tasks = try await ws.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
            var projectTemplate = template
            projectTemplate.title = "Проекты"
            let projects = try await ws.createDatabase(parent: nil, template: projectTemplate, ids: RandomIDs(), now: 1)
            let relation = UUID()
            try await ws.addRelation(database: tasks.id, name: "Проект", target: projects.id, twoWay: true, pairName: "Задачи", id: relation, pairID: UUID(), now: 1)
            let note = UUID()
            try await ws.addProperty(database: tasks.id, name: "Заметка", type: .text, id: note, now: 1)
            let alpha = UUID(), beta = UUID(), task = UUID()
            try await ws.createRecord(database: projects.id, title: "Альфа", id: alpha, now: 2)
            try await ws.createRecord(database: projects.id, title: "Бета [2]", id: beta, now: 2)
            try await ws.createRecord(database: tasks.id, title: "Купить", id: task, now: 2)
            try await ws.setValue(pages: [task], property: relation, value: .relation([LinkedPage(id: alpha, title: ""), LinkedPage(id: beta, title: "")]), now: 3)
            try await ws.setValue(pages: [task], property: note, value: .text("две\nстроки *важно*"), now: 3)

            let fresh = try await ws.database(tasks.id)!
            let card = MarkdownExport.propertyCard(fresh, values: try await ws.recordValues(page: task, database: fresh), untitled: "Без названия")
            checkEqual(card, ["Проект: [[Альфа]], [[Бета [2]]]", "Заметка: две строки \\*важно\\*"], "пустые свойства пропущены, текст экранирован")
            let markdown = MarkdownExport.export(title: "Купить", card: card, blocks: [], assetFolder: "f") { _ in nil }.markdown
            checkEqual(markdown, "# Купить\n\nПроект: [[Альфа]], [[Бета [2]]]\n\nЗаметка: две строки \\*важно\\*\n")
            let back = MarkdownImport.fragments(from: markdown).dropFirst()
            checkEqual(NotionRelations.dropPropertyCard(Array(back), names: Set(fresh.properties.map { SearchText.normalize($0.name) })).count, 0,
                       "при импорте нашего экспорта карточка не дублируется в текст")

            // Экспорт всего пространства: карточка у записи с текстом.
            var batch = SaveBatch()
            let block = Block(id: UUID(), pageID: task, sortKey: "a0", content: BlockContent(runs: [TextRun("Описание")]), createdAt: 4)
            batch.upserts[block.id] = block
            batch.touchedPages = [task]
            try await ws.commit(batch)
            let out = dir.appendingPathComponent("out")
            _ = try await WorkspaceExport.exportAll(source: ws, to: out, untitled: "Без названия")
            let file = try String(contentsOf: out.appendingPathComponent("Задачи/Купить.md"), encoding: .utf8)
            check(file.hasPrefix("# Купить\n\nПроект: [[Альфа]], [[Бета [2]]]\n"), "карточка в экспорте папки: \(file)")
            check(file.contains("Описание"))
        }
    }
}
