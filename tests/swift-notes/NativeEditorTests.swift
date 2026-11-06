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
        tv.setFrameSize(NSSize(width: 600, height: 300))
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
        let expected = doc.blocks.map { $0.content.map { BlockTextMapping.toView($0.plainText) } ?? "\u{FFFC}" }.joined(separator: "\n")
        checkEqual(tv.string, expected, "вид и модель \(what)", file: file, line: line)
        checkEqual(controller.spans.map(\.id), doc.blocks.map(\.id), "порядок спанов \(what)", file: file, line: line)
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
            let a = r.controller.checkboxRect(for: r.controller.spans[1])!
            let b = r.controller.checkboxRect(for: r.controller.spans[2])!
            check(a.minY < b.minY, "отметки идут сверху вниз \(a) \(b)")
            check(r.controller.handleClick(at: NSPoint(x: a.midX, y: a.midY)), "нажатие на отметку")
            checkEqual(r.doc.blocks[1].content?.checked, false)
            check(!r.controller.handleClick(at: NSPoint(x: 200, y: a.midY)), "нажатие по тексту не отмечает")
            r.caret(0, 2)
            r.controller.changeBlockType(.heading2)
            checkEqual(r.types[0], .heading2)
            checkEqual((r.tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 21, "оформление обновилось")
            checkEqual(r.tv.selectedRange().location, 2, "курсор на месте")
            r.controller.insertBlock(.task)
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
                default: r.controller.changeBlockType([BlockType.paragraph, .heading1, .task][next(3)])
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
            check(r.tv.acceptableDragTypes.isEmpty, "перетаскивание выключено")
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
