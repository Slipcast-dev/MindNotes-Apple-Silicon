import AppKit
import Foundation

/// Тестовый стенд: настоящий NSTextView, настоящая сессия и база; ввод подаётся программно.
@MainActor
final class EditorRig {
    let ws: SQLiteWorkspace
    let session: WorkspaceSession
    let editor: EditorSession
    let controller: BlockEditorController
    let clock = FakeClock()
    let window: NSWindow
    var tv: BlockTextView { controller.textView }
    var doc: BlockDocument { controller.document }

    init(dir: URL, blocks: [(BlockType, String)], checked: Set<Int> = []) async throws {
        let store = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w-\(UUID().uuidString)"), name: "T")
        ws = store
        let scheduler = ManualScheduler(clock: clock)
        session = WorkspaceSession(store: store, name: "T", scheduler: scheduler, clock: clock, ids: RandomIDs())
        let page = try await session.createPage(parent: nil, title: "Страница")
        var batch = SaveBatch()
        var key: String?
        for (i, item) in blocks.enumerated() {
            let id = UUID()
            key = SortKey.between(key, nil)
            batch.upserts[id] = Block(id: id, pageID: page.id, sortKey: key!, type: item.0,
                                      content: BlockContent(runs: [TextRun(item.1)], checked: checked.contains(i)), createdAt: 1)
        }
        if !batch.isEmpty { try await store.commit(batch) }
        editor = try await session.open(page.id)
        controller = BlockEditorController(session: editor)
        // Настоящее окно вне экрана: вид остаётся первым получателем, как в приложении.
        window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = controller.textView
        view.setFrameSize(NSSize(width: 600, height: 300))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
    }

