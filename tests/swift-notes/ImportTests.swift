import CryptoKit
import Foundation

private func sha(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private func content(_ fragment: BlockFragment) -> BlockContent? { fragment.content }

func runFolderImportTests() async {
    await test("Импорт Markdown: ссылки, [[…]], экранирование, таблица, картинка, опасные ссылки") {
        let text = """
        Текст \\*не курсив\\* и [сайт](https://example.com), [почта](mailto:a@b.ru), [опасно](javascript:alert(1)), [[Другая]]
        | Имя | Значение |
        | --- | :-: |
        | а \\| б | 2 |
        ![схема](<папка/схема 1.png>)
        ![нет файла](нет.png)
        """
        var images: [String] = []
        let fragments = MarkdownImport.fragments(from: text, image: { alt, path in
            images.append(path)
            return path == "папка/схема 1.png" ? BlockFragment(type: BlockType.image.rawValue, contentVersion: 1, json: "{}", plain: alt) : nil
        }, link: { href in
            href == "wiki:Другая" ? "a:notes://page/x" : MarkdownImport.safeLink(href)
        })
        let runs = content(fragments[0])?.runs ?? []
        checkEqual(RichText.plain(runs), "Текст *не курсив* и сайт, почта, опасно, Другая", "экранирование снято, подписи ссылок сохранены")
        check(runs.contains { $0.text == "сайт" && $0.marks == ["a:https://example.com"] })
        check(runs.contains { $0.text == "почта" && $0.marks == ["a:mailto:a@b.ru"] })
        check(!runs.flatMap(\.marks).contains { $0.contains("javascript") }, "javascript: убран")
        check(runs.contains { $0.text == "Другая" && $0.marks == ["a:notes://page/x"] })
        checkEqual(fragments[1].type, BlockType.table.rawValue)
        checkEqual(AtomData.rows(of: Block(id: UUID(), pageID: UUID(), parentID: nil, sortKey: "a", type: .table, contentVersion: 1,
                                           contentJSON: fragments[1].json, plainText: "", createdAt: 1, updatedAt: 1)),
                   [["Имя", "Значение"], ["а | б", "2"]], "строка-разделитель пропущена, экранированная черта — текст")
        checkEqual(fragments[2].type, BlockType.image.rawValue)
        checkEqual(images, ["папка/схема 1.png", "нет.png"])
        checkEqual(fragments.last?.plain, "нет файла", "картинка без файла остаётся подписью")
        checkEqual(MarkdownImport.imageReferences(text), ["папка/схема 1.png", "нет.png"])
    }

    await test("Импорт Markdown: наш экспорт читается обратно без потерь форматирования") {
        let page = UUID()
        let source = [
            Block(id: UUID(), pageID: page, sortKey: "a0", content: BlockContent(runs: [TextRun("жирный", marks: ["b"]), TextRun(" 2*3 [x] #тег")]), createdAt: 1),
            Block(id: UUID(), pageID: page, sortKey: "a1", type: .task, content: BlockContent(runs: [TextRun("дело")], checked: true), createdAt: 1),
        ]
        let markdown = MarkdownExport.export(title: "Т", blocks: source, assetFolder: "f") { _ in nil }.markdown
        let back = MarkdownImport.fragments(from: markdown).dropFirst()
        checkEqual(back.map(\.plain), ["жирный 2*3 [x] #тег", "дело"])
        checkEqual(back.first.flatMap(content)?.runs.first?.marks, ["b"])
        checkEqual(back.last.flatMap(content)?.checked, true)
    }

    await test("Импорт CSV: угадывание типов, заголовки, варианты, несовместимые значения, запись базы") {
        let table = CSV.parse("""
        Название;Сумма;Готово;Срок;Статус;Метки;Ссылка;Заметка
        Первая;1 200,50;да;2026-03-08;В работе;a, b;https://example.com;текст
        Вторая;7;нет;08.03.2026;Готово;b;https://ya.ru;ещё
        Третья;;нет;;В работе;a;;
        Четвёртая;5;да;2026-03-09;Готово;c;;длинный текст без повторов
        """, delimiter: ";")
        let zone = "Europe/Moscow"
        var plan = CSVImport.plan(table, hasHeader: true, zone: zone)
        checkEqual(plan.types, [.title, .number, .checkbox, .date, .select, .multiSelect, .url, .text])
        checkEqual(plan.rows.count, 4)
        plan.types[7] = .number // пользователь сменил тип: текст не подойдёт и сохранится как есть
        let built = CSVImport.build(plan, zone: zone, ids: RandomIDs())
        checkEqual(built.unconverted, 3)
        checkEqual(built.properties[4].options.map(\.name), ["В работе", "Готово"])
        checkEqual(built.properties[5].options.map(\.name), ["a", "b", "c"])

        let noHeader = CSVImport.plan([["x", "1"], ["y", "2"]], hasHeader: false, zone: zone)
        checkEqual(noHeader.headers, ["Столбец 1", "Столбец 2"])
        checkEqual(noHeader.rows.count, 2)
        checkEqual(CSVImport.plan([["Имя", "имя", ""]], hasHeader: true, zone: zone).headers, ["Имя", "имя 2", "Столбец 3"], "одинаковые и пустые заголовки")

        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let database = try await ws.importDatabase(parent: nil, title: "Импорт", viewName: "Таблица", properties: built.properties, records: built.records, now: 5)
            checkEqual(database.properties.map(\.name), plan.headers)
            let rows = try await ws.queryRecords(database: database, state: DatabaseViewState(), limit: 10, offset: 0)
            checkEqual(rows.total, 4)
            let first = rows.rows.first { $0.title == "Первая" }!
            func value(_ i: Int) -> PropertyValue? { first.values[database.properties[i].id] }
            checkEqual(value(1), .number(1200.5))
            checkEqual(value(2), .checkbox(true))
            checkEqual(value(3), .date(DateValue(start: .day(LocalDate(year: 2026, month: 3, day: 8)!))))
            checkEqual(value(7), .unconverted("текст"))
            if case .options(let ids)? = value(5) { checkEqual(ids.count, 2) } else { check(false, "множественный выбор") }
            let hits = try await ws.search("Четвёртая")
            check(hits.contains { $0.pageID == rows.rows.first { $0.title == "Четвёртая" }!.id }, "записи в поиске")
        }
    }

    await test("Импорт папки Notion: страницы, вложенность, база из _all, строки, картинки, ссылки, пропуски, оригиналы") {
        try await withTempDir { dir in
            let fm = FileManager.default
            let src = dir.appendingPathComponent("Export")
            let h1 = String(repeating: "a", count: 32), h2 = String(repeating: "b", count: 32), h3 = String(repeating: "c", count: 32)
            func put(_ path: String, _ text: String) throws {
                let url = src.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            try put("Проекты \(h1).md", """
            # Проекты

            См. [План](Проекты%20\(h1)/План%20\(h2).md) и [[Задачи]], [сайт](https://example.com), [опасно](javascript:x), [наружу](../../секрет.md)

            ![схема](Проекты%20\(h1)/схема.png)
            ![нет](Проекты%20\(h1)/нет.png)
            """)
            try put("Проекты \(h1)/План \(h2).md", "# План\n\nТекст **плана**\n")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: src.appendingPathComponent("Проекты \(h1)/схема.png"))
            try put("Задачи \(h3).csv", "Name,Status\nКупить молоко,Done\n")
            try put("Задачи \(h3)_all.csv", "Name,Status\nКупить молоко,Done\nПозвонить,Not started\nОтчёт,Done\n")
            try put("Задачи \(h3)/Купить молоко \(h1).md", "# Купить молоко\n\nОписание задачи\n")
            try put("Заметки/Идея.md", "Просто идея\n")
            try put("лишнее.bin", "x")
            try fm.createSymbolicLink(at: src.appendingPathComponent("ссылка.md"), withDestinationURL: src.appendingPathComponent("Заметки/Идея.md"))
            let originals = try fm.subpathsOfDirectory(atPath: src.path).sorted().map { "\($0)=\(sha(src.appendingPathComponent($0)))" }

            let plan = try FolderImport.scan(src)
            checkEqual(plan.markdown.count, 4)
            checkEqual(plan.csv.count, 2)
            check(plan.skipped.contains { $0.path == "ссылка.md" }, "символическая ссылка пропущена")
            checkEqual(try FolderImport.scan(src).fingerprint, plan.fingerprint, "отпечаток стабилен")

            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let (root, report) = try await FolderImport.run(plan, into: ws, title: "Импорт — Export", untitled: "Без названия", viewName: "Таблица", zone: "UTC", now: 10)
            let pages = try await ws.allPages()
            func page(_ title: String) -> Page? { pages.first { $0.title == title } }
            checkEqual(page("Импорт — Export")?.id, root)
            let projects = page("Проекты")!, plan2 = page("План")!, notes = page("Заметки")!
            checkEqual(projects.parentID, root)
            checkEqual(plan2.parentID, projects.id, "папка Notion становится детьми одноимённой страницы")
            check(notes.isFolder && page("Идея")?.parentID == notes.id, "папка без страницы — папка")
            checkEqual(report.databases, 1)
            checkEqual(report.records, 3, "взята полная таблица _all")
            check(report.skipped.contains { $0.path == "Задачи \(h3).csv" })
            let databasePage = page("Задачи")!
            let record = pages.first { $0.title == "Купить молоко" && $0.databaseID != nil }!
            checkEqual(try await ws.blocks(ofPage: record.id).map(\.plainText), ["Описание задачи"], "текст строки Notion достался записи")
            check(!pages.contains { $0.title == "Купить молоко" && $0.databaseID == nil }, "без лишней страницы-дубля")

            let blocks = try await ws.blocks(ofPage: projects.id)
            check(blocks.first?.type != .heading1, "повтор заголовка убран")
            let marks = blocks.compactMap(\.content).flatMap(\.runs).flatMap(\.marks)
            check(marks.contains(PageLink.mark(plan2.id)), "ссылка на файл стала ссылкой на страницу")
            check(marks.contains(PageLink.mark(databasePage.id)), "[[Задачи]] — ссылка на базу")
            check(marks.contains("a:https://example.com"))
            check(!marks.contains { $0.contains("javascript") || $0.contains("секрет") }, "опасные и внешние пути убраны")
            checkEqual(report.unresolvedLinks, 2)
            let image = blocks.first { $0.type == .image }
            check(image != nil && report.assets == 1, "картинка стала вложением")
            if let image, case .string(let raw)? = image.atomJSON["asset"], let asset = UUID(uuidString: raw) {
                let url = try await ws.assetURL(asset)
                checkEqual(try Data(contentsOf: url!), Data([0x89, 0x50, 0x4E, 0x47]))
            }
            checkEqual(report.missingImages, 1)
            checkEqual(report.unusedFiles, 1, "лишний файл не импортирован")
            checkEqual(try await ws.blocks(ofPage: plan2.id).first?.content?.runs.map(\.marks), [[], ["b"]])
            let after = try fm.subpathsOfDirectory(atPath: src.path).sorted().map { "\($0)=\(sha(src.appendingPathComponent($0)))" }
            checkEqual(after, originals, "оригиналы не изменены")
        }
    }

    await test("Импорт папки: пределы, отпечаток меняется вместе с содержимым") {
        try await withTempDir { dir in
            let src = dir.appendingPathComponent("s")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            for i in 0..<3 { try Data("т\(i)".utf8).write(to: src.appendingPathComponent("\(i).md")) }
            let before = try FolderImport.scan(src).fingerprint
            await checkThrows("слишком много файлов") { try FolderImport.scan(src, limits: FolderImport.Limits(maxFiles: 2)) }
            await checkThrows("слишком большой объём") { try FolderImport.scan(src, limits: FolderImport.Limits(maxTotalBytes: 4)) }
            try Data("другой".utf8).write(to: src.appendingPathComponent("0.md"))
            let changed = try FolderImport.scan(src).fingerprint
            check(changed != before)
            checkEqual(FolderImport.cleanTitle("Задачи \(String(repeating: "f", count: 32))_all.csv"), "Задачи")
            checkEqual(FolderImport.cleanTitle("Обычная.md"), "Обычная")
            checkEqual(FolderImport.relativePath(dir.appendingPathComponent("s/../s2/x"), base: src), nil, "соседняя папка с похожим именем не внутри")
        }
    }

    await test("Архив: распаковка, вложенные части, символическая ссылка отклоняется") {
        try await withTempDir { dir in
            let fm = FileManager.default
            func zip(_ folder: URL, _ out: URL) throws {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", folder.path, out.path]
                try p.run(); p.waitUntilExit()
            }
            let good = dir.appendingPathComponent("good")
            try fm.createDirectory(at: good.appendingPathComponent("Папка"), withIntermediateDirectories: true)
            try Data("текст".utf8).write(to: good.appendingPathComponent("Папка/Страница.md"))
            let part = dir.appendingPathComponent("part.zip")
            try zip(good, part)
            let outer = dir.appendingPathComponent("outer")
            try fm.createDirectory(at: outer, withIntermediateDirectories: true)
            try fm.copyItem(at: part, to: outer.appendingPathComponent("Export-Part-1.zip"))
            let archive = dir.appendingPathComponent("export.zip")
            try zip(outer, archive)
            let extracted = try ArchiveExtract.extract(archive, into: dir)
            checkEqual(try String(contentsOf: extracted.appendingPathComponent("Папка/Страница.md"), encoding: .utf8), "текст", "вложенная часть распакована")

            let bad = dir.appendingPathComponent("bad")
            try fm.createDirectory(at: bad, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: bad.appendingPathComponent("наружу").path, withDestinationPath: "/etc/hosts")
            let badZip = dir.appendingPathComponent("bad.zip")
            try zip(bad, badZip)
            let before = try fm.contentsOfDirectory(atPath: dir.path).count
            await checkThrows("ссылка в архиве") { try ArchiveExtract.extract(badZip, into: dir) }
            checkEqual(try fm.contentsOfDirectory(atPath: dir.path).count, before, "папка неудачной распаковки удалена")
            // Записи «../x» и «/abs» ditto кладёт внутрь целевой папки: проверено на этой системе и закреплено тестом.
            let slip = dir.appendingPathComponent("slip.zip")
            let absolute = "/tmp/mindnotes-abs-\(UUID().uuidString).md"
            try Data(storedZip([("ok.md", "ok"), ("../escaped.md", "e"), (absolute, "a")])).write(to: slip)
            let inside = try ArchiveExtract.extract(slip, into: dir)
            check(!fm.fileExists(atPath: dir.appendingPathComponent("escaped.md").path), "../ не вышел из папки распаковки")
            check(fm.fileExists(atPath: inside.appendingPathComponent("escaped.md").path), "запись ../ осталась внутри")
            check(!fm.fileExists(atPath: absolute), "абсолютный путь не записан в /tmp")
            check(fm.fileExists(atPath: inside.appendingPathComponent(String(absolute.dropFirst())).path), "абсолютный путь стал путём внутри")
            try Data("не архив".utf8).write(to: dir.appendingPathComponent("broken.zip"))
            await checkThrows("повреждённый архив") { try ArchiveExtract.extract(dir.appendingPathComponent("broken.zip"), into: dir) }
        }
    }
}

