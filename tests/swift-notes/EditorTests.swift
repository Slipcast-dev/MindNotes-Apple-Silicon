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

func runReviewFixTests() async {
    await test("Ключи блоков: перенумерация при многократной вставке в одну точку") {
        let page = UUID(), first = UUID(), last = UUID()
        var doc = BlockDocument(pageID: page, blocks: [
            Block(id: first, pageID: page, sortKey: "a0", content: BlockContent(text: "первый"), createdAt: 1),
            Block(id: last, pageID: page, sortKey: "a1", content: BlockContent(text: "последний"), createdAt: 1)])
        let ids = SeqIDs()
        var maxLength = 0
        for i in 0..<300 {
            let r = try BlockEditing.apply(.insertBlock(after: first, type: .paragraph), to: doc, ids: ids, now: Int64(i))
            var back = r.document
            back.apply(r.inverse)
            checkEqual(back, doc, "обратимость при перенумерации")
            doc = r.document
            maxLength = max(maxLength, doc.blocks.map(\.sortKey.utf8.count).max() ?? 0)
            checkEqual(doc.blocks.first?.id, first)
            checkEqual(doc.blocks.last?.id, last)
            checkEqual(doc.blocks[1].id, r.selection?.anchor.blockID, "новый блок сразу после якоря")
        }
        check(maxLength <= SortKey.maxLength, "длина ключа ограничена: \(maxLength)")
        var splitDoc = doc
        for _ in 0..<100 {
            let r = try BlockEditing.apply(.splitBlock(BlockPoint(blockID: first, offset: 0)), to: splitDoc, ids: ids, now: 1)
            splitDoc = r.document
            checkEqual(splitDoc.blocks.first?.id, first, "разделение сохраняет порядок")
            checkEqual(splitDoc.blocks[1].plainText, "первый", "текст перешёл в новый блок один раз")
            var clear = splitDoc
            let id = splitDoc.blocks[1].id
            clear.apply([.delete(id)])
            splitDoc = clear
            splitDoc.apply([.upsert(Block(id: first, pageID: page, sortKey: splitDoc.block(first)!.sortKey, content: BlockContent(text: "первый"), createdAt: 1))])
        }
    }

    await test("Создание: метаданные не отделены от схемы, сбой можно повторить") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            var bad = SQLiteWorkspace.Options()
            bad.migrations = [Migration(version: 1, name: "сбой") { db in
                try db.execute("PRAGMA application_id=\(Migrations.applicationID)")
                try db.execute(Migrations.schemaV1)
                try db.execute("NOT SQL")
            }]
            await checkThrows("сбой создания") { try SQLiteWorkspace.create(at: w, name: "A", options: bad) }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: w.path)) ?? []
            checkEqual(left, [], "папка снова пуста: \(left)")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let id = try await ws.workspaceID()
            check(id.uuidString.count == 36, "идентификатор есть")
            ws.close()
        }
    }

    await test("Backup: неудача не трогает прежний архив") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let archive = dir.appendingPathComponent("a.minervabackup")
            try BackupService.create(workspaceRoot: w, snapshotter: ws, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 1)
            let before = try fileHash(archive)
            struct Broken: DatabaseSnapshotter {
                func snapshotDatabase(to url: URL) throws { throw WorkspaceError.diskFull }
            }
            await checkThrows("снимок не удался") { try BackupService.create(workspaceRoot: w, snapshotter: Broken(), inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 2) }
            checkEqual(try fileHash(archive), before, "прежний архив цел")
            ws.close()
        }
    }

    await test("RichText.diff: форма нормализации не теряется") {
        let nfc = "ё", nfd = "е\u{308}"
        let d = RichText.diff(old: nfc, new: nfd)
        check(d != nil, "NFC и NFD различаются для поля и модели")
        checkEqual(d?.text.unicodeScalars.count, 2)
    }
}