    func type(_ text: String) { tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    func key(_ selector: Selector) { tv.doCommand(by: selector) }
    func caret(_ i: Int, _ offset: Int) {
        tv.setSelectedRange(NSRange(location: controller.spans[i].location + offset, length: 0))
    }
    func select(_ i: Int, _ a: Int, _ j: Int, _ b: Int) {
        let from = controller.spans[i].location + a, to = controller.spans[j].location + b
        tv.setSelectedRange(NSRange(location: from, length: to - from))
    }
    var texts: [String] { doc.blocks.map(\.plainText) }
    var types: [BlockType] { doc.blocks.map(\.type) }

    /// Главный инвариант: текст вида и разбиение совпадают с моделью.
    func checkSync(_ what: String = "", file: StaticString = #fileID, line: UInt = #line) {
        let expected = controller.visible.map { $0.content.map { BlockTextMapping.toView($0.plainText) } ?? "\u{FFFC}" }.joined(separator: "\n")
        checkEqual(tv.string, expected, "вид и модель \(what)", file: file, line: line)
        checkEqual(controller.spans.map(\.id), controller.visible.map(\.id), "порядок спанов \(what)", file: file, line: line)
        var at = 0
        for s in controller.spans {
            check(s.location == at, "положение спана \(what)", file: file, line: line)
            at = s.end + 1
        }
    }

    func close() async throws { try await session.close() }
}

@MainActor
func runNativeEditorTests() async {
    _ = NSApplication.shared

    await test("M3: кириллица, emoji и составные символы доходят до базы") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, ""), (.heading1, "Заголовок"), (.task, "Задача")])
            r.caret(0, 0)
            r.type("Ёж 🦔 ")
            r.type("👨‍👩‍👧")
            r.type("e\u{301}")
            r.checkSync()
            checkEqual(r.texts[0], "Ёж 🦔 👨‍👩‍👧e\u{301}")
            r.caret(0, ("Ёж 🦔 ".utf16.count + "👨‍👩‍👧".utf16.count))
            r.tv.deleteBackward(nil)
            checkEqual(r.texts[0], "Ёж 🦔 e\u{301}", "emoji удаляется целиком")
            r.checkSync()
            let page = r.editor.pageID
            try await r.close()
            let re = try SQLiteWorkspace.open(at: r.ws.layout.root)
            let saved = try await re.blocks(ofPage: page).sorted { $0.sortKey < $1.sortKey }
            checkEqual(saved.map(\.plainText), ["Ёж 🦔 e\u{301}", "Заголовок", "Задача"], "после перезапуска")
            re.close()
        }
    }

    await test("M3: Enter и Backspace по правилам типов") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.heading1, "Заголовок"), (.task, "Задача"), (.paragraph, "Абзац")])
            r.caret(1, 3)
            r.key(#selector(NSResponder.insertNewline(_:)))
            checkEqual(r.texts, ["Заголовок", "Зад", "ача", "Абзац"])
            checkEqual(r.types[2], .task, "задача порождает задачу")
            checkEqual(r.tv.selectedRange().location, r.controller.spans[2].location, "курсор в начале нового блока")
            r.checkSync("Enter")
            r.caret(2, 3)
            r.key(#selector(NSResponder.insertNewline(_:)))
            checkEqual(r.texts.count, 5)
            r.key(#selector(NSResponder.insertNewline(_:)))
            checkEqual(r.types[3], .paragraph, "Enter в пустой задаче снимает тип")
            r.checkSync("пустая задача")
            r.caret(2, 0)
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.types[2], .paragraph, "Backspace в начале сначала снимает тип")
            checkEqual(r.texts.count, 5, "текст не тронут")
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.texts[1], "Задача", "затем объединяет")
            checkEqual(r.tv.selectedRange().location, r.controller.spans[1].location + 3, "курсор на границе")
            r.checkSync("объединение")
            r.caret(0, 0)
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.types[0], .paragraph)
            let n = r.texts.count
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.texts.count, n, "первый блок не с чем объединять")
            r.caret(0, 9)
            r.key(#selector(NSResponder.deleteForward(_:)))
            checkEqual(r.texts[0], "ЗаголовокЗадача", "Delete в конце объединяет следующий")
            checkEqual(r.tv.selectedRange().location, 9, "курсор на месте")
            r.checkSync("Delete")
            try await r.close()
        }
    }

    await test("M3: Shift+Enter — перенос внутри блока") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "Первая")])
            r.caret(0, 6)
            r.key(#selector(NSResponder.insertLineBreak(_:)))
            r.type("вторая")
            checkEqual(r.texts, ["Первая\nвторая"], "один блок, перенос в модели")
            check(r.tv.string.contains("\u{2028}"), "в виде разделитель строки")
            r.checkSync()
            r.key(#selector(NSResponder.insertNewline(_:)))
            checkEqual(r.texts, ["Первая\nвторая", ""])
            try await r.close()
        }
    }

    await test("AT-04: выделение через 3 блока, копирование, вставка и точная отмена") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.heading1, "Один"), (.task, "Два ✅"), (.paragraph, "Три"), (.paragraph, "Хвост")], checked: [1])
            let before = r.doc
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            r.select(0, 2, 2, 1)
            r.controller.copy(to: board)
            checkEqual(board.string(forType: .string), "ин\nДва ✅\nТ", "обычный текст в буфере")
            check(board.data(forType: BlockEditorController.pasteboardType) != nil, "собственный формат")

            r.caret(3, 5)
            r.controller.paste(from: board)
            checkEqual(r.texts, ["Один", "Два ✅", "Три", "Хвостин", "Два ✅", "Т"])
            checkEqual(r.types[4], .task, "тип сохранён")
            checkEqual(r.doc.blocks[4].content?.checked, true, "отметка сохранена")
            r.checkSync("вставка")
            let afterPaste = r.doc
            r.tv.undo(nil)
            checkEqual(r.doc, before, "восстановлено точное исходное состояние")
            r.checkSync("отмена")
            r.tv.redo(nil)
            checkEqual(r.doc, afterPaste, "повтор")
            r.checkSync("повтор")
            r.tv.undo(nil)

            r.select(0, 2, 2, 1)
            r.type("Ж")
            checkEqual(r.texts, ["ОдЖри", "Хвост"], "ввод заменяет выделение через блоки")
            checkEqual(r.tv.selectedRange(), NSRange(location: 3, length: 0), "курсор после ввода")
            r.checkSync("замена")
            r.tv.undo(nil)
            checkEqual(r.doc, before, "отмена замены")

            r.select(0, 2, 2, 1)
            r.controller.cut(to: board)
            checkEqual(r.texts, ["Одри", "Хвост"], "вырезание")
            r.tv.undo(nil)
            checkEqual(r.doc, before)
            checkEqual(r.tv.selectedRange(), NSRange(location: 2, length: "ин\nДва ✅\nТ".utf16.count), "выделение восстановлено")

            r.select(0, 0, 3, 5)
            r.tv.deleteBackward(nil)
            checkEqual(r.texts, [""], "всё удалено, поле осталось")
            r.checkSync("всё удалено")
            r.tv.undo(nil)
            checkEqual(r.doc, before)
            try await r.close()
        }
    }

    await test("M3: вставка обычного и многострочного текста") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "абв")])
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            board.clearContents()
            board.setString("раз\r\nдва\n\nчетыре", forType: .string)
            r.caret(0, 1)
            r.controller.paste(from: board)
            checkEqual(r.texts, ["араз", "два", "", "четыребв"])
            r.checkSync()
            try await r.close()
        }
    }

    await test("M3: составной ввод (IME) не попадает в модель до завершения") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "абв"), (.paragraph, "где"), (.paragraph, "жзи")])
            let before = r.doc
            r.caret(0, 3)
            r.tv.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            check(r.tv.hasMarkedText(), "идёт составной ввод")
            checkEqual(r.texts[0], "абв", "модель не меняется")
            checkEqual(r.controller.spans[1].location, 5, "разбиение следует за видом")
            r.tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            checkEqual(r.controller.spans[1].location, 6)
            r.type("日本")
            check(!r.tv.hasMarkedText(), "ввод завершён")
            checkEqual(r.texts[0], "абв日本")
            r.checkSync("завершение")

            r.caret(1, 1)
            r.tv.setMarkedText("с", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            r.tv.unmarkText()
            checkEqual(r.texts[1], "гсде", "unmarkText оставляет текст")
            r.checkSync("unmark")

            r.select(0, 1, 2, 1)
            r.tv.setMarkedText("ю", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            checkEqual(r.texts, ["ази"], "выделение через блоки удалено до составного ввода")
            r.type("я")
            checkEqual(r.texts, ["аязи"])
            r.checkSync("поверх выделения")
            while r.controller.canUndo { r.tv.undo(nil) }
            checkEqual(r.doc, before, "всё отменяется")
            r.checkSync("полная отмена")
            try await r.close()
        }
    }

    await test("M3: неизвестный блок и заглушка таблицы") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "до"), (.paragraph, "после")])
            let page = r.editor.pageID
            // Блок будущей версии в той же странице.
            var b = SaveBatch()
            let tableID = UUID()
            b.upserts[tableID] = Block(id: tableID, pageID: page, parentID: nil, sortKey: SortKey.between(r.doc.blocks[0].sortKey, r.doc.blocks[1].sortKey),
                                       type: BlockType(rawValue: "table"), contentVersion: 1, contentJSON: #"{"rows":[["а"]]}"#, plainText: "а", createdAt: 1, updatedAt: 1)
            try await r.ws.commit(b)
            let second = try await r.session.open(page)
            let c = BlockEditorController(session: second)
            c.textView.setFrameSize(NSSize(width: 600, height: 300))
            checkEqual(c.spans.map(\.length), [2, 1, 5], "неделимый символ")
            let put: @MainActor (Int) -> Void = { c.textView.setSelectedRange(NSRange(location: $0, length: 0)) }
            let ins: @MainActor () -> Void = { c.textView.insertText("ф", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            put(4) // Сразу после блока.
            ins()
            check(c.document.block(tableID) != nil, "ввод рядом блок не удаляет")
            checkEqual(c.document.blocks.map(\.plainText), ["до", "а", "ф", "после"], "текст стал новым блоком")
            checkEqual(try c.document.block(tableID)?.contentJSON(), #"{"rows":[["а"]]}"#, "исходные данные целы")
            c.undo()
            put(5) // Начало блока «после».
            c.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            checkEqual(c.document.blocks.count, 3, "абзац не сливается с неизвестным блоком")
            c.textView.setSelectedRange(NSRange(location: 3, length: 1))
            c.textView.deleteBackward(nil)
            check(c.document.block(tableID) == nil, "выделенный целиком удаляется")
            c.undo()
            checkEqual(try c.document.block(tableID)?.contentJSON(), #"{"rows":[["а"]]}"#, "и возвращается отменой")
            try await r.close()
        }
    }

    await test("M3: задачи, смена типа, позиции отметок") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "текст"), (.task, "задача"), (.task, "")])
            r.controller.perform(.setChecked(block: r.doc.blocks[1].id, checked: true))
            checkEqual(r.doc.blocks[1].content?.checked, true)
            r.checkSync("отметка")
            let a = r.controller.markerRect(for: r.controller.spans[1])!
            let b = r.controller.markerRect(for: r.controller.spans[2])!
            check(a.minY < b.minY, "отметки идут сверху вниз \(a) \(b)")
            check(r.controller.handleClick(at: NSPoint(x: a.midX, y: a.midY)), "нажатие на отметку")
            checkEqual(r.doc.blocks[1].content?.checked, false)
            check(!r.controller.handleClick(at: NSPoint(x: 200, y: a.midY)), "нажатие по тексту не отмечает")
            r.caret(0, 2)
            r.controller.run(.turnInto(.heading2))
            checkEqual(r.types[0], .heading2)
            checkEqual((r.tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 21, "оформление обновилось")
            checkEqual(r.tv.selectedRange().location, 2, "курсор на месте")
            r.controller.perform(.insertBlock(after: r.doc.blocks[0].id, type: .task))
            checkEqual(r.types[1], .task)
            r.checkSync("вставка блока")
            try await r.close()
        }
    }

    await test("M3: случайные правки — вид и модель совпадают, Undo возвращает начало") {
        try await withTempDir { dir in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next(_ n: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(max(n, 1)))
            }
            let words = ["ё", "Привет", "🦔", "👨‍👩‍👧", "a", " ", "e\u{301}", "новое слово"]
            let r = try await EditorRig(dir: dir, blocks: [(.heading1, "Заголовок"), (.paragraph, "Текст абзаца"), (.task, "Задача 🎄"), (.paragraph, ""), (.heading3, "Конец")])
            let initial = r.doc
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            for step in 0..<600 {
                r.clock.now += 2000 // Правки не склеиваются: проверяется каждый шаг отмены.
                let total = (r.tv.string as NSString).length
                let a = next(total + 1), b = next(total + 1)
                // Границы — только по целым символам.
                let lo = (r.tv.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: min(a, max(total - 1, 0)), length: 0)).location
                let up = a == b ? lo : max(lo, (r.tv.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: min(max(a, b), max(total - 1, 0)), length: 0)).location)
                r.tv.setSelectedRange(NSRange(location: lo, length: up - lo))
                switch next(9) {
                case 0, 1, 2: r.type(words[next(words.count)])
                case 3: r.key(#selector(NSResponder.insertNewline(_:)))
                case 4: r.key(#selector(NSResponder.deleteBackward(_:)))
                case 5: r.key(#selector(NSResponder.deleteForward(_:)))
                case 6: r.controller.copy(to: board); r.tv.setSelectedRange(NSRange(location: (r.tv.string as NSString).length, length: 0)); r.controller.paste(from: board)
                case 7: if r.controller.canUndo { r.tv.undo(nil) }
                default: r.controller.run(.turnInto([BlockType.paragraph, .heading1, .task, .bullet, .quote, .code][next(6)]))
                }
                r.checkSync("шаг \(step)")
                if !TestRun.failed.isEmpty { break }
            }
            var guardCount = 0
            while r.controller.canUndo && guardCount < 2000 { r.tv.undo(nil); guardCount += 1 }
            r.checkSync("после отмены")
            checkEqual(r.doc.blocks.map(\.plainText), initial.blocks.map(\.plainText), "текст вернулся к началу")
            checkEqual(r.doc.blocks.map(\.type), initial.blocks.map(\.type), "типы вернулись")
            try await r.session.close()
            let re = try SQLiteWorkspace.open(at: r.ws.layout.root)
            let saved = try await re.blocks(ofPage: r.editor.pageID)
            checkEqual(Set(saved.map(\.id)), Set(initial.blocks.map(\.id)), "в базе те же блоки")
            re.close()
        }
    }
}

