import Foundation

/// Хранилище-обёртка: отказ записи включается флагом, остальное делегируется настоящей базе во временной папке.
final class FlakyStore: WorkspaceStore {
    let inner: SQLiteWorkspace
    var failCommits = false
    init(_ inner: SQLiteWorkspace) { self.inner = inner }
    func commit(_ batch: SaveBatch) async throws {
        if failCommits { throw WorkspaceError.diskFull }
        try await inner.commit(batch)
    }
    func workspaceID() async throws -> UUID { try await inner.workspaceID() }
    func allPages() async throws -> [Page] { try await inner.allPages() }
    func page(_ id: UUID) async throws -> Page? { try await inner.page(id) }
    func createPage(parent: UUID?, title: String, id: UUID, now: Int64) async throws -> Page { try await inner.createPage(parent: parent, title: title, id: id, now: now) }
    func updatePage(_ page: Page) async throws { try await inner.updatePage(page) }
    func movePage(_ id: UUID, toParent parent: UUID?, afterSibling: UUID?, now: Int64) async throws { try await inner.movePage(id, toParent: parent, afterSibling: afterSibling, now: now) }
    func blocks(ofPage id: UUID) async throws -> [Block] { try await inner.blocks(ofPage: id) }
    func trashPage(_ id: UUID, batch: UUID, now: Int64) async throws { try await inner.trashPage(id, batch: batch, now: now) }
    func trashItems() async throws -> [TrashItem] { try await inner.trashItems() }
    func restoreTrash(batch: UUID) async throws -> Bool { try await inner.restoreTrash(batch: batch) }
    func purgeTrash(batch: UUID) async throws { try await inner.purgeTrash(batch: batch) }
    func markOpened(_ id: UUID, now: Int64) async throws { try await inner.markOpened(id, now: now) }
    func saveRevision(pageID: UUID, reason: String, blocks: [Block], id: UUID, now: Int64) async throws -> Revision? { try await inner.saveRevision(pageID: pageID, reason: reason, blocks: blocks, id: id, now: now) }
    func revisions(ofPage id: UUID) async throws -> [Revision] { try await inner.revisions(ofPage: id) }
    func revisionBlocks(_ revisionID: UUID) async throws -> [Block] { try await inner.revisionBlocks(revisionID) }
    func pruneRevisions(pageID: UUID, keeping: Set<UUID>) async throws { try await inner.pruneRevisions(pageID: pageID, keeping: keeping) }
    func close() { inner.close() }
}

private func titles(_ ws: SQLiteWorkspace, parent: UUID? = nil) async throws -> [String] {
    try await ws.allPages().filter { $0.parentID == parent }.map(\.title)
}

