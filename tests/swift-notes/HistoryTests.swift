import Foundation

@MainActor
func runHistoryTests() async {
    await test("История: восстановление версии — снимок до, новая версия после, отмена одним шагом") {
        try await withTempDir { dir in
            let clock = FakeClock(), scheduler = ManualScheduler(clock: clock)
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let session = WorkspaceSession(store: ws, name: "A", scheduler: scheduler, clock: clock, ids: RandomIDs())
            let p = try await session.createPage(parent: nil, title: "Страница")
            let e = try await session.open(p.id)
            let first = e.document.blocks[0].id
            e.perform_(.setPlainText(block: first, text: "Первая версия"))
            e.perform_(.insertBlock(after: first, type: .task))
            try await e.snapshot(reason: "Проверка")
            let old = e.document.blocks.map(\.plainText)
            let firstRevision = try await ws.revisions(ofPage: p.id).first!

            clock.now += 60_000
            e.perform_(.setPlainText(block: first, text: "Вторая версия"))
            e.perform_(.insertBlock(after: first, type: .paragraph))
            let modified = e.document.blocks.map(\.plainText)
            check(modified != old)

            try await e.restore(revisionBlocks: try await ws.revisionBlocks(firstRevision.id), label: "Восстановлено из версии 1")
            checkEqual(e.document.blocks.map(\.plainText), old, "документ вернулся к версии")
            let reasons = try await ws.revisions(ofPage: p.id).map(\.reason)
            checkEqual(Array(reasons.prefix(2)), ["Восстановлено из версии 1", "Перед восстановлением"], "до и после восстановления есть снимки")
            let stored = try await ws.blocks(ofPage: p.id).map(\.plainText)
            checkEqual(stored, old, "восстановленное записано в базу")
            let before = try await ws.revisions(ofPage: p.id)[1]
            checkEqual(try await ws.revisionBlocks(before.id).map(\.plainText), modified, "прежний текст сохранён в истории")

            e.undoStep()
            checkEqual(e.document.blocks.map(\.plainText), modified, "⌘Z возвращает текст до восстановления")
            e.redoStep()
            checkEqual(e.document.blocks.map(\.plainText), old)
            try await session.close()
        }
    }

    await test("История: восстановление той же версии ничего не меняет, пустая версия получает абзац") {
        try await withTempDir { dir in
            let clock = FakeClock(), scheduler = ManualScheduler(clock: clock)
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let session = WorkspaceSession(store: ws, name: "A", scheduler: scheduler, clock: clock, ids: RandomIDs())
            let p = try await session.createPage(parent: nil, title: "Страница")
            let e = try await session.open(p.id)
            e.perform_(.setPlainText(block: e.document.blocks[0].id, text: "Текст"))
            try await e.snapshot(reason: "Проверка")
            let doc = e.document
            let rev = try await ws.revisions(ofPage: p.id).first!
            try await e.restore(revisionBlocks: try await ws.revisionBlocks(rev.id), label: "Восстановлено")
            checkEqual(e.document, doc, "та же версия: документ не меняется")
            check(!e.canRedo)

            try await e.restore(revisionBlocks: [], label: "Пустая")
            checkEqual(e.document.blocks.count, 1, "пустая версия получила абзац")
            checkEqual(e.document.blocks.first?.plainText, "")
            try await session.close()
        }
    }

    await test("История: удержание — сутки целиком, час, день, неделя, самый новый всегда") {
        let h = RevisionRetention.hour, d = RevisionRetention.day
        let now: Int64 = 1000 * d
        var seq = 0
        func rev(_ at: Int64) -> Revision { seq += 1; return Revision(id: UUID(), pageID: UUID(), seq: seq, createdAt: at, reason: "", contentHash: "", byteSize: 0) }
        let recent = [rev(now - 10), rev(now - h), rev(now - 2 * h)]
        let hourA = rev(now - 2 * d - 10 * 60_000 - (now % h)), hourB = rev(hourA.createdAt + 5 * 60_000)
        let dayA = rev(now - 10 * d - (now % d) + 3 * h), dayB = rev(dayA.createdAt + 2 * h)
        let weekA = rev((now - 100 * d) / (7 * d) * (7 * d) + d), weekB = rev(weekA.createdAt + d) // одна неделя
        let kept = RevisionRetention.keep(recent + [hourA, hourB, dayA, dayB, weekA, weekB], now: now)
        check(recent.allSatisfy { kept.contains($0.id) }, "последние сутки целиком")
        check(kept.contains(hourB.id) && !kept.contains(hourA.id), "в часе — новейший")
        check(kept.contains(dayB.id) && !kept.contains(dayA.id), "в дне — новейший")
        check(kept.contains(weekB.id) && !kept.contains(weekA.id), "в неделе — новейший")
        let old = rev(now - 400 * d)
        checkEqual(RevisionRetention.keep([old], now: now), [old.id], "единственный старый снимок остаётся")
        checkEqual(RevisionRetention.keep([], now: now), [])
    }

    await test("История: прореживание в базе удаляет только лишние снимки") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let page = UUID()
            _ = try await ws.createPage(parent: nil, title: "С", id: page, now: 1)
            var ids: [UUID] = []
            for i in 0..<4 {
                let block = Block(id: UUID(), pageID: page, sortKey: "a", content: BlockContent(text: "версия \(i)"), createdAt: 1)
                ids.append(try await ws.saveRevision(pageID: page, reason: "r", blocks: [block], id: UUID(), now: Int64(i + 1))!.id)
            }
            try await ws.pruneRevisions(pageID: page, keeping: [ids[1], ids[3]])
            checkEqual(Set(try await ws.revisions(ofPage: page).map(\.id)), [ids[1], ids[3]])
            try await ws.pruneRevisions(pageID: page, keeping: [])
            checkEqual(try await ws.revisions(ofPage: page).count, 2, "пустой набор ничего не удаляет")
            ws.close()
        }
    }

    await test("Экспорт Markdown: форматирование, списки, вложенность, задачи, таблица, вложение, отчёт") {
        let page = UUID(), other = UUID(), asset = UUID()
        func b(_ type: BlockType, _ runs: [TextRun], parent: UUID? = nil, checked: Bool = false, key: String) -> Block {
            var block = Block(id: UUID(), pageID: page, parentID: parent, sortKey: key, type: type, content: BlockContent(runs: runs, checked: checked), createdAt: 1)
            block.pageID = page
            return block
        }
        let list = b(.bullet, [TextRun("пункт")], key: "a2")
        var blocks = [
            b(.paragraph, [TextRun("Жирный", marks: ["b"]), TextRun(" и "), TextRun("код", marks: ["code"]), TextRun(" 2*3")], key: "a0"),
            b(.heading1, [TextRun("Раздел")], key: "a1"),
            list,
            b(.bullet, [TextRun("вложенный", marks: ["u"])], parent: list.id, key: "a3"),
            b(.numbered, [TextRun("один")], key: "a4"),
            b(.numbered, [TextRun("два")], key: "a5"),
            b(.task, [TextRun("сделано")], checked: true, key: "a6"),
            b(.paragraph, [TextRun("ссылка", marks: [PageLink.mark(other)])], key: "a7"),
        ]
        blocks.append(Block(id: UUID(), pageID: page, parentID: nil, sortKey: "a8", type: .image, contentVersion: 1,
                            contentJSON: "{\"asset\":\"\(asset.uuidString.lowercased())\",\"name\":\"фото/1.png\"}", plainText: "фото", createdAt: 1, updatedAt: 1))
        blocks.append(Block(id: UUID(), pageID: page, parentID: nil, sortKey: "a9", type: .table, contentVersion: 1,
                            contentJSON: AtomData.tableJSON([["А", "Б"], ["1", "2|3"]]), plainText: "", createdAt: 1, updatedAt: 1))
        let r = MarkdownExport.export(title: "Заметка #1", blocks: blocks, assetFolder: "Заметка_files") { $0 == other ? "Другая" : nil }
        let md = r.markdown
        check(md.hasPrefix("# Заметка \\#1\n"), "заголовок страницы экранирован")
        check(md.contains("**Жирный** и `код` 2\\*3"), "форматирование и экранирование: \(md)")
        check(md.contains("\n## Раздел"), "заголовок блока на уровень ниже")
        check(md.contains("- пункт\n    - вложенный"), "вложенность отступом")
        check(md.contains("1. один\n2. два"), "нумерация")
        check(md.contains("- [x] сделано"), "задача")
        check(md.contains("[[Другая]]"), "ссылка на страницу по заголовку")
        check(md.contains("![фото/1.png](<Заметка_files/фото_1.png>)"), "изображение с безопасным именем")
        check(md.contains("| А | Б |\n| --- | --- |\n| 1 | 2\\|3 |"), "таблица")
        checkEqual(r.assets.map(\.id), [asset])
        checkEqual(r.report.map(\.reason), ["Подчёркивание"], "потери в отчёте")
    }
}