/// Отклик обычного ввода на странице из 500 блоков: команда, модель и раскладка.
@MainActor
func benchEditor() async throws {
    _ = NSApplication.shared
    try await withTempDir { dir in
        var items: [(BlockType, String)] = []
        for i in 0..<500 { items.append((i % 7 == 0 ? .heading2 : (i % 5 == 0 ? .task : .paragraph), "Строка \(i): немного русского текста для раскладки страницы 🦔")) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = try await EditorRig(dir: dir, blocks: items)
        print(String(format: "open+render ms: %.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
        r.caret(250, 10)
        var times: [Double] = []
        for i in 0..<400 {
            let t = DispatchTime.now().uptimeNanoseconds
            r.type(i % 10 == 9 ? " " : "ё")
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        times.sort()
        print(String(format: "typing ms: p50=%.2f p95=%.2f max=%.2f", times[200], times[380], times[399]))
        var splits: [Double] = []
        for _ in 0..<50 {
            let t = DispatchTime.now().uptimeNanoseconds
            r.key(#selector(NSResponder.insertNewline(_:)))
            splits.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        splits.sort()
        print(String(format: "enter ms: p50=%.2f p95=%.2f", splits[25], splits[47]))
        try await r.close()
    }
}

@MainActor
func runNativeEditorReviewTests() async {
    _ = NSApplication.shared
    await test("M3 ревью: несколько диапазонов и атрибуты в обход модели отклоняются") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "первый"), (.paragraph, "второй")])
            let before = r.doc
            let many = [NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 7, length: 1))]
            check(!r.controller.textView(r.tv, shouldChangeTextInRanges: many, replacementStrings: ["x", "y"]), "правка в двух местах отклонена")
            check(!r.controller.textView(r.tv, shouldChangeTextIn: NSRange(location: 0, length: 2), replacementString: nil), "только атрибуты")
            let accepted = Set(r.tv.acceptableDragTypes)
            check(accepted.contains(.fileURL) && accepted.contains(.png) && accepted.contains(.tiff), "файлы и картинки принимаются")
            check(!accepted.contains(.string) && !accepted.contains(.rtf), "текст не перетаскивается")
            checkEqual(r.doc, before)
            r.checkSync()
            try await r.close()
        }
    }
    await test("M3 ревью: Shift+Enter поверх выделения не делит блок, \\r\\n делит") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "первый"), (.paragraph, "второй")])
            r.select(0, 3, 1, 3)
            r.key(#selector(NSResponder.insertLineBreak(_:)))
            checkEqual(r.texts, ["пер\nрой"], "перенос внутри одного блока")
            r.checkSync("перенос")
            r.caret(0, 7)
            r.type("a\r\nb")
            checkEqual(r.texts, ["пер\nройa", "b"], "CRLF не попадает в текст блока")
            r.checkSync("CRLF")
            try await r.close()
        }
    }
    await test("M3 ревью: строка целиком сохраняет тип следующего блока") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "строка"), (.task, "задача"), (.paragraph, "хвост")], checked: [1])
            let before = r.doc
            r.tv.setSelectedRange(NSRange(location: 0, length: r.controller.spans[1].location))
            r.tv.deleteBackward(nil)
            checkEqual(r.texts, ["задача", "хвост"])
            checkEqual(r.types[0], .task, "тип сохранён")
            checkEqual(r.doc.blocks[0].content?.checked, true, "отметка сохранена")
            checkEqual(r.tv.selectedRange().location, 0)
            r.checkSync()
            r.tv.undo(nil)
            checkEqual(r.doc, before)
            try await r.close()
        }
    }
    await test("M3 ревью: составной ввод с коротким итогом и нажатия рядом с непонятным блоком") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "до"), (.paragraph, "кон")])
            r.caret(1, 3)
            r.tv.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            r.type("你好")
            checkEqual(r.texts, ["до", "кон你好"], "итог короче составного в конце документа")
            r.checkSync()
            let page = r.editor.pageID
            var b = SaveBatch()
            let tableID = UUID()
            b.upserts[tableID] = Block(id: tableID, pageID: page, parentID: nil, sortKey: SortKey.between(r.doc.blocks[0].sortKey, r.doc.blocks[1].sortKey),
                                       type: BlockType(rawValue: "table"), contentVersion: 1, contentJSON: "{}", plainText: "", createdAt: 1, updatedAt: 1)
            try await r.session.coordinator.flush()
            try await r.ws.commit(b)
            let second = try await r.session.open(page)
            let c = BlockEditorController(session: second)
            var errors: [String] = []
            c.onError = { errors.append($0) }
            c.textView.setSelectedRange(NSRange(location: 2, length: 0))
            c.textView.doCommand(by: #selector(NSResponder.deleteForward(_:)))
            check(c.document.block(tableID) != nil, "Delete перед непонятным блоком не удаляет его")
            c.textView.setSelectedRange(NSRange(location: 3, length: 0))
            c.markedTextEnded()
            check(errors.isEmpty, "нет ложной ошибки: \(errors)")
            try await r.close()
        }
    }
    await test("M3 ревью: набор продолжает оформление слева") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.heading2, "Заголовок"), (.paragraph, "текст")])
            r.caret(0, 3)
            checkEqual((r.tv.typingAttributes[.font] as? NSFont)?.pointSize, 21)
            r.caret(1, 0)
            checkEqual((r.tv.typingAttributes[.font] as? NSFont)?.pointSize, 14, "у начала блока — оформление блока")
            try await r.close()
        }
    }
}