@MainActor
func runTrashTests() async {
    await test("AT-08: удалить страницу с дочерними и восстановить") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let session = WorkspaceSession(store: ws, name: "A")
            let root = try await session.createPage(parent: nil, title: "Проект")
            let child = try await session.createPage(parent: root.id, title: "Подстраница")
            let grand = try await session.createPage(parent: child.id, title: "Внучка")
            let other = try await session.createPage(parent: nil, title: "Другая")
            let e = try await session.open(child.id)
            try e.perform(.setPlainText(block: e.document.blocks[0].id, text: "Несохранённый текст ёж"))

            try await session.trash(root.id)
            check(session.editor == nil, "открытая страница закрыта")
            checkEqual(session.pages.map(\.id), [other.id], "поддерево исчезло из обычного списка")
            let items = try await ws.trashItems()
            checkEqual(items.count, 1, "одно действие — одна запись корзины")
            checkEqual(items[0].page.id, root.id)
            checkEqual(items[0].descendants, 2)

            await checkThrows("перемещение под удалённую запрещено") { try await session.move(other.id, toParent: root.id, afterSibling: nil) }

            let moved = try await session.restore(batch: items[0].batchID)
            check(!moved, "родитель не менялся")
            checkEqual(session.pages.first { $0.id == grand.id }?.parentID, child.id, "дерево вернулось")
            checkEqual(session.pages.first { $0.id == child.id }?.parentID, root.id)
            let blocks = try await ws.blocks(ofPage: child.id)
            checkEqual(blocks.first?.plainText, "Несохранённый текст ёж", "содержимое и последняя правка на месте")
            let empty = try await ws.trashItems()
            check(empty.isEmpty, "корзина пуста")
            try await session.close()
        }
    }

    await test("Корзина: родитель удалён отдельно — восстановление в корень") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let session = WorkspaceSession(store: ws, name: "A")
            let parent = try await session.createPage(parent: nil, title: "Родитель")
            let child = try await session.createPage(parent: parent.id, title: "Дочерняя")
            try await session.trash(child.id)
            try await session.trash(parent.id)
            let items = try await ws.trashItems()
            checkEqual(items.count, 2, "два действия — две записи")
            let childItem = items.first { $0.page.id == child.id }!
            let moved = try await session.restore(batch: childItem.batchID)
            check(moved, "сообщаем о восстановлении в корень")
            checkEqual(session.pages.first { $0.id == child.id }?.parentID, nil)
            try await session.close()
        }
    }

    await test("Корзина: окончательное удаление не трогает остальное и переживает перезапуск") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            var ws = try SQLiteWorkspace.create(at: w, name: "A")
            let a = try await ws.createPage(parent: nil, title: "A", id: UUID(), now: 1)
            let aa = try await ws.createPage(parent: a.id, title: "AA", id: UUID(), now: 1)
            let b = try await ws.createPage(parent: nil, title: "B", id: UUID(), now: 1)
            var batch = SaveBatch()
            let bid = UUID()
            batch.upserts[bid] = Block(id: bid, pageID: aa.id, sortKey: "a0", content: BlockContent(text: "x"), createdAt: 1)
            try await ws.commit(batch)
            let del = UUID()
            try await ws.trashPage(a.id, batch: del, now: 2)
            ws.close()
            ws = try SQLiteWorkspace.open(at: w)
            let after = try await ws.trashItems()
            checkEqual(after.map(\.batchID), [del], "корзина сохранилась после перезапуска")
            try await ws.purgeTrash(batch: del)
            let pages = try await ws.allPages()
            checkEqual(pages.map(\.id), [b.id])
            let gone = try await ws.page(aa.id)
            check(gone == nil, "страница удалена окончательно")
            checkEqual(try ws.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM blocks") }, 0, "блоки удалены")
            ws.close()
        }
    }
}

@MainActor
func runFolderTests() async {
    await test("Папка: страница со значком, вложение и перезапуск") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let session = WorkspaceSession(store: ws, name: "A")
            let folder = try await session.createFolder(parent: nil, title: "Новая папка")
            check(folder.isFolder, "признак папки")
            let inner = try await session.createPage(parent: folder.id, title: "Внутри")
            let nested = try await session.createFolder(parent: folder.id, title: "Вложенная")
            try await session.close()
            let re = try SQLiteWorkspace.open(at: w)
            let pages = try await re.allPages()
            check(pages.first { $0.id == folder.id }?.isFolder == true, "значок сохранён")
            check(pages.first { $0.id == nested.id }?.isFolder == true, "вложенная папка")
            check(pages.first { $0.id == inner.id }?.isFolder == false, "обычная страница не папка")
            checkEqual(pages.first { $0.id == inner.id }?.parentID, folder.id)
            re.close()
        }
    }
}

