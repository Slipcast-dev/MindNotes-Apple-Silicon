import AppKit

/// M13, шаг 2 (ADR-0013): модель колонок — ряд, колонки, доли ширины, распускание.
func runColumnsTests() async {
    func doc(_ texts: [String]) -> (BlockDocument, [UUID]) {
        let page = UUID()
        let keys = SortKey.keys(after: nil, before: nil, count: texts.count)
        let blocks = zip(texts, keys).map { Block(id: UUID(), pageID: page, sortKey: $1, content: BlockContent(text: $0), createdAt: 1) }
        return (BlockDocument(pageID: page, blocks: blocks), blocks.map(\.id))
    }
    func apply(_ c: EditCommand, _ d: BlockDocument) throws -> BlockDocument { try BlockEditing.apply(c, to: d, ids: RandomIDs(), now: 2).document }
    func columns(_ d: BlockDocument) -> [[String]] {
        guard let row = d.blocks.first(where: { $0.type == .columnList }) else { return [] }
        return d.blocks.filter { $0.parentID == row.id && $0.type == .column }.map { c in d.blocks.filter { $0.parentID == c.id }.map(\.plainText) }
    }

    await test("Колонки: ряд из двух, третья колонка, доли, пределы") {
        var (d, ids) = doc(["А", "Б", "В", "Г", "Д", "Е", "Ж"])
        d = try apply(.makeColumns(target: ids[0], dropped: ids[1], left: false), d)
        checkEqual(columns(d), [["А"], ["Б"]], "Б справа от А")
        checkEqual(d.blocks.first?.type, .columnList, "ряд встал на место А")
        let row = d.blocks.first { $0.type == .columnList }!.id
        checkEqual(d.blocks.filter { $0.type == .column }.compactMap(AtomData.columnRatio(of:)), [0.5, 0.5])
        d = try apply(.makeColumns(target: ids[0], dropped: ids[2], left: true), d)
        checkEqual(columns(d), [["В"], ["А"], ["Б"]], "В слева от А — новая колонка в том же ряду")
        let thirds = d.blocks.filter { $0.type == .column }.compactMap(AtomData.columnRatio(of:))
        check(thirds.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 }, "ширина поровну: \(thirds)")
        d = try apply(.makeColumns(target: ids[1], dropped: ids[3], left: false), d)
        d = try apply(.makeColumns(target: ids[1], dropped: ids[4], left: false), d)
        checkEqual(columns(d).count, 5)
        let full = try BlockEditing.apply(.makeColumns(target: ids[1], dropped: ids[5], left: false), to: d, ids: RandomIDs(), now: 3)
        check(full.changes.isEmpty, "не больше пяти колонок")
        d = try apply(.setColumnRatios(row, [0.5, 0.01, 0.2, 0.2, 0.09]), d)
        let ratios = d.blocks.filter { $0.type == .column }.compactMap(AtomData.columnRatio(of:))
        check(abs(ratios.reduce(0, +) - 1) < 1e-9 && ratios.allSatisfy { $0 >= 0.09 }, "сумма 1, узкая колонка не меньше предела: \(ratios)")
        let mismatch = try BlockEditing.apply(.setColumnRatios(row, [1]), to: d, ids: RandomIDs(), now: 4)
        check(mismatch.changes.isEmpty, "число долей должно совпадать с числом колонок")
        let selfDrop = try BlockEditing.apply(.makeColumns(target: ids[6], dropped: ids[6], left: true), to: d, ids: RandomIDs(), now: 4)
        check(selfDrop.changes.isEmpty, "блок не встаёт колонкой рядом с собой")
    }

    await test("Колонки: пустые убираются, ряд из одной распускается, экспорт по очереди, отмена") {
        var (d, ids) = doc(["А", "Б", "хвост"])
        let original = d
        let made = try BlockEditing.apply(.makeColumns(target: ids[0], dropped: ids[1], left: false), to: d, ids: RandomIDs(), now: 2)
        d = made.document
        var undone = d
        undone.apply(made.inverse)
        checkEqual(undone.blocks.map(\.plainText), original.blocks.map(\.plainText), "отмена возвращает как было")
        checkEqual(undone.blocks.filter { $0.type == .columnList || $0.type == .column }.count, 0)
        let md = MarkdownExport.export(title: "Т", blocks: d.blocks, assetFolder: "f") { _ in nil }
        check(md.markdown.contains("\nА\n") && md.markdown.contains("\nБ\n") && !md.markdown.contains("    А"), "колонки по очереди, без отступа: \(md.markdown)")
        let row = d.blocks.first { $0.type == .columnList }!.id
        // Б вынесли из колонки: колонка пуста, ряд из одной — распускается, А встаёт на место ряда.
        d = try apply(.moveBlock(ids[1], parent: nil, after: nil), d)
        d = try apply(.tidyColumns(row), d)
        checkEqual(d.blocks.map(\.plainText), ["Б", "А", "хвост"], "ряд распущен, порядок сохранён")
        check(!d.blocks.contains { $0.type == .column || $0.type == .columnList }, "ни ряда, ни колонок")
    }
}