@MainActor
func runNotionEditorTests() async {
    _ = NSApplication.shared
    await test("Markdown-сокращения превращают абзац в блок и отменяются") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "")])
            for (input, type) in [("# ", BlockType.heading1), ("## ", .heading2), ("### ", .heading3), ("- ", .bullet), ("1. ", .numbered), ("[] ", .task), ("> ", .quote)] {
                r.caret(0, 0)
                for ch in input { r.type(String(ch)) }
                checkEqual(r.types[0], type, input)
                checkEqual(r.texts[0], "", "текст сокращения убран: \(input)")
                r.checkSync(input)
                r.tv.undo(nil)
                r.controller.perform(.changeType(block: r.doc.blocks[0].id, type: .paragraph))
                r.controller.perform(.setPlainText(block: r.doc.blocks[0].id, text: ""))
            }
            r.caret(0, 0)
            for ch in "---" { r.type(String(ch)) }
            checkEqual(r.doc.blocks[0].type, .divider, "разделитель")
            check(r.doc.blocks.count == 2 && r.types[1] == .paragraph, "ввод продолжается ниже")
            r.checkSync("разделитель")
            r.type("дальше")
            checkEqual(r.texts[1], "дальше")
            try await r.close()
        }
    }

    await test("Списки: Enter продолжает, на пустом пункте снимает, номера считаются") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.numbered, "раз"), (.numbered, "два"), (.paragraph, "текст"), (.numbered, "снова")])
            checkEqual(r.doc.blocks.map { r.controller.number(of: $0.id) }, [1, 2, 1, 1], "нумерация и сброс")
            r.caret(1, 3)
            r.key(#selector(NSResponder.insertNewline(_:)))
            checkEqual(r.types[2], .numbered, "список продолжается")
            r.key(#selector(NSResponder.insertNewline(_:)))
            checkEqual(r.types[2], .paragraph, "пустой пункт снимает тип")
            r.checkSync()
            try await r.close()
        }
    }

    await test("Вложенность: Tab, Shift+Tab, отступ в виде, Backspace выводит наверх") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.bullet, "первый"), (.bullet, "второй"), (.paragraph, "третий")])
            r.caret(1, 2)
            r.key(#selector(NSResponder.insertTab(_:)))
            checkEqual(r.doc.blocks[1].parentID, r.doc.blocks[0].id, "вложен в предыдущий")
            checkEqual(r.controller.depth(of: r.doc.blocks[1].id), 1)
            checkEqual(r.tv.selectedRange().location, r.controller.spans[1].location + 2, "курсор на месте")
            let style = r.tv.textStorage?.attribute(.paragraphStyle, at: r.controller.spans[1].location, effectiveRange: nil) as? NSParagraphStyle
            checkEqual(style?.headIndent, BlockTextStyle.markerIndent + BlockTextStyle.nestIndent, "отступ в виде")
            r.checkSync("Tab")
            r.key(#selector(NSResponder.insertBacktab(_:)))
            checkEqual(r.doc.blocks[1].parentID, nil, "обратно")
            r.key(#selector(NSResponder.insertTab(_:)))
            r.controller.perform(.changeType(block: r.doc.blocks[1].id, type: .paragraph))
            r.caret(1, 0)
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.doc.blocks[1].parentID, nil, "Backspace уменьшает вложенность")
            checkEqual(r.texts.count, 3, "без объединения")
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.texts.count, 2, "затем объединяет")
            r.checkSync("Backspace")
            try await r.close()
        }
    }

    await test("Сворачиваемый блок скрывает потомков, не теряя их") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.toggle, "раздел"), (.paragraph, "внутри"), (.paragraph, "снаружи")])
            r.caret(1, 0)
            r.key(#selector(NSResponder.insertTab(_:)))
            let id = r.doc.blocks[0].id
            r.controller.perform(.setCollapsed(block: id, collapsed: true))
            checkEqual(r.tv.string, "раздел\nснаружи", "потомок скрыт")
            checkEqual(r.doc.blocks.count, 3, "но остался в модели")
            r.checkSync("свёрнуто")
            r.caret(1, 3)
            r.type("ё")
            checkEqual(r.texts, ["раздел", "внутри", "снаёружи"], "правка попадает в нужный блок")
            r.checkSync("правка рядом")
            r.controller.perform(.setCollapsed(block: id, collapsed: false))
            checkEqual(r.tv.string, "раздел\nвнутри\nснаёружи")
            r.checkSync("развёрнуто")
            try await r.close()
        }
    }

    await test("Форматирование: выделение через блоки, снятие, цвет, ссылка, очистка") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "первый"), (.paragraph, "второй")])
            let before = r.doc
            r.select(0, 2, 1, 3)
            r.controller.run(.mark("b"))
            let marks: @MainActor (Int) -> [[String]] = { r.doc.blocks[$0].content!.runs.map(\.marks) }
            checkEqual(marks(0), [[], ["b"]])
            checkEqual(marks(1), [["b"], []])
            checkEqual(r.tv.selectedRange().length, 8, "выделение сохранено")
            check(r.controller.isMarked("b"), "состояние кнопки")
            let bold = r.tv.textStorage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
            check(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true, "вид обновлён")
            r.checkSync("жирный")
            r.controller.run(.mark("b"))
            checkEqual(marks(0), [[]], "повторное действие снимает")
            r.controller.run(.color("red"))
            r.controller.run(.highlight("yellow"))
            r.controller.run(.color("blue"))
            check(marks(0)[1].contains("c:blue") && !marks(0)[1].contains("c:red"), "цвет заменяется")
            check(marks(0)[1].contains("bg:yellow"), "маркер остаётся")
            r.controller.perform(.formatText(r.controller.selection(for: r.tv.selectedRange()), .setValue(prefix: "a:", value: "https://example.com")))
            let link = r.tv.textStorage?.attribute(.link, at: 3, effectiveRange: nil) as? URL
            checkEqual(link?.absoluteString, "https://example.com", "ссылка в виде")
            r.controller.run(.clearFormat)
            checkEqual(marks(0), [[]], "очистка")
            while r.controller.canUndo { r.tv.undo(nil) }
            checkEqual(r.doc, before, "всё отменяется")
            r.caret(0, 6)
            r.controller.run(.mark("b"))
            r.type("Ж")
            check(r.doc.blocks[0].content!.runs.contains { $0.text == "Ж" && $0.marks == ["b"] }, "⌘B перед набором")
            r.checkSync("ввод с меткой")
            try await r.close()
        }
    }

    await test("Меню «/»: поиск по-русски, клавиши, Escape, применение одной правкой") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "")])
            var shown: [[String]] = []
            r.controller.onSlashChange = { state, items, _ in if state != nil { shown.append(items.map(\.title)) } }
            r.caret(0, 0)
            r.type("/")
            check(r.controller.slash != nil, "открылось")
            checkEqual(shown.last?.count, EditorAction.slashItems.count)
            r.type("ц")
            r.type("и")
            checkEqual(shown.last, ["Цитата"], "поиск по названию")
            let beforeChoice = r.controller.slash?.query
            checkEqual(beforeChoice, "ци")
            r.key(#selector(NSResponder.insertNewline(_:)))
            check(r.controller.slash == nil, "закрылось")
            checkEqual(r.types[0], .quote)
            checkEqual(r.texts, [""], "текст запроса убран")
            r.checkSync("выбор")
            r.tv.undo(nil)
            checkEqual(r.types[0], .paragraph, "одна правка отмены")
            checkEqual(r.texts[0], "/ци")
            r.checkSync("отмена")
            r.controller.perform(.setPlainText(block: r.doc.blocks[0].id, text: ""))
            r.controller.renderAll()
            r.caret(0, 0)
            r.type("/")
            r.key(#selector(NSResponder.moveDown(_:)))
            checkEqual(r.controller.slash?.selected, 1, "стрелка вниз")
            r.key(#selector(NSResponder.moveUp(_:)))
            r.key(#selector(NSResponder.cancelOperation(_:)))
            check(r.controller.slash == nil, "Escape закрывает")
            checkEqual(r.texts[0], "/", "текст остаётся")
            r.type("ёёё")
            check(r.controller.slash == nil, "после Escape не открывается снова")
            r.caret(0, 0)
            r.controller.perform(.setPlainText(block: r.doc.blocks[0].id, text: "слово "))
            r.controller.renderAll()
            r.caret(0, 6)
            r.type("/")
            check(r.controller.slash != nil, "после пробела открывается")
            r.type("разд")
            r.key(#selector(NSResponder.insertNewline(_:)))
            check(r.doc.blocks.contains { $0.type == .divider }, "вставка разделителя")
            checkEqual(r.texts[0], "слово ", "остальной текст цел")
            r.checkSync("вставка")
            r.controller.perform(.setPlainText(block: r.doc.blocks.last!.id, text: "url/путь"))
            r.controller.renderAll()
            r.caret(r.doc.blocks.count - 1, 3)
            r.type("/")
            check(r.controller.slash == nil, "внутри слова не открывается")
            checkEqual(EditorAction.filterSlash("зелёный").count, 0)
            check(EditorAction.filterSlash("ЗАГОЛОВОК").count == 3, "регистр не важен")
            check(!EditorAction.filterSlash("спойлер").isEmpty, "синонимы")
            try await r.close()
        }
    }

    await test("Код: Enter и Tab внутри блока, разделитель неделим") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.code, "let x"), (.paragraph, "текст")])
            r.caret(0, 5)
            r.key(#selector(NSResponder.insertNewline(_:)))
            r.key(#selector(NSResponder.insertTab(_:)))
            r.type("y")
            checkEqual(r.texts, ["let x\n    y", "текст"], "новая строка и отступ в том же блоке")
            r.checkSync()
            r.controller.perform(.insertBlock(after: r.doc.blocks[0].id, type: .divider))
            checkEqual(r.controller.spans[1].length, 1)
            r.caret(2, 0)
            r.key(#selector(NSResponder.deleteBackward(_:)))
            check(r.doc.blocks.contains { $0.type == .divider }, "с разделителем абзац не сливается")
            r.checkSync("разделитель")
            try await r.close()
        }
    }

    await test("Импорт Markdown: все типы блоков, оригинал не меняется") {
        try await withTempDir { dir in
            let file = dir.appendingPathComponent("заметка.md")
            let text = "# З\n\n- пункт\n1. номер\n> цитата\n---\n```\nкод\n\n  строка\n```\nабзац\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            let hash = try fileHash(file)
            let read = try TextFileReader.read(file)
            let f = MarkdownImport.fragments(from: read.text)
            checkEqual(f.map(\.type), ["heading1", "bullet", "numbered", "quote", "divider", "code", "paragraph"])
            checkEqual(f[5].plain, "код\n\n  строка", "код без изменений")
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "")])
            r.controller.perform(.replaceRange(BlockSelection(block: r.doc.blocks[0].id, offset: 0), f))
            checkEqual(r.types.map(\.rawValue), ["heading1", "bullet", "numbered", "quote", "divider", "code", "paragraph"])
            r.checkSync()
            checkEqual(try fileHash(file), hash, "файл не изменён")
            try await r.close()
        }
    }
}