@MainActor
func runGapTests() async {
    await test("Пробелы: movePage задаёт положение через afterSibling") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            var id: [String: UUID] = [:]
            for t in ["A", "B", "C"] {
                id[t] = UUID()
                _ = try await ws.createPage(parent: nil, title: t, id: id[t]!, now: 1)
            }
            try await ws.movePage(id["C"]!, toParent: nil, afterSibling: id["A"]!, now: 2)
            checkEqual(try await titles(ws), ["A", "C", "B"], "после A")
            try await ws.movePage(id["B"]!, toParent: nil, afterSibling: nil, now: 3)
            checkEqual(try await titles(ws), ["B", "A", "C"], "без соседа — в начало")
            try await ws.movePage(id["B"]!, toParent: nil, afterSibling: id["C"]!, now: 4)
            checkEqual(try await titles(ws), ["A", "C", "B"], "после последнего")
            try await ws.movePage(id["A"]!, toParent: id["C"]!, afterSibling: nil, now: 5)
            checkEqual(try await titles(ws), ["C", "B"])
            checkEqual(try await titles(ws, parent: id["C"]!), ["A"], "вложена в C")
            let ghost = UUID()
            let e1 = await checkThrows("соседа из другого родителя") { try await ws.movePage(id["B"]!, toParent: nil, afterSibling: id["A"]!, now: 6) }
            expectError(e1, .pageNotFound(id["A"]!))
            let e2 = await checkThrows("несуществующий сосед") { try await ws.movePage(id["B"]!, toParent: nil, afterSibling: ghost, now: 6) }
            expectError(e2, .pageNotFound(ghost))
            checkEqual(try await titles(ws), ["C", "B"], "отказ не меняет порядок")
            ws.close()
        }
    }

    await test("Пробелы: многократная вставка в одну точку перенумеровывает ключи, порядок переживает перезапуск") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let first = UUID()
            _ = try await ws.createPage(parent: nil, title: "X", id: first, now: 1)
            _ = try await ws.createPage(parent: nil, title: "Y", id: UUID(), now: 1)
            let n = 300
            for i in 1...n {
                let p = try await ws.createPage(parent: nil, title: "p\(i)", id: UUID(), now: 2)
                try await ws.movePage(p.id, toParent: nil, afterSibling: first, now: 3)
            }
            var expected = ["X"] + (1...n).reversed().map { "p\($0)" } + ["Y"]
            let pages = try await ws.allPages()
            checkEqual(pages.map(\.title), expected, "порядок вставок в одну точку")
            check(pages.allSatisfy { $0.sortKey.utf8.count <= SortKey.maxLength }, "ни один ключ не длиннее предела: \(pages.map { $0.sortKey.utf8.count }.max() ?? 0)")
            check(pages.allSatisfy { SortKey.isValid($0.sortKey) }, "ключи корректны")
            checkEqual(Set(pages.map(\.sortKey)).count, pages.count, "после перенумерации ключи различны")
            ws.close()
            let again = try SQLiteWorkspace.open(at: w)
            checkEqual(try await again.allPages().map(\.title), expected, "порядок после перезапуска")
            let tail = try await again.allPages().last!
            try await again.movePage(tail.id, toParent: nil, afterSibling: nil, now: 9)
            expected = ["Y"] + expected.dropLast()
            checkEqual(try await again.allPages().map(\.title), expected, "перемещение после перезапуска")
            again.close()
        }
    }

    await test("Пробелы: переименование переживает close/open и входит в статус") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let clock = FakeClock(), scheduler = ManualScheduler(clock: clock)
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let session = WorkspaceSession(store: ws, name: "A", scheduler: scheduler, clock: clock, ids: RandomIDs())
            let p = try await session.createPage(parent: nil, title: "Старое")
            checkEqual(session.coordinator.status, .saved)
            session.rename(p.id, title: "Новое ё 🎄")
            checkEqual(session.coordinator.status, .saving, "переименование — несохранённая правка")
            checkEqual(session.pages.first?.title, "Новое ё 🎄", "в модели сразу")
            try await session.close()
            checkEqual(session.coordinator.status, .saved)
            let reopened = try SQLiteWorkspace.open(at: w)
            checkEqual(try await reopened.page(p.id)?.title, "Новое ё 🎄", "заголовок записан")
            reopened.close()
        }
    }

    await test("Пробелы: подстраница под несуществующим родителем отклоняется") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let session = WorkspaceSession(store: ws, name: "A")
            let ghost = UUID()
            expectError(await checkThrows { try await session.createPage(parent: ghost, title: "x") }, .pageNotFound(ghost))
            checkEqual(session.pages.count, 0, "страница не создана")
            checkEqual(try await ws.allPages().count, 0)
            try await session.close()
        }
    }

    await test("Пробелы: emergencyText содержит несохранённую правку при отказе записи") {
        try await withTempDir { dir in
            let clock = FakeClock(), scheduler = ManualScheduler(clock: clock)
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let store = FlakyStore(ws)
            let session = WorkspaceSession(store: store, name: "A", scheduler: scheduler, clock: clock, ids: RandomIDs())
            let p = try await session.createPage(parent: nil, title: "Заметка")
            let e = try await session.open(p.id)
            let first = e.document.blocks[0].id
            try await session.coordinator.flush()
            store.failCommits = true
            try e.perform(.setPlainText(block: first, text: "Несохранённое ёлка"))
            try e.perform(.insertBlock(after: first, type: .task))
            await scheduler.advance(500)
            if case .failed = session.coordinator.status { check(true) } else { check(false, "ожидалась ошибка записи: \(session.coordinator.status)") }
            let text = e.emergencyText(title: "Заметка")
            check(text.contains("Несохранённое ёлка"), "правка в аварийном тексте")
            check(text.hasPrefix("# Заметка\n"), "заголовок")
            check(text.contains("- [ ] "), "задача")
            let stored = try await ws.blocks(ofPage: p.id)
            check(!stored.contains { $0.plainText == "Несохранённое ёлка" }, "в базе правки нет")
            store.failCommits = false
            try await session.coordinator.flush()
            let after = try await ws.blocks(ofPage: p.id)
            check(after.contains { $0.plainText == "Несохранённое ёлка" }, "после восстановления записи правка доходит")
            try await session.close()
        }
    }

    await test("Пробелы: повторное открытие после undo/redo видит подтверждённое состояние") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let session = WorkspaceSession(store: ws, name: "A")
            let p = try await session.createPage(parent: nil, title: "A")
            let e = try await session.open(p.id)
            let first = e.document.blocks[0].id
            try e.perform(.setPlainText(block: first, text: "Один"))
            try e.perform(.insertBlock(after: first, type: .paragraph))
            e.undoStep()
            let e2 = try await session.open(p.id)
            checkEqual(e2.document.blocks.map(\.plainText), ["Один"], "после undo")
            checkEqual(try await ws.blocks(ofPage: p.id).map(\.plainText), ["Один"], "в базе то же")
            check(!e2.canUndo && !e2.canRedo, "история нового сеанса пуста")
            e2.undoStep()
            try e2.perform(.setPlainText(block: first, text: "Два"))
            e2.undoStep()
            e2.redoStep()
            let e3 = try await session.open(p.id)
            checkEqual(e3.document.blocks.map(\.plainText), ["Два"], "после undo/redo")
            checkEqual(e3.document, e2.document)
            try await session.close()
        }
    }

    await test("Пробелы: блок с недоступным родителем виден в корне, descendants при удалении") {
        let page = UUID(), root = UUID(), mid = UUID(), leaf = UUID(), orphan = UUID(), orphanChild = UUID(), tail = UUID()
        func blk(_ id: UUID, _ parent: UUID?, _ key: String) -> Block {
            Block(id: id, pageID: page, parentID: parent, sortKey: key, content: BlockContent(text: key), createdAt: 1)
        }
        let doc = BlockDocument(pageID: page, blocks: [
            blk(leaf, mid, "c0"), blk(tail, nil, "z0"), blk(orphanChild, orphan, "o0"), blk(mid, root, "b0"), blk(root, nil, "a0"), blk(orphan, UUID(), "m0"),
        ])
        checkEqual(doc.blocks.map(\.id), [root, mid, leaf, orphan, orphanChild, tail], "порядок обхода в глубину, сирота в корне")
        check(doc.blocks.contains { $0.id == orphan }, "блок не потерян")
        checkEqual(doc.descendants(of: root).map(\.id), [mid, leaf])
        checkEqual(doc.descendants(of: leaf).count, 0)
        checkEqual(doc.descendants(of: UUID()).count, 0, "неизвестный id")

        let r = try BlockEditing.apply(.deleteBlock(root), to: doc, ids: SeqIDs(), now: 5)
        checkEqual(r.document.blocks.map(\.id), [orphan, orphanChild, tail], "удалены корень и вложенные")
        checkEqual(r.changes.count, 3)
        var back = r.document
        back.apply(r.inverse)
        checkEqual(back, doc, "обратимость удаления поддерева")

        var d = doc
        d.apply([.delete(mid)])
        checkEqual(d.blocks.map(\.id), [root, leaf, orphan, orphanChild, tail], "потомок удалённого родителя остаётся в корне")
        check(d.descendants(of: root).isEmpty, "у корня потомков нет")
        await checkThrows("удаление несуществующего") { try BlockEditing.apply(.deleteBlock(UUID()), to: doc, ids: SeqIDs(), now: 1) }
    }

    await test("Пробелы: RichText.diff и replace на ё, комбинируемых знаках и emoji") {
        func applyDiff(_ old: String, _ new: String) -> String {
            guard let d = RichText.diff(old: old, new: new) else { return old }
            return RichText.plain(RichText.replace([TextRun(old)], range: d.range, with: d.text))
        }
        let pairs: [(String, String)] = [
            ("е", "е\u{0301}"), ("e", "e\u{0301}"), ("ёж", "ежж"), ("ёлка", "ёлки"), ("a👍b", "a👍🏽b"),
            ("a🎄b", "a🎅b"), ("👨‍👩‍👧", "👨‍👩‍👧‍👦"), ("🇷🇺", "🇷🇺🇺🇸"), ("x", "x🎄"), ("🎄x", "x"), ("", "ё"), ("ё", ""),
        ]
        for (o, n) in pairs { checkEqual(applyDiff(o, n), n, "diff+replace \(o.unicodeScalars.count)->\(n.unicodeScalars.count)") }
        check(RichText.diff(old: "ёлка 🎄", new: "ёлка 🎄") == nil, "равные строки — nil")

        let d1 = RichText.diff(old: "е", new: "е\u{0301}")
        checkEqual(d1?.range, 0..<1, "комбинируемый знак меняет весь символ")
        checkEqual(d1?.text, "е\u{0301}")
        let d2 = RichText.diff(old: "a👍b", new: "a👍🏽b")
        checkEqual(d2?.range, 1..<3, "диапазон в UTF-16: emoji — 2 единицы")
        checkEqual(d2?.text, "👍🏽")
        let d3 = RichText.diff(old: "ё🎄", new: "ё")
        checkEqual(d3?.range, 1..<3)
        checkEqual(d3?.text, "")
        let d4 = RichText.diff(old: "ёж", new: "ёёж")
        checkEqual(d4?.text.utf16.count, 1, "вставка одного символа")

        // replace: смещение внутри суррогатной пары и перед комбинируемым знаком сдвигается к началу символа.
        let runs = [TextRun("a"), TextRun("🎄", marks: ["b"]), TextRun("е\u{0301}z", marks: ["i"])]
        checkEqual(RichText.plain(RichText.replace(runs, range: 2..<2, with: "Q")), "aQ🎄е\u{0301}z", "вставка внутри emoji")
        checkEqual(RichText.plain(RichText.replace(runs, range: 4..<4, with: "Q")), "a🎄Qе\u{0301}z", "вставка внутри е+U+0301")
        checkEqual(RichText.plain(RichText.replace(runs, range: 1..<3, with: "")), "a\u{0435}\u{0301}z", "удаление целого emoji")
        checkEqual(RichText.plain(RichText.replace(runs, range: 3..<5, with: "")), "a🎄z", "удаление е+U+0301")
        checkEqual(RichText.plain(RichText.replace(runs, range: -5..<100, with: "ё")), "ё", "границы за пределами текста")
        for off in 0...RichText.length(runs) + 1 {
            let (l, r) = RichText.split(runs, at: off)
            checkEqual(RichText.plain(l + r), RichText.plain(runs), "split без потерь на \(off)")
            check(RichText.snap(RichText.plain(runs), off) <= off, "snap не позже смещения \(off)")
        }
        let marked = RichText.replace(runs, range: 3..<3, with: "Q")
        checkEqual(marked.first { $0.text.contains("Q") }?.marks, ["b"], "вставка наследует метки слева")
    }
}