/// Колонки в настоящем редакторе: поля колонок поверх места в тексте, общая модель и отмена.
@MainActor
func runColumnsEditorTests() async {
    func spin() async { for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); await Task.yield() } }

    await test("Колонки в редакторе: поля колонок, ввод, место по высоте, бросок на край, отмена") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "Левая"), (.paragraph, "Правая"), (.paragraph, "Ниже")])
            r.tv.setFrameSize(NSSize(width: 700, height: 300))
            let left = r.doc.blocks[0].id, right = r.doc.blocks[1].id
            r.controller.perform(.makeColumns(target: left, dropped: right, left: false))
            r.controller.layoutColumns()
            await spin()
            checkEqual(r.tv.string, "\u{FFFC}\nНиже", "в основном тексте — место ряда и абзац ниже")
            let host = r.tv.subviews.compactMap { $0 as? ColumnsHost }.first
            check(host != nil, "поля колонок поставлены")
            guard let host else { return }
            checkEqual(host.columns.count, 2)
            checkEqual(host.columns.map { $0.editor.textView.string }, ["Левая", "Правая"], "каждое поле — своя колонка")
            check(host.columns[0].editor.textView.frame.maxX <= host.columns[1].editor.textView.frame.minX, "колонки рядом")

            // Ввод в правой колонке меняет общую модель; основной текст не трогается.
            let rightEditor = host.columns[1].editor
            rightEditor.textView.window?.makeFirstResponder(rightEditor.textView)
            rightEditor.textView.setSelectedRange(NSRange(location: 6, length: 0))
            rightEditor.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            checkEqual(r.doc.block(right)?.plainText, "Правая!")
            await spin()
            checkEqual(r.tv.string, "\u{FFFC}\nНиже")

            // Enter в колонке: новый блок остаётся в ней же; место ряда растёт.
            let before = host.frame.height
            rightEditor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            rightEditor.textView.insertText("ещё", replacementRange: NSRange(location: NSNotFound, length: 0))
            await spin()
            let column = r.doc.block(right)!.parentID!
            checkEqual(r.doc.blocks.filter { $0.parentID == column }.map(\.plainText), ["Правая!", "ещё"], "новая строка в колонке")
            check(host.frame.height > before, "место ряда выросло: \(before) → \(host.frame.height)")

            // Из колонки на уровень ряда не выносится.
            rightEditor.perform(.outdent(r.doc.blocks.first { $0.plainText == "ещё" }!.id))
            checkEqual(r.doc.block(r.doc.blocks.first { $0.plainText == "ещё" }!.id)?.parentID, column)

            // Бросок «Ниже» на правый край места ряда — не колонка (это сам ряд); на левый край «Левой» в поле — третья колонка.
            let below = r.doc.blocks.first { $0.plainText == "Ниже" }!.id
            r.controller.perform(.makeColumns(target: left, dropped: below, left: true))
            r.controller.layoutColumns()
            await spin()
            checkEqual(host.columns.count, 3, "третья колонка")
            checkEqual(host.columns.first?.editor.textView.string, "Ниже", "встала слева")

            // Удаление единственного блока колонки убирает колонку.
            let first = host.columns[0].editor
            first.textView.setSelectedRange(NSRange(location: 0, length: 0))
            first.run(.deleteBlock)
            r.controller.layoutColumns()
            await spin()
            checkEqual(host.columns.count, 2, "пустая колонка убрана")
            r.checkSync("основной текст после правок в колонках")

            // Отмена из основного редактора возвращает изменения колонок.
            for _ in 0..<6 { r.tv.undo(nil) }
            await spin()
            r.controller.layoutColumns()
            check(r.doc.blocks.contains { $0.type == .columnList }, "ряд на месте после нескольких отмен")
            try await r.close()
        }
    }

    await test("Колонки: бросок на край — только над блоком и внутри текста") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "Первый"), (.paragraph, "Второй")])
            r.tv.setFrameSize(NSSize(width: 600, height: 300))
            r.tv.layoutManager?.ensureLayout(for: r.tv.textContainer!)
            let first = r.controller.spans[0], dragged = r.doc.blocks[1].id
            let line = r.controller.handleRect(for: first)!
            let y = line.midY
            let right = r.controller.columnDrop(at: NSPoint(x: 590, y: y), dragging: dragged)
            checkEqual(right?.target, r.doc.blocks[0].id)
            checkEqual(right?.left, false, "правый край")
            checkEqual(r.controller.columnDrop(at: NSPoint(x: BlockEditorController.gutter + 20, y: y), dragging: dragged)?.left, true, "левый край")
            check(r.controller.columnDrop(at: NSPoint(x: 300, y: y), dragging: dragged) == nil, "середина — обычный перенос")
            check(r.controller.columnDrop(at: NSPoint(x: 10, y: y), dragging: dragged) == nil, "над ручкой — обычный перенос")
            check(r.controller.columnDrop(at: NSPoint(x: 590, y: 2000), dragging: dragged) == nil, "ниже всех блоков — обычный перенос")
            try await r.close()
        }
    }

    await test("Колонки: перенос блока между полями и выделение блоков через колонки") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "А"), (.paragraph, "Б"), (.paragraph, "В"), (.paragraph, "Низ")])
            r.tv.setFrameSize(NSSize(width: 700, height: 300))
            let ids = r.doc.blocks.map(\.id)
            r.controller.perform(.makeColumns(target: ids[0], dropped: ids[1], left: false))
            r.controller.perform(.makeColumns(target: ids[1], dropped: ids[2], left: false))
            r.controller.layoutColumns()
            await spin()
            let host = r.tv.subviews.compactMap { $0 as? ColumnsHost }.first!
            checkEqual(host.columns.count, 3)
            // Из колонки «В» в основной текст, ниже «Низ»: колонка пустеет и убирается тем же шагом.
            r.tv.layoutManager?.ensureLayout(for: r.tv.textContainer!)
            let low = r.controller.span(withID: ids[3])!
            let y = r.controller.handleRect(for: low)!.maxY + 30
            r.controller.finishDrag(ids[2], at: NSPoint(x: 200, y: y))
            r.controller.layoutColumns()
            await spin()
            checkEqual(r.doc.block(ids[2])?.parentID, nil, "блок в основном тексте")
            checkEqual(host.columns.count, 2, "опустевшая колонка убрана")
            r.tv.undo(nil)
            r.controller.layoutColumns()
            await spin()
            checkEqual(host.columns.count, 3, "одна отмена вернула и блок, и колонку")
            // Из колонки «Б» в колонку «А»: перенос в другое поле.
            let leftEditor = host.columns[0].editor
            leftEditor.textView.layoutManager?.ensureLayout(for: leftEditor.textView.textContainer!)
            let aSpan = leftEditor.span(withID: ids[0])!
            leftEditor.finishDrag(ids[1], at: NSPoint(x: 60, y: leftEditor.handleRect(for: aSpan)!.maxY + 2))
            r.controller.layoutColumns()
            await spin()
            checkEqual(r.doc.block(ids[1])?.parentID, r.doc.block(ids[0])?.parentID, "«Б» теперь в колонке «А»")
            checkEqual(host.columns.count, 2, "колонка «Б» опустела и убрана")
            // Выделение от «А» (колонка) до «Низ» (основной текст): целые блоки, копирование и удаление.
            leftEditor.selectBlocks(from: ids[0], to: ids[3])
            check(r.controller.hasBlockSelection && leftEditor.hasBlockSelection, "выделение общее для всех полей")
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            r.controller.copy(to: board)
            checkEqual(board.string(forType: .string), "А\nБ\nВ\nНиз", "копирование — блоки по очереди")
            r.controller.deleteBlockSelection()
            r.controller.layoutColumns()
            await spin()
            check(!r.doc.blocks.contains { ["А", "Б", "В", "Низ"].contains($0.plainText) }, "выделенные блоки удалены")
            check(!r.doc.blocks.contains { $0.type == .columnList || $0.type == .column }, "пустой ряд убран")
            check(!r.doc.blocks.isEmpty, "страница не осталась без строки")
            r.tv.undo(nil)
            check(r.doc.blocks.contains { $0.plainText == "Низ" }, "⌘Z вернул удалённое")
            try await r.close()
        }
    }
}