@MainActor
func runNotionReviewTests() async {
    _ = NSApplication.shared
    await test("Ревью: строка целиком с потомком не ломает структуру и сохранение") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "родитель"), (.paragraph, "дитя1"), (.paragraph, "дитя2"), (.paragraph, "конец")])
            let parent = r.doc.blocks[0].id, c1 = r.doc.blocks[1].id, c2 = r.doc.blocks[2].id
            r.controller.perform(.batch([.indent(c1), .indent(c2)]))
            let before = r.doc
            r.tv.setSelectedRange(NSRange(location: 0, length: r.controller.spans[1].location))
            r.tv.deleteBackward(nil)
            checkEqual(r.texts, ["дитя1", "дитя2", "конец"])
            checkEqual(r.doc.block(c1)?.parentID, nil, "занял место родителя")
            checkEqual(r.doc.block(c2)?.parentID, c1, "второй ребёнок под ним")
            check(r.doc.block(parent) == nil)
            r.checkSync()
            try await r.session.coordinator.flush()
            let saved = try await r.ws.blocks(ofPage: r.editor.pageID)
            checkEqual(Set(saved.map(\.plainText)), ["дитя1", "дитя2", "конец"], "база приняла правку")
            r.tv.undo(nil)
            checkEqual(r.doc, before)
            try await r.session.coordinator.flush()
            let back = try await r.ws.blocks(ofPage: r.editor.pageID)
            checkEqual(back.count, 4, "отмена записана")
            try await r.close()
        }
    }

    await test("Ревью: свёрнутый блок не теряет скрытых потомков") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.toggle, "раздел"), (.paragraph, "внутри"), (.paragraph, "снаружи"), (.paragraph, "ещё")])
            let toggle = r.doc.blocks[0].id, inner = r.doc.blocks[1].id
            r.controller.perform(.batch([.indent(inner), .setCollapsed(block: toggle, collapsed: true)]))
            r.checkSync("свёрнуто")
            r.select(0, 3, 1, 3)
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            r.controller.copy(to: board)
            checkEqual(board.string(forType: .string), "дел\nсна", "скрытое не копируется")
            r.tv.deleteBackward(nil)
            check(r.doc.block(inner) != nil, "скрытый потомок цел")
            checkEqual(r.doc.block(toggle)?.plainText, "разружи")
            r.checkSync("удаление через свёрнутый")
            r.tv.undo(nil)
            r.caret(0, 6)
            r.key(#selector(NSResponder.deleteForward(_:)))
            checkEqual(r.texts, ["раздел", "внутри", "снаружи", "ещё"], "Delete в конце свёрнутого ничего не сливает")
            r.caret(1, 0)
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.doc.block(toggle)?.plainText, "разделснаружи", "Backspace сливает с видимым блоком, а не со скрытым")
            checkEqual(r.doc.block(inner)?.plainText, "внутри")
            r.checkSync("Backspace")
            try await r.close()
        }
    }

    await test("Ревью: смена типа свёрнутого блока показывает потомков; вложение в свёрнутый разворачивает") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.toggle, "раздел"), (.paragraph, "внутри"), (.paragraph, "снаружи")])
            let toggle = r.doc.blocks[0].id, inner = r.doc.blocks[1].id, outer = r.doc.blocks[2].id
            r.controller.perform(.batch([.indent(inner), .setCollapsed(block: toggle, collapsed: true)]))
            r.caret(1, 0)
            r.key(#selector(NSResponder.insertTab(_:)))
            checkEqual(r.doc.block(outer)?.parentID, toggle)
            check(r.doc.block(toggle)?.isCollapsed == false, "свёрнутый родитель раскрылся")
            r.checkSync("Tab")
            r.controller.perform(.setCollapsed(block: toggle, collapsed: true))
            r.controller.perform(.changeType(block: toggle, type: .paragraph))
            checkEqual(r.tv.string, "раздел\nвнутри\nснаружи", "потомки снова видны")
            r.checkSync("смена типа")
            try await r.close()
        }
    }

    await test("Ревью: outdent сохраняет порядок; выделение строки не захватывает следующую") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "P"), (.paragraph, "c1"), (.paragraph, "b"), (.paragraph, "c2"), (.paragraph, "конец")])
            r.controller.perform(.batch(r.doc.blocks[1...3].map { .indent($0.id) }))
            let b = r.doc.blocks[2].id, c2 = r.doc.blocks[3].id
            let before = r.doc
            r.caret(2, 0)
            r.key(#selector(NSResponder.insertBacktab(_:)))
            checkEqual(r.texts, ["P", "c1", "b", "c2", "конец"], "порядок текста тот же")
            checkEqual(r.doc.block(c2)?.parentID, b, "младший брат под ним")
            r.checkSync("outdent")
            r.tv.undo(nil)
            checkEqual(r.doc, before)
            let line = NSRange(location: r.controller.spans[4].location - r.controller.spans[3].length - 1, length: r.controller.spans[3].length + 1)
            r.tv.setSelectedRange(line)
            r.controller.run(.turnInto(.heading1))
            checkEqual(r.doc.blocks.last?.type, .paragraph, "следующий блок не затронут")
            checkEqual(r.doc.block(c2)?.type, .heading1)
            try await r.close()
        }
    }

    await test("Ревью: дублирование и вставка сохраняют тип; код не разбивается") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.task, "дело"), (.code, "a")], checked: [0])
            r.caret(0, 2)
            r.controller.run(.duplicateBlock)
            checkEqual(r.types.map(\.rawValue), ["task", "task", "code"], "тип сохранён")
            checkEqual(r.doc.blocks[1].content?.checked, true)
            r.checkSync("дублирование")
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            board.clearContents()
            board.setString("b\nc\r\nd", forType: .string)
            r.caret(2, 1)
            r.controller.paste(from: board)
            checkEqual(r.texts[2], "ab\nc\nd", "код одним блоком")
            r.checkSync("вставка в код")
            r.controller.perform(.setPlainText(block: r.doc.blocks[0].id, text: ""))
            r.controller.renderAll()
            r.caret(0, 0)
            r.controller.paste(from: board)
            checkEqual(r.types[0], .task, "обычный текст в пустую задачу сохраняет её тип")
            r.checkSync("вставка в пустой блок")
            try await r.close()
        }
    }

    await test("Ревью: метки набора не трогают другие; ⌘B снимается; набор — один шаг отмены") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "текст")])
            r.select(0, 0, 0, 5)
            r.controller.run(.highlight("yellow"))
            r.caret(0, 5)
            r.controller.run(.mark("b"))
            r.type("Ж")
            r.type("Ю")
            let last = r.doc.blocks[0].content!.runs.last!
            checkEqual(last.text, "ЖЮ")
            check(last.marks.contains("b") && last.marks.contains("bg:yellow"), "жирный добавлен, маркер остался: \(last.marks)")
            r.tv.undo(nil)
            checkEqual(r.texts[0], "текст", "один шаг отмены")
            r.tv.redo(nil)
            r.caret(0, 7)
            check(r.controller.isMarked("b"), "у курсора жирный")
            r.controller.run(.mark("b"))
            check(!r.controller.isMarked("b"), "снят для следующего ввода")
            r.type("я")
            checkEqual(r.doc.blocks[0].content!.runs.last!.text, "я")
            check(!r.doc.blocks[0].content!.runs.last!.marks.contains("b"), "ввод без жирного")
            r.checkSync()
            try await r.close()
        }
    }

    await test("Ревью: импорт не съедает символы; двоичный файл отклоняется") {
        checkEqual(RichText.plain(MarkdownImport.inline("snake_case_name и 2 * 3 * 4 и *.txt и *.md")), "snake_case_name и 2 * 3 * 4 и *.txt и *.md")
        checkEqual(MarkdownImport.inline("_курсив_ и `a*b*c`").map(\.text), ["курсив", " и ", "a*b*c"])
        try await withTempDir { dir in
            let bin = dir.appendingPathComponent("a.bin")
            try Data([0x41, 0, 0x42]).write(to: bin)
            await checkThrows("двоичный") { try TextFileReader.read(bin) }
        }
    }
}

