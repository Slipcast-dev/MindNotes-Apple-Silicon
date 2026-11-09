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
}
