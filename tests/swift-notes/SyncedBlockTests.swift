import Foundation

/// M12, ADR-0012: синхронизированный блок — одно содержимое у оригинала, копии правят его же.
@MainActor
func runSyncedBlockTests() async {
    func text(_ blocks: [Block]) -> [String] { blocks.filter { $0.content != nil }.map(\.plainText) }

    await test("Синхронизированный блок: обёртка, копирование копией, отвязка с новыми ID") {
        let page = UUID()
        let a = Block(id: UUID(), pageID: page, sortKey: "a", content: BlockContent(text: "один"), createdAt: 1)
        let b = Block(id: UUID(), pageID: page, sortKey: "b", content: BlockContent(text: "два"), createdAt: 1)
        let c = Block(id: UUID(), pageID: page, sortKey: "c", content: BlockContent(text: "три"), createdAt: 1)
        let doc = BlockDocument(pageID: page, blocks: [a, b, c])
        let wrapped = try BlockEditing.apply(.makeSynced([a.id, b.id]), to: doc, ids: RandomIDs(), now: 2).document
        let container = wrapped.blocks[0]
        checkEqual(container.type, .synced, "оригинал встал на место первого блока")
        checkEqual(wrapped.blocks.filter { $0.parentID == container.id }.map(\.plainText), ["один", "два"], "выделенные блоки внутри")
        checkEqual(wrapped.blocks.last?.plainText, "три", "остальное на месте")
        let mixed = try BlockEditing.apply(.makeSynced([a.id, container.id]), to: wrapped, ids: RandomIDs(), now: 3)
        check(mixed.changes.isEmpty, "блоки разных уровней не оборачиваются")
        // Копирование оригинала даёт копию: второй оригинал не появляется.
        var sel = BlockSelection(block: container.id, offset: 0)
        sel.focus = BlockPoint(blockID: wrapped.blocks[2].id, offset: 3)
        let fragments = wrapped.fragments(in: sel)
        checkEqual(fragments.map(\.type), [BlockType.syncedRef.rawValue], "только копия, без детей оригинала")
        check(fragments.first?.json.contains(container.id.uuidString.lowercased()) == true)

        // Отвязка: дети копии становятся новыми блоками страницы, сама копия уходит.
        let ref = Block(id: UUID(), pageID: page, parentID: nil, sortKey: "d", type: .syncedRef, contentVersion: 1,
                        contentJSON: AtomData.syncedRef(source: container.id).json, plainText: "", createdAt: 1, updatedAt: 1)
        let child = Block(id: UUID(), pageID: UUID(), parentID: ref.id, sortKey: "a", content: BlockContent(text: "чужой"), createdAt: 1)
        let grand = Block(id: UUID(), pageID: child.pageID, parentID: child.id, sortKey: "a", content: BlockContent(text: "внук"), createdAt: 1)
        let withRef = BlockDocument(pageID: page, blocks: [a, ref, child, grand])
        let freed = try BlockEditing.apply(.unsync(ref.id), to: withRef, ids: RandomIDs(), now: 4)
        let out = freed.document
        check(out.block(ref.id) == nil && out.block(child.id) == nil, "копия и показанные блоки ушли из вида")
        let copy = out.blocks.first { $0.plainText == "чужой" }!
        check(copy.id != child.id && copy.pageID == page && copy.parentID == nil, "новый ID, эта страница, место копии")
        checkEqual(out.blocks.first { $0.plainText == "внук" }?.parentID, copy.id, "вложенность сохранена")
    }

    await test("Синхронизированный блок: правка в копии меняет оригинал, перенос через рамку, удаление и отвязка") {
        try await withTempDir { dir in
            let store = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { store.close() }
            let clock = FakeClock()
            let session = WorkspaceSession(store: store, name: "T", scheduler: ManualScheduler(clock: clock), clock: clock, ids: RandomIDs())
            let pageA = try await session.createPage(parent: nil, title: "Оригинал")
            let pageB = try await session.createPage(parent: nil, title: "Копия")

            // Страница A: два абзаца, затем «Сделать синхронизированным».
            var ea = try await session.open(pageA.id)
            let first = ea.document.blocks[0].id
            try ea.perform(.setPlainText(block: first, text: "Общий текст"))
            try ea.perform(.insertBlock(after: first, type: .paragraph))
            let second = ea.document.blocks[1].id
            try ea.perform(.setPlainText(block: second, text: "Вторая строка"))
            try ea.perform(.makeSynced([first, second]))
            let source = ea.document.blocks.first { $0.type == .synced }!.id
            try await session.coordinator.flush()
            try await session.closeEditor()

            // Страница B: вставка копии.
            var eb = try await session.open(pageB.id)
            let anchor = eb.document.blocks[0].id
            try eb.perform(.replaceRange(BlockSelection(block: anchor, offset: 0), [AtomData.syncedRef(source: source)]))
            try await eb.loadSyncedSources()
            let ref = eb.document.blocks.first { $0.type == .syncedRef }!.id
            checkEqual(eb.syncedRefs[ref]?.reason, .shown)
            checkEqual(eb.syncedRefs[ref]?.title, "Оригинал")
            checkEqual(eb.document.blocks.filter { $0.parentID == ref }.map(\.plainText), ["Общий текст", "Вторая строка"], "копия показывает детей оригинала")

            // Правка в копии — правка оригинала.
            try eb.perform(.setPlainText(block: first, text: "Изменено в копии"))
            try eb.perform(.insertBlock(after: second, type: .paragraph))
            let added = eb.document.blocks.first { $0.parentID == ref && $0.id != first && $0.id != second }!.id
            try eb.perform(.setPlainText(block: added, text: "Новый в копии"))
            try await session.coordinator.flush()
            var storedA = try await store.blocks(ofPage: pageA.id)
            checkEqual(storedA.first { $0.id == first }?.plainText, "Изменено в копии", "текст записан на страницу оригинала")
            checkEqual(storedA.first { $0.id == added }?.parentID, source, "новый блок в копии — ребёнок оригинала")
            var storedB = try await store.blocks(ofPage: pageB.id)
            check(!storedB.contains { $0.id == first || $0.id == added }, "на странице копии содержимого оригинала нет")

            // Перенос из рамки наружу: блок переезжает на страницу копии.
            try eb.perform(.outdent(added))
            try await session.coordinator.flush()
            storedB = try await store.blocks(ofPage: pageB.id)
            storedA = try await store.blocks(ofPage: pageA.id)
            check(storedB.contains { $0.id == added && $0.parentID == nil }, "вынесенный блок теперь на странице копии")
            check(!storedA.contains { $0.id == added }, "и ушёл со страницы оригинала")

            // Снимок истории страницы копии — только её блоки.
            try await eb.snapshot(reason: "проверка")
            let revision = try await store.revisions(ofPage: pageB.id).first!
            let snapshot = try await store.revisionBlocks(revision.id)
            check(!snapshot.contains { $0.id == first || $0.id == second }, "снимок без содержимого оригинала")

            // Удаление копии не трогает оригинал; ⌘Z возвращает копию.
            try eb.perform(.deleteBlock(ref))
            try await session.coordinator.flush()
            storedA = try await store.blocks(ofPage: pageA.id)
            checkEqual(Set(storedA.filter { $0.parentID == source }.map(\.plainText)), ["Изменено в копии", "Вторая строка"], "оригинал цел после удаления копии")
            eb.undoStep()
            check(eb.document.block(ref) != nil && eb.document.block(first) != nil, "отмена вернула копию с содержимым")

            // Отвязка: независимые блоки; правка не доходит до оригинала.
            try eb.perform(.unsync(ref))
            try await session.coordinator.flush()
            let freed = eb.document.blocks.first { $0.plainText == "Изменено в копии" }!
            check(freed.id != first, "отвязанная копия — новые блоки")
            try eb.perform(.setPlainText(block: freed.id, text: "Только здесь"))
            try await session.coordinator.flush()
            storedA = try await store.blocks(ofPage: pageA.id)
            checkEqual(storedA.first { $0.id == first }?.plainText, "Изменено в копии", "оригинал не изменился")
            check(storedA.contains { $0.id == source }, "оригинал на месте")
            try await session.closeEditor()

            // Повторное открытие: копий нет, содержимое страницы — своё.
            eb = try await session.open(pageB.id)
            check(eb.syncedRefs.isEmpty)
            check(eb.document.blocks.contains { $0.plainText == "Только здесь" })
            try await session.closeEditor()

            // Копия на странице самого оригинала показывается ссылкой: содержимое не задваивается.
            ea = try await session.open(pageA.id)
            let tail = ea.document.blocks.last!.id
            try ea.perform(.insertBlock(after: tail, type: .paragraph))
            let place = ea.document.blocks.last!.id
            try ea.perform(.replaceRange(BlockSelection(block: place, offset: 0), [AtomData.syncedRef(source: source)]))
            try await ea.loadSyncedSources()
            let selfRef = ea.document.blocks.first { $0.type == .syncedRef }!.id
            checkEqual(ea.syncedRefs[selfRef]?.reason, .samePage)
            checkEqual(Set(ea.document.blocks.map(\.id)).count, ea.document.blocks.count, "ID не повторяются")
            try await session.closeEditor()
        }
    }

    await test("Синхронизированный блок: оригинал в корзине — копия недоступна; экспорт") {
        try await withTempDir { dir in
            let store = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { store.close() }
            let clock = FakeClock()
            let session = WorkspaceSession(store: store, name: "T", scheduler: ManualScheduler(clock: clock), clock: clock, ids: RandomIDs())
            let pageA = try await session.createPage(parent: nil, title: "A")
            let pageB = try await session.createPage(parent: nil, title: "B")
            let ea = try await session.open(pageA.id)
            let first = ea.document.blocks[0].id
            try ea.perform(.setPlainText(block: first, text: "Текст"))
            try ea.perform(.makeSynced([first]))
            let source = ea.document.blocks.first { $0.type == .synced }!.id
            let md = MarkdownExport.export(title: "A", blocks: ea.document.blocks, assetFolder: "f") { _ in nil }
            check(md.markdown.contains("\nТекст") && !md.markdown.contains("    Текст"), "дети оригинала — на его уровне: \(md.markdown)")
            try await session.coordinator.flush()
            try await session.closeEditor()
            try await store.trashPage(pageA.id, batch: UUID(), now: 5)
            let eb = try await session.open(pageB.id)
            try eb.perform(.replaceRange(BlockSelection(block: eb.document.blocks[0].id, offset: 0), [AtomData.syncedRef(source: source)]))
            try await eb.loadSyncedSources()
            let ref = eb.document.blocks.first { $0.type == .syncedRef }!
            checkEqual(eb.syncedRefs[ref.id]?.reason, .unavailable, "оригинал в корзине")
            check(!eb.document.blocks.contains { $0.id == first }, "содержимое не показано")
            let mdB = MarkdownExport.export(title: "B", blocks: eb.document.blocks, assetFolder: "f") { _ in nil }
            check(mdB.report.contains { $0.reason.hasPrefix("Копии синхронизированных блоков") }, "копия отмечена в отчёте экспорта")
            try await session.closeEditor()
        }
    }
}