func runRangeTests() async {
    let page = UUID()
    let a = UUID(), b = UUID(), c = UUID(), u = UUID(), d = UUID()
    func sample() -> BlockDocument {
        BlockDocument(pageID: page, blocks: [
            Block(id: a, pageID: page, sortKey: "a0", type: .heading1, content: BlockContent(runs: [TextRun("Заголовок")]), createdAt: 1),
            Block(id: b, pageID: page, sortKey: "a1", type: .task, content: BlockContent(runs: [TextRun("Ёлка 🎄 "), TextRun("жирно", marks: ["b"])], checked: true), createdAt: 1),
            Block(id: c, pageID: page, sortKey: "a2", content: BlockContent(text: "Абзац три"), createdAt: 1),
            Block(id: u, pageID: page, parentID: nil, sortKey: "a3", type: BlockType(rawValue: "table"), contentVersion: 1, contentJSON: #"{"rows":1}"#, plainText: "ячейка", createdAt: 1, updatedAt: 1),
            Block(id: d, pageID: page, sortKey: "a4", content: BlockContent(text: "Конец"), createdAt: 1),
        ])
    }
    func range(_ x: UUID, _ i: Int, _ y: UUID, _ j: Int) -> BlockSelection {
        var s = BlockSelection(block: x, offset: i)
        s.focus = BlockPoint(blockID: y, offset: j)
        return s
    }
    func texts(_ doc: BlockDocument) -> [String] { doc.blocks.map(\.plainText) }
    func apply(_ s: BlockSelection, _ f: [BlockFragment], on doc: BlockDocument, file: StaticString = #fileID, line: UInt = #line) throws -> EditResult {
        let r = try BlockEditing.apply(.replaceRange(s, f), to: doc, ids: SeqIDs(), now: 5)
        var back = r.document
        back.apply(r.inverse)
        checkEqual(back, doc, "обратимость", file: file, line: line)
        return r
    }

    await test("replaceRange: удаление через блоки объединяет края и отменяется целиком") {
        let doc = sample()
        let r = try apply(range(a, 3, c, 5), [], on: doc)
        checkEqual(texts(r.document), ["Заг три", "ячейка", "Конец"])
        checkEqual(r.document.blocks[0].type, .heading1, "тип первого блока сохраняется")
        checkEqual(r.selection, BlockSelection(block: a, offset: 3))
        let reversed = try apply(range(c, 5, a, 3), [], on: doc)
        checkEqual(texts(reversed.document), ["Заг три", "ячейка", "Конец"], "направление выделения не важно")
    }

    await test("replaceRange: ввод вместо выделения и многострочная вставка") {
        let doc = sample()
        let typed = try apply(range(a, 3, c, 5), BlockFragment.lines("ё"), on: doc)
        checkEqual(texts(typed.document)[0], "Загё три")
        checkEqual(typed.selection, BlockSelection(block: a, offset: 4), "курсор после вставки")
        let multi = try apply(BlockSelection(block: c, offset: 2), BlockFragment.lines("раз\nдва\nтри"), on: doc)
        checkEqual(Array(texts(multi.document)[2...4]), ["Абраз", "два", "тризац три"])
        checkEqual(multi.selection?.anchor.offset, 3, "курсор в начале хвоста последней строки")
        let keys = multi.document.blocks.map(\.sortKey)
        checkEqual(keys, keys.sorted(), "порядок ключей")
        checkEqual(multi.document.blocks.last?.id, d)
    }

    await test("replaceRange: собственный формат сохраняет типы, отметки и метки") {
        let doc = sample()
        let copied = doc.fragments(in: range(a, 3, c, 5))
        checkEqual(copied.map(\.plain), ["оловок", "Ёлка 🎄 жирно", "Абзац"], "границы обрезаны")
        checkEqual(copied[1].type, BlockType.task.rawValue)
        check(copied[1].content?.checked == true, "отметка в копии")
        check(copied[1].content?.runs.contains { $0.marks == ["b"] } == true, "метки в копии")
        checkEqual(BlockFragment.plainText(copied), "оловок\nЁлка 🎄 жирно\nАбзац")
        let pasted = try apply(BlockSelection(block: d, offset: 5), copied, on: doc)
        checkEqual(texts(pasted.document).suffix(3).map { $0 }, ["Конецоловок", "Ёлка 🎄 жирно", "Абзац"])
        checkEqual(pasted.document.blocks[pasted.document.blocks.count - 2].type, .task)
        let ids = pasted.document.blocks.map(\.id)
        checkEqual(Set(ids).count, ids.count, "новые UUID")
        let empty = BlockDocument(pageID: page, blocks: [Block(id: a, pageID: page, sortKey: "a0", createdAt: 1)])
        let intoEmpty = try apply(BlockSelection(block: a, offset: 0), [copied[1]], on: empty)
        checkEqual(intoEmpty.document.blocks[0].plainText, "Ёлка 🎄 жирно")
        let one = try apply(BlockSelection(block: a, offset: 0), [BlockFragment(type: .task, content: BlockContent(text: "x")), BlockFragment(type: .heading2, content: BlockContent(text: "y"))], on: empty)
        checkEqual(one.document.blocks[0].type, .task, "в пустой блок вставка несёт свой тип")
        checkEqual(one.document.blocks[1].type, .heading2)
    }

    await test("replaceRange: непонятный блок не теряется случайно") {
        let doc = sample()
        let covered = try apply(range(c, 1, d, 1), [], on: doc)
        checkEqual(texts(covered.document), ["Заголовок", "Ёлка 🎄 жирно", "Аонец"], "покрытый целиком удаляется вместе с выделением")
        let copied = doc.fragments(in: range(c, 1, d, 1))
        check(copied[1].content == nil, "копия хранит непрозрачный блок")
        checkEqual(copied[1].json, #"{"rows":1}"#, "исходная строка")
        let pasted = try apply(BlockSelection(block: a, offset: 9), copied, on: doc)
        check(pasted.document.blocks.contains { $0.type.rawValue == "table" && (try? $0.contentJSON()) == #"{"rows":1}"# && $0.id != u }, "вставлен копией без потерь")
        let keep = try BlockEditing.apply(.replaceRange(BlockSelection(block: u, offset: 1), []), to: doc, ids: SeqIDs(), now: 1)
        check(keep.changes.isEmpty, "пустая правка с курсором на блоке ничего не меняет")
        let typed = try apply(BlockSelection(block: u, offset: 1), BlockFragment.lines("новый"), on: doc)
        check(typed.document.block(u) != nil, "ввод рядом с блоком его не удаляет")
        check(texts(typed.document).contains("новый"), "текст стал новым блоком")
        let itself = try apply(range(u, 0, u, 1), [], on: doc)
        check(itself.document.block(u) == nil, "выделенный блок удаляется")
    }

    await test("replaceRange: всё удалено — остаётся пустой абзац; потомки не теряются") {
        let doc = sample()
        let all = try apply(range(a, 0, d, 5), [], on: doc)
        checkEqual(texts(all.document), [""], "поле для ввода осталось")
        let p = UUID(), kid = UUID(), x = UUID()
        let nested = BlockDocument(pageID: page, blocks: [
            Block(id: x, pageID: page, sortKey: "a0", content: BlockContent(text: "начало"), createdAt: 1),
            Block(id: p, pageID: page, sortKey: "a1", content: BlockContent(text: "родитель"), createdAt: 1),
            Block(id: kid, pageID: page, parentID: p, sortKey: "a0", content: BlockContent(text: "дочерний"), createdAt: 1),
        ])
        let m = try apply(range(x, 6, p, 8), [], on: nested)
        checkEqual(texts(m.document), ["начало", "дочерний"], "дочерний блок сохранён")
        checkEqual(m.document.block(kid)?.parentID, x, "и получил нового родителя")
    }

    await test("Enter в начале заголовка сохраняет заголовок") {
        let doc = sample()
        let r = try BlockEditing.apply(.splitBlock(BlockPoint(blockID: a, offset: 0)), to: doc, ids: SeqIDs(), now: 1)
        checkEqual(r.document.blocks[0].type, .paragraph)
        checkEqual(r.document.blocks[0].plainText, "")
        checkEqual(r.document.blocks[1].type, .heading1)
        checkEqual(r.document.blocks[1].plainText, "Заголовок")
        var back = r.document
        back.apply(r.inverse)
        checkEqual(back, doc, "обратимость")
    }
}

func runImportTests() async {
    await test("Импорт Markdown: заголовки, задачи, абзацы, встроенная разметка") {
        let f = MarkdownImport.fragments(from: "# Заголовок\r\n\nТекст **жирный** и *курсив*\nвторая строка\n\n- [ ] Дело\n- [x] Сделано\n## Два\nбез `кода конца и ~~зач~~")
        checkEqual(f.map(\.type), ["heading1", "paragraph", "task", "task", "heading2", "paragraph"])
        checkEqual(f[1].plain, "Текст жирный и курсив\nвторая строка")
        check(f[1].content?.runs.contains { $0.text == "жирный" && $0.marks == ["b"] } == true, "жирный")
        check(f[1].content?.runs.contains { $0.text == "курсив" && $0.marks == ["i"] } == true, "курсив")
        checkEqual(f[3].content?.checked, true)
        checkEqual(f[5].plain, "без `кода конца и зач", "незакрытая разметка остаётся текстом")
    }
}