@MainActor
func runPageLinkTests() async {
    _ = NSApplication.shared
    await test("[[: список страниц, поиск, вставка ссылки, переход, обратная ссылка") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "см. "), (.code, "код")])
            let target = UUID()
            r.controller.pageSearch = { q in
                let all: [(id: UUID, title: String)] = [(target, "Ёлка"), (UUID(), "Дневник")]
                return all.filter { q.isEmpty || SearchText.normalize($0.title).contains(SearchText.normalize(q)) }
            }
            var shown: [[String]] = []
            r.controller.onSlashChange = { s, items, _ in if s != nil { shown.append(items.map(\.title)) } }
            var opened: UUID?
            r.controller.onOpenLink = { page, _ in opened = page }
            r.caret(0, 4)
            r.type("[")
            check(r.controller.slash == nil, "одна скобка не открывает")
            r.type("[")
            check(r.controller.slash?.kind == .pageLink, "две скобки открывают")
            checkEqual(shown.last?.count, 2)
            r.type("е")
            r.type("л")
            checkEqual(shown.last, ["Ёлка"], "поиск с ё/е")
            r.key(#selector(NSResponder.insertNewline(_:)))
            checkEqual(r.texts[0], "см. Ёлка", "запрос заменён заголовком")
            check(r.doc.blocks[0].content!.runs.contains { $0.marks == [PageLink.mark(target)] }, "ссылка по UUID")
            r.checkSync("ссылка")
            let url = r.tv.textStorage?.attribute(.link, at: 5, effectiveRange: nil) as? URL
            checkEqual(url.flatMap(PageLink.page(from:)), target, "ссылка в виде")
            check(r.controller.textView(r.tv, clickedOnLink: url!, at: 5), "внутренняя ссылка обработана")
            checkEqual(opened, target)
            check(!r.controller.textView(r.tv, clickedOnLink: URL(string: "https://example.com")!, at: 0), "внешняя идёт в браузер")
            r.type(" дальше")
            checkEqual(r.doc.blocks[0].content!.runs.last?.text, " дальше")
            check(r.doc.blocks[0].content!.runs.last?.marks.isEmpty == true, "после ссылки обычный текст")
            try await r.session.coordinator.flush()
            let pages = try await r.ws.backlinks(to: target)
            checkEqual(pages.first?.blockID, r.doc.blocks[0].id, "обратная ссылка записана")
            r.tv.undo(nil)
            r.checkSync("отмена")
            r.caret(1, 3)
            r.type("[")
            r.type("[")
            check(r.controller.slash == nil, "в коде не открывается")
            r.caret(0, 0)
            r.type("[")
            r.type("[")
            r.key(#selector(NSResponder.cancelOperation(_:)))
            check(r.controller.slash == nil, "Escape")
            try await r.close()
        }
    }
    await test("Показ блока из поиска") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "один"), (.paragraph, "два")])
            r.controller.reveal(r.doc.blocks[1].id)
            checkEqual(r.tv.selectedRange().location, r.controller.spans[1].location)
            try await r.close()
        }
    }
    await test("Поиск: нормализация и фрагмент") {
        checkEqual(SearchText.tokens("  Ёлка-Палка!  "), ["елка", "палка"])
        checkEqual(SearchText.match("\"а*"), "\"а\"*")
        check(SearchText.match("!!!") == nil, "нет слов")
        let long = String(repeating: "слово ", count: 40) + "цель " + String(repeating: "конец ", count: 40)
        let s = SearchText.snippet(long, query: "цель")
        check(s.contains("цель") && s.hasPrefix("…") && s.hasSuffix("…"), "вокруг совпадения: \(s)")
        checkEqual(PageLink.page(fromMark: "a:https://example.com"), nil)
    }
}