/// Peek (M14): вторая страница открыта рядом своей сессией на том же сохранении.
@MainActor
func runPeekTests() async {
    await test("Peek: правки основной страницы и страницы сбоку записываются обе") {
        try await withTempDir { dir in
            let store = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { store.close() }
            let clock = FakeClock()
            let session = WorkspaceSession(store: store, name: "T", scheduler: ManualScheduler(clock: clock), clock: clock, ids: RandomIDs())
            let main = try await session.createPage(parent: nil, title: "Основная")
            let side = try await session.createPage(parent: nil, title: "Сбоку")
            let mainEditor = try await session.open(main.id)
            let peek = try await EditorSession.open(pageID: side.id, store: store, coordinator: session.coordinator, clock: clock, ids: RandomIDs())
            if peek.document.blocks.isEmpty { try peek.perform(.insertBlock(after: nil, type: .paragraph), recordUndo: false, quiet: true) }
            try mainEditor.perform(.setPlainText(block: mainEditor.document.blocks[0].id, text: "текст основной"))
            try peek.perform(.setPlainText(block: peek.document.blocks[0].id, text: "текст сбоку"))
            try mainEditor.perform(.insertBlock(after: mainEditor.document.blocks[0].id, type: .paragraph))
            try await peek.close()
            try await session.coordinator.flush()
            checkEqual(try await store.blocks(ofPage: side.id).map(\.plainText), ["текст сбоку"], "правка в Peek записана на свою страницу")
            checkEqual(try await store.blocks(ofPage: main.id).map(\.plainText), ["текст основной", ""], "основная страница не задета")
            try mainEditor.perform(.setPlainText(block: mainEditor.document.blocks[1].id, text: "после закрытия Peek"))
            try await session.closeEditor()
            checkEqual(try await store.blocks(ofPage: main.id).last?.plainText, "после закрытия Peek", "основной редактор работает дальше")
            try await store.setMeta("peek." + main.id.uuidString, "center")
            checkEqual(try await store.meta("peek." + main.id.uuidString), "center", "режим Peek хранится в пространстве")
        }
    }
}

