import AppKit

/// M13, шаг 1 (ADR-0013, вариант А): живое представление базы поверх места в тексте.
@MainActor
func runLiveViewTests() async {
    await test("Живое представление: высота в блоке, пределы, прочие поля не теряются") {
        let fragment = AtomData.databaseView(page: UUID(), kind: DatabaseView.tableKind, state: "{}")
        var block = Block(id: UUID(), pageID: UUID(), parentID: nil, sortKey: "a", type: .databaseView, contentVersion: 1,
                          contentJSON: fragment.json, plainText: "", createdAt: 1, updatedAt: 1)
        checkEqual(AtomData.viewHeight(of: block), AtomData.defaultViewHeight, "по умолчанию")
        block = Block(id: block.id, pageID: block.pageID, parentID: nil, sortKey: "a", type: .databaseView, contentVersion: 1,
                      contentJSON: AtomData.withViewHeight(block, 5000), plainText: "", createdAt: 1, updatedAt: 1)
        checkEqual(AtomData.viewHeight(of: block), 900, "не выше предела")
        checkEqual(AtomData.viewPage(of: block), AtomData.viewPage(of: Block(id: UUID(), pageID: UUID(), parentID: nil, sortKey: "a", type: .databaseView,
                                                                             contentVersion: 1, contentJSON: fragment.json, plainText: "", createdAt: 1, updatedAt: 1)),
                   "страница базы сохранилась")
        let low = Block(id: UUID(), pageID: UUID(), parentID: nil, sortKey: "a", type: .databaseView, contentVersion: 1,
                        contentJSON: AtomData.withViewHeight(block, 10), plainText: "", createdAt: 1, updatedAt: 1)
        checkEqual(AtomData.viewHeight(of: low), 200, "не ниже предела")
    }

    await test("Живое представление в редакторе: вид на месте блока, растягивание с отменой, удаление, карточка без вида") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "до"), (.paragraph, "после")])
            var made = 0
            r.controller.liveView = { _ in made += 1; return NSView() }
            r.caret(0, 2)
            r.controller.insertFragments([AtomData.databaseView(page: UUID(), kind: DatabaseView.tableKind, state: "{}")])
            let id = r.doc.blocks.first { $0.type == .databaseView }!.id
            r.controller.layoutLiveViews()
            let hosts = r.tv.subviews.compactMap { $0 as? LiveViewHost }
            checkEqual(hosts.count, 1, "вид поставлен поверх текста")
            checkEqual(made, 1, "вид создан один раз")
            let host = hosts[0]
            checkEqual(host.frame.height, CGFloat(AtomData.defaultViewHeight), "высота из блока")
            check(host.frame.width > 100, "на ширину строки")
            let afterTop = host.frame.maxY
            // Текст «после» стоит ниже вида: место в тексте той же высоты.
            let storage = r.tv.textStorage!
            let tail = (storage.string as NSString).range(of: "после")
            var actual = NSRange()
            let glyphs = r.tv.layoutManager!.glyphRange(forCharacterRange: tail, actualCharacterRange: &actual)
            let below = r.tv.layoutManager!.boundingRect(forGlyphRange: glyphs, in: r.tv.textContainer!).minY + r.tv.textContainerOrigin.y
            check(below >= afterTop - 1, "текст ниже вида не перекрыт: \(below) vs \(afterTop)")

            r.controller.setLiveHeight(id, 520)
            checkEqual(AtomData.viewHeight(of: r.doc.block(id)!), 520)
            checkEqual(host.frame.height, 520, "вид вырос вместе с местом")
            r.tv.undo(nil)
            r.controller.layoutLiveViews()
            checkEqual(AtomData.viewHeight(of: r.doc.block(id)!), AtomData.defaultViewHeight, "⌘Z вернул высоту")

            // Набор выше двигает вид вместе с текстом.
            let before = host.frame.minY
            r.caret(0, 2)
            r.key(#selector(NSResponder.insertNewline(_:)))
            r.type("строка")
            r.controller.layoutLiveViews()
            check(host.frame.minY > before, "вид сдвинулся вниз вместе с текстом")
            checkEqual(made, 1, "правка рядом не пересоздаёт вид")

            r.controller.perform(.deleteBlock(id))
            r.controller.layoutLiveViews()
            check(host.superview == nil, "блок удалён — вид убран")
            r.checkSync("после удаления")

            // Вид не получился (база в корзине): прежняя карточка, без вида поверх.
            r.controller.liveView = { _ in nil }
            r.controller.insertFragments([AtomData.databaseView(page: UUID(), kind: DatabaseView.tableKind, state: "{}")])
            r.controller.layoutLiveViews()
            checkEqual(r.tv.subviews.compactMap { $0 as? LiveViewHost }.count, 0, "без вида — карточка")
            try await r.close()
        }
    }
}
