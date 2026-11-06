import Foundation

final class SeqIDs: IDGenerator {
    var n = 0
    func next() -> UUID {
        n += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
}

/// Проверка главного свойства команды: обратные изменения дают исходный документ.
func checkInverse(_ command: EditCommand, on doc: BlockDocument, _ what: String, file: StaticString = #fileID, line: UInt = #line) throws -> EditResult {
    let r = try BlockEditing.apply(command, to: doc, ids: SeqIDs(), now: 99)
    var back = r.document
    back.apply(r.inverse)
    checkEqual(back, doc, "обратное изменение: \(what)", file: file, line: line)
    return r
}

@MainActor
func runEditorTests() async {
    let page = UUID()
    let a = UUID(), b = UUID(), c = UUID()
    let doc = BlockDocument(pageID: page, blocks: [
        Block(id: a, pageID: page, sortKey: "a0", type: .heading1, content: BlockContent(text: "Заголовок"), createdAt: 1),
        Block(id: b, pageID: page, sortKey: "a1", type: .task, content: BlockContent(runs: [TextRun("Купить "), TextRun("ёлку 🎄", marks: ["b"])], checked: true), createdAt: 1),
        Block(id: c, pageID: page, sortKey: "a2", content: BlockContent(text: "Абзац"), createdAt: 1),
    ])

    await test("Команды: обратимость и содержимое") {
        let split = try checkInverse(.splitBlock(BlockPoint(blockID: b, offset: 7)), on: doc, "разделение")
        checkEqual(split.document.blocks.count, 4)
        checkEqual(split.document.blocks[1].plainText, "Купить ")
        checkEqual(split.document.blocks[2].plainText, "ёлку 🎄")
        checkEqual(split.document.blocks[2].type, .task, "задача порождает задачу")
        checkEqual(split.document.blocks[2].content?.checked, false, "новая задача не отмечена")
        checkEqual(split.document.blocks[2].content?.runs.first?.marks, ["b"], "метки сохранены")
        checkEqual(split.selection, BlockSelection(block: split.document.blocks[2].id, offset: 0))

        let heading = try checkInverse(.splitBlock(BlockPoint(blockID: a, offset: 9)), on: doc, "разделение заголовка")
        checkEqual(heading.document.blocks[1].type, .paragraph, "после заголовка — абзац")

        let merge = try checkInverse(.mergeBackward(block: c), on: doc, "объединение")
        checkEqual(merge.document.blocks.count, 2)
        checkEqual(merge.document.blocks[1].plainText, "Купить ёлку 🎄Абзац")
        checkEqual(merge.selection, BlockSelection(block: b, offset: "Купить ёлку 🎄".utf16.count))
        let first = try BlockEditing.apply(.mergeBackward(block: a), to: doc, ids: SeqIDs(), now: 1)
        check(first.changes.isEmpty, "первый блок не с чем объединять")

        _ = try checkInverse(.deleteBlock(b), on: doc, "удаление")
        _ = try checkInverse(.changeType(block: c, type: .task), on: doc, "смена типа")
        let toggled = try checkInverse(.setChecked(block: b, checked: false), on: doc, "отметка")
        checkEqual(toggled.document.block(b)?.content?.checked, false)
        checkEqual(toggled.document.block(b)?.plainText, "Купить ёлку 🎄", "текст не тронут")

        let ins = try checkInverse(.insertBlock(after: a, type: .paragraph), on: doc, "вставка")
        checkEqual(ins.document.blocks[1].plainText, "")
        check(ins.document.blocks[1].sortKey > "a0" && ins.document.blocks[1].sortKey < "a1", "ключ между соседями")
        let top = try checkInverse(.insertBlock(after: nil, type: .paragraph), on: doc, "вставка в начало")
        checkEqual(top.document.blocks.count, 4)
        check(top.document.blocks[0].plainText.isEmpty, "новый блок первым")

        let typed = try checkInverse(.setPlainText(block: b, text: "Купить большую ёлку 🎄"), on: doc, "ввод текста")
        checkEqual(typed.document.block(b)?.plainText, "Купить большую ёлку 🎄")
        check(typed.document.block(b)?.content?.runs.contains { $0.marks == ["b"] } == true, "форматирование сохранилось")
    }

    await test("Команды: неизвестный блок не меняется и не теряется") {
        let u = UUID()
        let d = BlockDocument(pageID: page, blocks: doc.blocks + [
            Block(id: u, pageID: page, parentID: nil, sortKey: "a3", type: BlockType(rawValue: "future"), contentVersion: 9, contentJSON: "{}", plainText: "", createdAt: 1, updatedAt: 1)])
        await checkThrows("правка неизвестного блока") { try BlockEditing.apply(.setPlainText(block: u, text: "x"), to: d, ids: SeqIDs(), now: 1) }
        let after = UUID()
        let e = BlockDocument(pageID: page, blocks: d.blocks + [Block(id: after, pageID: page, sortKey: "a4", content: BlockContent(text: "x"), createdAt: 1)])
        let m = try BlockEditing.apply(.mergeBackward(block: after), to: e, ids: SeqIDs(), now: 1)
        check(m.changes.isEmpty, "с неизвестным блоком не объединяем")
    }

    await test("Undo/Redo: набор склеивается, структура отменяется целиком") {
        try await withTempDir { dir in
            let clock = FakeClock(), scheduler = ManualScheduler(clock: clock)
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let session = WorkspaceSession(store: ws, name: "A", scheduler: scheduler, clock: clock, ids: RandomIDs())
            let p = try await session.createPage(parent: nil, title: "Страница")
            let e = try await session.open(p.id)
            let first = e.document.blocks[0].id
            checkEqual(e.document.blocks.count, 1, "у новой страницы есть пустой абзац")
            let initial = e.document
            e.perform_(.setPlainText(block: first, text: "П"))
            clock.now += 100
            e.perform_(.setPlainText(block: first, text: "Пр"))
            clock.now += 100
            e.perform_(.setPlainText(block: first, text: "При"))
            clock.now += 5000
            e.perform_(.splitBlock(BlockPoint(blockID: first, offset: 1)))
            let splitDoc = e.document
            checkEqual(splitDoc.blocks.count, 2)
            e.undoStep()
            checkEqual(e.document.blocks.map(\.plainText), ["При"], "разделение отменено целиком")
            e.undoStep()
            checkEqual(e.document, initial, "набор отменён одним шагом")
            check(!e.canUndo, "дальше отменять нечего")
            e.redoStep()
            checkEqual(e.document.blocks.map(\.plainText), ["При"])
            e.redoStep()
            checkEqual(e.document.blocks.map(\.plainText), splitDoc.blocks.map(\.plainText))
            e.undoStep()
            e.perform_(.setChecked(block: first, checked: true))
            check(!e.canRedo, "новая правка очищает повтор")
            try await session.close()
        }
    }

    await test("История: снимок при уходе со страницы, политика частоты") {
        let p = RevisionPolicy()
        check(!p.isDue(dirty: false, lastSnapshotAt: nil, now: 0), "без изменений не нужен")
        check(p.isDue(dirty: true, lastSnapshotAt: nil, now: 0), "первый снимок")
        check(!p.isDue(dirty: true, lastSnapshotAt: 0, now: RevisionPolicy.minInterval - 1), "рано")
        check(p.isDue(dirty: true, lastSnapshotAt: 0, now: RevisionPolicy.minInterval), "пора")
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let session = WorkspaceSession(store: ws, name: "A")
            let a = try await session.createPage(parent: nil, title: "A")
            let b = try await session.createPage(parent: nil, title: "B")
            let e = try await session.open(a.id)
            try e.perform(.setPlainText(block: e.document.blocks[0].id, text: "Текст"))
            _ = try await session.open(b.id)
            let revisions = try await ws.revisions(ofPage: a.id)
            checkEqual(revisions.count, 1, "снимок при уходе")
            let read = try await ws.blocks(ofPage: a.id)
            checkEqual(read.first?.plainText, "Текст", "правка записана до открытия другой страницы")
            try await session.close()
        }
    }
}

extension EditorSession {
    /// Команда в тестах, где ошибка не ожидается.
    func perform_(_ c: EditCommand) { _ = try? perform(c) }
}