/// Комментарии (M14, схема v10).
func runCommentTests() async {
    await test("Комментарии: ветки, ответы, решено, удаление, автор, корзина, метка в тексте") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let page = try await w.createPage(parent: nil, title: "Страница", id: UUID(), now: 1)
            let anna = try await w.addPerson(name: "Анна", color: nil, emoji: nil, id: UUID(), now: 1)
            let block = UUID(), thread = UUID()
            try await w.addComment(page: page.id, block: block, thread: nil, author: anna.id, body: "  Проверить цифры ", anchor: "итог 120", id: thread, now: 2)
            try await w.addComment(page: page.id, block: nil, thread: thread, author: nil, body: "Проверил", anchor: "", id: UUID(), now: 3)
            try await w.addComment(page: page.id, block: nil, thread: nil, author: UUID(), body: "О странице", anchor: "", id: UUID(), now: 4)
            await checkThrows("пустой комментарий") { try await w.addComment(page: page.id, block: nil, thread: nil, author: nil, body: "  ", anchor: "", id: UUID(), now: 5) }
            await checkThrows("ответ в чужую ветку") { try await w.addComment(page: page.id, block: nil, thread: UUID(), author: nil, body: "x", anchor: "", id: UUID(), now: 5) }
            var list = try await w.comments(page: page.id)
            let threads = CommentThread.group(list)
            checkEqual(threads.count, 2)
            checkEqual(threads[0].root.body, "Проверить цифры", "пробелы сняты")
            checkEqual(threads[0].root.authorName, "Анна")
            checkEqual(threads[0].replies.map(\.body), ["Проверил"])
            checkEqual(threads[1].root.authorID, nil, "неизвестный автор не записывается")
            try await w.resolveThread(thread, resolved: true, now: 6)
            list = try await w.comments(page: page.id)
            check(list.first { $0.id == thread }?.resolved == true, "решено")
            try await w.deletePerson(anna.id, now: 7)
            list = try await w.comments(page: page.id)
            checkEqual(list.first { $0.id == thread }?.authorID, nil, "удалённый человек — комментарий без автора")
            try await w.deleteComment(thread)
            checkEqual(try await w.comments(page: page.id).count, 1, "удаление первого комментария удаляет ветку")
            let batch = UUID()
            try await w.trashPage(page.id, batch: batch, now: 8)
            checkEqual(try await w.comments(page: page.id).count, 1, "в корзине комментарии сохраняются")
            try await w.purgeTrash(batch: batch)
            checkEqual(try await w.comments(page: page.id).count, 0, "удаление навсегда убирает и комментарии")
        }
        // Метка в тексте: набор рядом не продлевает комментарий, экспорт отмечает потерю.
        let mark = Comment.mark(UUID())
        let runs = [TextRun("итог 120", marks: [mark]), TextRun(" руб.")]
        checkEqual(RichText.replace(runs, range: 8..<8, with: "!").first?.text, "итог 120", "набор после не входит в комментарий")
        let block = Block(id: UUID(), pageID: UUID(), sortKey: "a", content: BlockContent(runs: runs), createdAt: 1)
        let md = MarkdownExport.export(title: "Т", blocks: [block], assetFolder: "f") { _ in nil }
        check(md.markdown.contains("итог 120 руб."), "текст выгружается")
        check(md.report.contains { $0.reason.hasPrefix("Комментарии не выгружаются") }, "комментарии отмечены в отчёте")
    }
}