/// Простейший zip без сжатия: чтобы проверить враждебные имена записей, которые не создать обычными средствами.
func storedZip(_ entries: [(String, String)]) -> [UInt8] {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        table[i] = c
    }
    func crc(_ bytes: [UInt8]) -> UInt32 { ~bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) } }
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    var out: [UInt8] = [], central: [UInt8] = []
    for (name, text) in entries {
        let n = Array(name.utf8), body = Array(text.utf8), sum = crc(body), offset = UInt32(out.count)
        let common = le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(sum) + le32(UInt32(body.count)) + le32(UInt32(body.count)) + le16(n.count) + le16(0)
        out += le32(0x04034b50) + common + n + body
        central += le32(0x02014b50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + n
    }
    let start = UInt32(out.count)
    out += central
    out += le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(central.count)) + le32(start) + le16(0)
    return out
}

@MainActor
func runVideoTests() async {
    await test("Видео: тип по файлу, старые карточки-видео, экспорт, длительность") {
        checkEqual(BlockEditorController.attachmentType(for: URL(fileURLWithPath: "/x/клип.MOV")), .video)
        checkEqual(BlockEditorController.attachmentType(for: URL(fileURLWithPath: "/x/a.mp4")), .video)
        checkEqual(BlockEditorController.attachmentType(for: URL(fileURLWithPath: "/x/a.heic")), .image)
        checkEqual(BlockEditorController.attachmentType(for: URL(fileURLWithPath: "/x/a.mp3")), .file, "звук — файл")
        checkEqual(BlockEditorController.attachmentType(for: URL(fileURLWithPath: "/x/a.pdf")), .file)
        let page = UUID(), asset = UUID()
        func atom(_ type: BlockType, _ name: String) -> Block {
            Block(id: UUID(), pageID: page, parentID: nil, sortKey: "a", type: type, contentVersion: 1,
                  contentJSON: "{\"asset\":\"\(asset.uuidString.lowercased())\",\"name\":\"\(name)\",\"size\":10}", plainText: name, createdAt: 1, updatedAt: 1)
        }
        let video = atom(.video, "клип.mov"), legacy = atom(.file, "старое.mp4"), doc = atom(.file, "отчёт.pdf")
        check(BlockEditorController.isVideo(video) && BlockEditorController.isVideo(legacy) && !BlockEditorController.isVideo(doc))
        checkEqual(video.assetID, asset, "вложение видео защищено от уборки как у картинки")
        check(BlockType.video.isAtom)
        let md = MarkdownExport.export(title: "Т", blocks: [video], assetFolder: "f") { _ in nil }
        check(md.markdown.contains("[клип.mov](<f/клип.mov>)") && !md.markdown.contains("!["), "видео — ссылкой на файл")
        checkEqual(md.assets.map(\.id), [asset])
        checkEqual(BlockEditorController.durationText(65.4), "1:05")
        checkEqual(BlockEditorController.durationText(3725), "1:02:05")
    }
}
