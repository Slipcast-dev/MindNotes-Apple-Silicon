import AppKit

/// M12: цвет блока — текст или фон на весь блок, как в Notion.
@MainActor
func runBlockColorTests() async {
    await test("Цвет блока: допустимые значения и хранение в поле, которое старые версии не теряют") {
        checkEqual(BlockColor.valid("red"), "red")
        checkEqual(BlockColor.valid("blue_background"), "blue_background")
        checkEqual(BlockColor.valid("magenta"), nil, "незнакомое имя не принимается")
        checkEqual(BlockColor.valid("red_background_background"), nil)
        checkEqual(BlockColor.names.count, 9, "девять цветов и «по умолчанию» — десять вариантов, как в Notion")
        var content = BlockContent(text: "Важно")
        content.color = "yellow_background"
        let json = try content.jsonString()
        check(json.contains(#""color":"yellow_background""#))
        checkEqual(BlockContent(json: json)?.color, "yellow_background", "читается обратно")
        content.color = "nonsense"
        checkEqual(content.color, nil, "незнакомое значение снимает цвет, а не записывается")
        checkEqual(BlockContent(json: #"{"runs":[],"color":"violet"}"#)?.color, nil, "чужое значение из файла не показывается")
    }

    await test("Цвет блока: команда, отмена, несколько блоков, сохранение и экспорт") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "первый"), (.bullet, "второй"), (.paragraph, "третий")])
            r.select(0, 1, 1, 2)
            r.controller.run(.blockColor("red_background"))
            checkEqual(r.doc.blocks.map { $0.content?.color }, ["red_background", "red_background", nil], "выделение через два блока")
            checkEqual(r.doc.blocks.map { $0.content?.plainText }, ["первый", "второй", "третий"], "текст не тронут")
            r.checkSync("после цвета")
            r.tv.undo(nil)
            checkEqual(r.doc.blocks.map { $0.content?.color }, [nil, nil, nil], "одна отмена снимает цвет со всех")
            r.caret(2, 0)
            r.controller.run(.blockColor("green"))
            checkEqual(r.doc.blocks[2].content?.color, "green")
            let text = r.controller.textView.textStorage!
            let ink = text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? NSColor
            checkEqual(ink, BlockTextStyle.text(of: "green"), "текст блока окрашен")
            r.controller.run(.blockColor(nil))
            checkEqual(r.doc.blocks[2].content?.color, nil, "«По умолчанию» снимает цвет")
            r.controller.run(.blockColor("blue"))
            try await r.session.coordinator.flush()
            let stored = try await r.ws.blocks(ofPage: r.editor.pageID)
            checkEqual(stored.first { $0.plainText == "третий" }?.content?.color, "blue", "цвет записан в хранилище")
            let md = MarkdownExport.export(title: "Т", blocks: r.doc.blocks, assetFolder: "f") { _ in nil }
            check(md.report.contains { $0.reason == "Цвет блоков" && $0.count == 1 }, "экспорт отмечает потерю цвета в отчёте")
            try await r.close()
        }
    }
}

/// Двойной щелчок по заголовку окна: правило по настройке macOS и полоса заголовка.
func runTitlebarGestureTests() async {
    await test("Окно: двойной щелчок по заголовку разворачивает его, как настроено в macOS") {
        checkEqual(TitlebarGesture.action(preference: nil, legacyMinimize: false), .zoom, "по умолчанию — развернуть")
        checkEqual(TitlebarGesture.action(preference: "Maximize", legacyMinimize: false), .zoom)
        checkEqual(TitlebarGesture.action(preference: "Fill", legacyMinimize: false), .zoom)
        checkEqual(TitlebarGesture.action(preference: "Minimize", legacyMinimize: false), .minimize)
        checkEqual(TitlebarGesture.action(preference: "None", legacyMinimize: false), .none)
        checkEqual(TitlebarGesture.action(preference: nil, legacyMinimize: true), .minimize, "старая настройка «свернуть»")
        check(TitlebarGesture.isTitlebar(x: 400, y: 790, windowWidth: 1200, contentTop: 748), "полоса заголовка")
        check(!TitlebarGesture.isTitlebar(x: 400, y: 700, windowWidth: 1200, contentTop: 748), "содержимое — нет")
        check(!TitlebarGesture.isTitlebar(x: 1180, y: 790, windowWidth: 1200, contentTop: 748), "кнопка темы справа — нет")
    }
}

/// Своё название раздела «Страницы» хранится в пространстве: у другого — своё или стандартное.
func runPagesTitleTests() async {
    await test("Раздел страниц: название у каждого пространства своё и переживает переоткрытие") {
        try await withTempDir { dir in
            let key = "ui.pagesSectionTitle"
            let a = try SQLiteWorkspace.create(at: dir.appendingPathComponent("a"), name: "A")
            let b = try SQLiteWorkspace.create(at: dir.appendingPathComponent("b"), name: "B")
            try await a.setMeta(key, "Мои заметки")
            checkEqual(try await b.meta(key), nil, "у другого пространства — стандартное")
            a.close()
            let again = try SQLiteWorkspace.open(at: dir.appendingPathComponent("a"))
            checkEqual(try await again.meta(key), "Мои заметки", "после переоткрытия — своё")
            try await again.setMeta(key, "")
            checkEqual(try await again.meta(key), "", "пустое значение — вернуть «Страницы»")
            again.close()
            b.close()
        }
    }
}

/// Свои разделы боковой панели (схема v9).
func runSectionTests() async {
    await test("Разделы: создание, переименование, порядок, страницы, удаление без потери страниц") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let work = try await w.addSection(name: "  Работа ", id: UUID(), now: 1)
            let home = try await w.addSection(name: "Личное", id: UUID(), now: 2)
            checkEqual(work.name, "Работа", "пробелы сняты")
            await checkThrows("пустое имя") { try await w.addSection(name: "   ", id: UUID(), now: 3) }
            checkEqual(try await w.sections().map(\.name), ["Работа", "Личное"], "порядок добавления")
            try await w.moveSection(home.id, after: nil)
            checkEqual(try await w.sections().map(\.name), ["Личное", "Работа"], "раздел поднят первым")
            try await w.moveSection(home.id, after: work.id)
            checkEqual(try await w.sections().map(\.name), ["Работа", "Личное"])
            try await w.renameSection(work.id, to: "Проекты")
            let page = try await w.createPage(parent: nil, title: "План", id: UUID(), now: 4)
            try await w.setSection(page: page.id, section: work.id)
            checkEqual(try await w.sectionMembers()[page.id], work.id)
            try await w.setSection(page: page.id, section: UUID())
            checkEqual(try await w.sectionMembers()[page.id], nil, "несуществующий раздел — стандартный")
            try await w.setSection(page: page.id, section: home.id)
            try await w.deleteSection(home.id)
            checkEqual(try await w.sectionMembers()[page.id], nil, "страница удалённого раздела — в стандартном")
            let alive = try await w.page(page.id)
            check(alive != nil, "сама страница цела")
            checkEqual(try await w.sections().map(\.name), ["Проекты"])
            try await w.setSection(page: page.id, section: work.id)
            let batch = UUID()
            try await w.trashPage(page.id, batch: batch, now: 5)
            checkEqual(try await w.sectionMembers()[page.id], work.id, "в корзине раздел помнится — восстановится на место")
            try await w.purgeTrash(batch: batch)
            checkEqual(try await w.sectionMembers()[page.id], nil, "удалённая навсегда страница уходит из раздела")
        }
    }
}