@MainActor
func runAttachmentTests() async {
    _ = NSApplication.shared
    await test("Изображение и файл: копия в пространстве, блок, связь, архив, отмена") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "до"), (.paragraph, "после")])
            r.controller.addAttachment = { url in try await r.ws.addAsset(copying: url, now: 1) }
            r.controller.assetURL = { try? r.ws.assetFileURLSync($0) }
            let png = dir.appendingPathComponent("картинка.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .png, properties: [:])!.write(to: png)
            let doc = dir.appendingPathComponent("отчёт.pdf")
            try Data("pdf".utf8).write(to: doc)
            let before = r.doc
            r.caret(0, 2)
            r.controller.insertFiles([png, doc])
            for _ in 0..<40 where r.doc.blocks.count < 4 { try await Task.sleep(nanoseconds: 50_000_000) }
            checkEqual(r.doc.blocks.map(\.type.rawValue), ["paragraph", "image", "file", "paragraph"], "типы блоков")
            r.checkSync("вставка")
            let image = r.doc.blocks.first { $0.type == .image }!, file = r.doc.blocks.first { $0.type == .file }!
            checkEqual(AtomData.name(of: file), "отчёт.pdf", "исходное имя")
            let url = try r.ws.assetFileURLSync(image.assetID!)
            check(url?.path.contains("/assets/") == true, "файл в пространстве")
            try FileManager.default.removeItem(at: png)
            check(FileManager.default.fileExists(atPath: url!.path), "копия не зависит от оригинала")
            try await r.session.coordinator.flush()
            let links = try r.ws.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM block_assets") }
            checkEqual(links, 2, "блоки ссылаются на вложения")
            let found = try await r.ws.search("отчёт")
            checkEqual(found.first?.blockID, file.id, "файл находится по имени")
            let archive = dir.appendingPathComponent("a.minervabackup")
            let backup = try BackupService.create(workspaceRoot: r.ws.layout.root, snapshotter: r.ws, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 1)
            checkEqual(backup.manifest.files.count, 3, "база и два вложения")
            check(backup.isComplete, "копия полна")
            r.tv.undo(nil)
            checkEqual(r.doc.blocks.map(\.plainText).filter { !$0.isEmpty }, before.blocks.map(\.plainText), "отмена убирает блоки")
            r.checkSync("отмена")
            // Удалённый блок не трогает файл: его ещё может вернуть отмена или история.
            check(FileManager.default.fileExists(atPath: url!.path), "файл остаётся")
            try await r.close()
        }
    }

    await test("Таблица: вставка, правка данных, поиск, отмена, нажатие открывает редактор") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "")])
            r.caret(0, 0)
            r.controller.run(.insertTable)
            checkEqual(r.doc.blocks[0].type, .table, "пустая строка стала таблицей")
            checkEqual(AtomData.rows(of: r.doc.blocks[0]), [["", "", ""], ["", "", ""]])
            checkEqual(r.types.last, .paragraph, "ниже строка для ввода")
            r.checkSync("вставка")
            let id = r.doc.blocks[0].id
            let rows = [["Имя", "Город"], ["Ёж", "Лес"]]
            r.controller.perform(.setAtomData(block: id, json: AtomData.tableJSON(rows), plain: AtomData.tablePlain(rows)))
            checkEqual(AtomData.rows(of: r.doc.block(id)!), rows)
            r.checkSync("правка")
            try await r.session.coordinator.flush()
            let hit = try await r.ws.search("город")
            checkEqual(hit.first?.blockID, id, "поиск по таблице")
            var opened: UUID?
            r.controller.onEditTable = { opened = $0.id }
            r.tv.layoutManager?.ensureLayout(for: r.tv.textContainer!)
            check(r.controller.handleClick(at: NSPoint(x: 60, y: 12)), "нажатие по таблице")
            checkEqual(opened, id)
            r.tv.undo(nil)
            checkEqual(AtomData.rows(of: r.doc.block(id)!), [["", "", ""], ["", "", ""]], "отмена правки")
            r.checkSync("отмена")
            try await r.close()
        }
    }

    await test("Перемещение блоков: команда, потомки, запрет цикла, клавиши, бросок") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "а"), (.paragraph, "б"), (.paragraph, "в"), (.paragraph, "г")])
            let a = r.doc.blocks[0].id, b = r.doc.blocks[1].id, c = r.doc.blocks[2].id, d = r.doc.blocks[3].id
            r.controller.perform(.indent(c))
            checkEqual(r.doc.block(c)?.parentID, b)
            let before = r.doc
            r.controller.perform(.moveBlock(b, parent: nil, after: d))
            checkEqual(r.texts, ["а", "г", "б", "в"], "блок идёт с потомками")
            r.checkSync("перенос")
            r.tv.undo(nil)
            checkEqual(r.doc, before, "отмена")
            check(!r.controller.perform(.moveBlock(b, parent: c, after: nil)), "в собственного потомка нельзя")
            check(!r.controller.perform(.moveBlock(b, parent: b, after: nil)), "в себя нельзя")
            checkEqual(r.doc, before)
            r.controller.perform(.moveBlock(d, parent: nil, after: nil))
            checkEqual(r.texts, ["г", "а", "б", "в"], "в начало")
            r.tv.undo(nil)
            r.caret(0, 0)
            r.controller.run(.moveBlockDown)
            checkEqual(r.texts, ["б", "в", "а", "г"], "вниз через соседа с потомками")
            r.controller.run(.moveBlockUp)
            checkEqual(r.texts, ["а", "б", "в", "г"], "обратно")
            r.tv.layoutManager?.ensureLayout(for: r.tv.textContainer!)
            let lastSpan = r.controller.spans[3]
            let y = r.controller.handleRect(for: lastSpan)!.maxY + 40
            r.controller.finishDrag(a, at: NSPoint(x: 30, y: y))
            checkEqual(r.texts, ["б", "в", "г", "а"], "бросок ниже последнего")
            r.checkSync("бросок")
            r.controller.finishDrag(a, at: NSPoint(x: 30, y: y))
            checkEqual(r.texts.last, "а", "бросок на себя ничего не меняет")
            try await r.close()
        }
    }

    await test("Ссылка на блок и адрес на выделение") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "текст"), (.paragraph, "цель")])
            let page = r.editor.pageID, block = r.doc.blocks[1].id
            r.controller.pageSearch = { _ in [(page, "Моя страница")] }
            var got: (UUID, UUID?)?
            r.controller.onOpenLink = { got = ($0, $1) }
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            board.clearContents()
            board.setString(PageLink.url(page: page, block: block), forType: .string)
            r.caret(0, 5)
            r.controller.paste(from: board)
            checkEqual(r.texts[0], "текстМоя страница")
            let url = r.tv.textStorage?.attribute(.link, at: 6, effectiveRange: nil) as? URL
            _ = r.controller.textView(r.tv, clickedOnLink: url!, at: 6)
            checkEqual(got?.0, page)
            checkEqual(got?.1, block, "ссылка ведёт на блок")
            board.clearContents()
            board.setString("https://example.com/путь", forType: .string)
            r.select(1, 0, 1, 4)
            r.controller.paste(from: board)
            checkEqual(r.texts[1], "цель", "текст не заменён")
            board.clearContents()
            board.setString("https://example.com/", forType: .string)
            r.select(1, 0, 1, 4)
            r.controller.paste(from: board)
            check(r.doc.blocks[1].content!.runs[0].marks.contains("a:https://example.com/"), "адрес на выделенный текст: \(r.doc.blocks[1].content!.runs[0].marks)")
            try await r.close()
        }
    }
}