/// Обновления и расширения (ADR-0014, ADR-0015): разбор без сети.
func runUpdateAndExtensionTests() async {
    await test("Обновления: версии, выпуск GitHub, контрольные суммы") {
        check(AppVersion("1.2.0")! < AppVersion("v1.3.0")!)
        check(AppVersion("1.10")! > AppVersion("1.9.9")!)
        check(AppVersion("1.3")! == AppVersion("1.3.0")!, "недостающие части — нули")
        checkEqual(AppVersion("2.0.0-beta")?.description, "2.0.0")
        check(AppVersion("abc") == nil && AppVersion("1..2") == nil && AppVersion("") == nil)
        func release(_ extra: String = "", tag: String = "v1.3.0", host: String = "github.com") -> Data {
            Data("""
            {"tag_name":"\(tag)","name":"MindNotes 1.3.0","body":"Что нового",\(extra)
             "assets":[{"name":"MindNotes-1.3.0.dmg","browser_download_url":"https://\(host)/x/MindNotes-1.3.0.dmg"},
                       {"name":"SHA256SUMS.txt","browser_download_url":"https://\(host)/x/SHA256SUMS.txt"}]}
            """.utf8)
        }
        let r = ReleaseInfo.parse(release())
        checkEqual(r?.version.description, "1.3.0")
        checkEqual(r?.image.lastPathComponent, "MindNotes-1.3.0.dmg")
        checkEqual(r?.notes, "Что нового")
        check(ReleaseInfo.parse(release(#""prerelease":true,"#)) == nil, "предварительный выпуск не предлагается")
        check(ReleaseInfo.parse(release(#""draft":true,"#)) == nil, "черновик не предлагается")
        check(ReleaseInfo.parse(release(host: "evil.example")) == nil, "образ только с github.com")
        check(ReleaseInfo.parse(release(tag: "latest")) == nil, "метка без версии")
        check(ReleaseInfo.parse(Data("не json".utf8)) == nil)
        let sums = ReleaseInfo.checksums("""
        cff2291ea207c90423eaa5e18e1bd30970466cd17eee9ba27dd56b8853b675ec  MindNotes-1.3.0.dmg
        DA398A372AAC2066170EDAA08404EAB709CC02D875A4E6639918A838C62A16D7 *build/Demo.mindnotesbackup
        мусор
        """)
        checkEqual(sums["MindNotes-1.3.0.dmg"], "cff2291ea207c90423eaa5e18e1bd30970466cd17eee9ba27dd56b8853b675ec")
        checkEqual(sums["Demo.mindnotesbackup"], "da398a372aac2066170edaa08404eab709cc02d875a4e6639918a838c62a16d7", "путь и «*» отбрасываются, регистр — нижний")
        checkEqual(sums.count, 2)
    }

    await test("Расширения: описание, виды, версия, палитра темы") {
        let m = ExtensionManifest.parse(Data(#"{"id":"my.ocean","name":"Океан","version":"1.1","kind":"theme","minApp":"1.3.0"}"#.utf8))
        checkEqual(m?.kind, .theme)
        check(m?.supported(by: AppVersion("1.3.0")) == true)
        check(m?.supported(by: AppVersion("1.2.0")) == false, "нужна более новая версия приложения")
        checkEqual(ExtensionManifest.parse(Data(#"{"id":"x","name":"X","kind":"plugin"}"#.utf8))?.kind, .plugin, "плагин — вид расширения (ADR-0019)")
        checkEqual(ExtensionManifest.parse(Data(#"{"id":"x","name":"X","kind":"widget"}"#.utf8))?.kind, .unsupported("widget"))
        check(ExtensionManifest.parse(Data(#"{"id":"../evil","name":"X","kind":"theme"}"#.utf8)) == nil, "id без разделителей пути")
        check(ExtensionManifest.parse(Data(#"{"name":"X","kind":"theme"}"#.utf8)) == nil, "без id")
        let fields = ThemeColors.fields.map { "\"\($0)\":\"#112233\"" }.joined(separator: ",")
        let good = ThemeColors.parse(Data("{\"light\":{\(fields)},\"dark\":{\(fields)}}".utf8))
        checkEqual(good.colors?.light["ink"], 0x112233)
        check(good.error == nil)
        let bad = ThemeColors.parse(Data("{\"light\":{\(fields.replacingOccurrences(of: "\"ink\":\"#112233\"", with: "\"ink\":\"red\""))},\"dark\":{\(fields)}}".utf8))
        check(bad.colors == nil && bad.error?.contains("light.ink") == true, "ошибка называет поле: \(bad.error ?? "")")
        check(ThemeColors.parse(Data("{\"light\":{\(fields)}}".utf8)).error?.contains("dark") == true, "нужны оба режима")
    }
}