@MainActor
func runAttachmentReviewTests() async {
    _ = NSApplication.shared
    await test("Ревью вложений: исполняемые файлы, таблица будущей версии, символическая ссылка, каталог") {
        check(BlockEditorController.isExecutable(URL(fileURLWithPath: "/a/запуск.command")))
        check(BlockEditorController.isExecutable(URL(fileURLWithPath: "/a/Программа.APP")))
        check(BlockEditorController.isExecutable(URL(fileURLWithPath: "/a/run.sh")))
        check(!BlockEditorController.isExecutable(URL(fileURLWithPath: "/a/отчёт.pdf")))
        check(!BlockEditorController.isExecutable(URL(fileURLWithPath: "/a/фото.png")))

        let page = UUID()
        let extra = #"{"format":"будущее","rows":[["a"]]}"#
        let keep = Block(id: UUID(), pageID: page, parentID: nil, sortKey: "a0", type: .table, contentVersion: 1, contentJSON: extra, plainText: "a", createdAt: 1, updatedAt: 1)
        check(AtomData.isEditableTable(keep))
        let written = AtomData.tableJSON([["б"]], keeping: keep.atomJSON)
        check(written.contains("будущее") && written.contains("б"), "неизвестное поле сохранено: \(written)")
        let newer = Block(id: UUID(), pageID: page, parentID: nil, sortKey: "a0", type: .table, contentVersion: 9, contentJSON: extra, plainText: "", createdAt: 1, updatedAt: 1)
        check(!AtomData.isEditableTable(newer), "более новая версия")
        let odd = Block(id: UUID(), pageID: page, parentID: nil, sortKey: "a0", type: .table, contentVersion: 1, contentJSON: #"{"rows":[[1,{"a":2}]]}"#, plainText: "", createdAt: 1, updatedAt: 1)
        check(!AtomData.isEditableTable(odd), "непонятные ячейки")

        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let real = dir.appendingPathComponent("настоящий.txt")
            try Data("данные".utf8).write(to: real)
            let link = dir.appendingPathComponent("ссылка.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let asset = try await ws.addAsset(copying: link, now: 1)
            checkEqual(asset.originalName, "ссылка.txt")
            let copy = try await ws.assetURL(asset.id)
            let attrs = try FileManager.default.attributesOfItem(atPath: copy!.path)
            checkEqual(attrs[.type] as? FileAttributeType, .typeRegular, "копируется цель, а не ссылка")
            checkEqual(try Data(contentsOf: copy!), Data("данные".utf8))
            await checkThrows("каталог") { try await ws.addAsset(copying: dir, now: 1) }
            ws.close()
        }
    }

    await test("Ревью вложений: бросок на то же место и вставка в конце страницы одной правкой") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "а"), (.paragraph, "б")])
            let before = r.doc
            let b = r.doc.blocks[1].id
            r.tv.layoutManager?.ensureLayout(for: r.tv.textContainer!)
            let rect = r.controller.handleRect(for: r.controller.spans[1])!
            r.controller.finishDrag(b, at: NSPoint(x: 30, y: rect.minY + 1))
            checkEqual(r.doc, before, "то же место")
            check(!r.controller.canUndo, "нет шага отмены")
            r.caret(1, 1)
            r.controller.insertFragments([AtomData.table([["x"]])])
            checkEqual(r.types.map(\.rawValue), ["paragraph", "paragraph", "table", "paragraph"], "ниже строка для ввода")
            r.checkSync("вставка")
            r.tv.undo(nil)
            checkEqual(r.doc, before, "одна правка отмены")
            try await r.close()
        }
    }
}
