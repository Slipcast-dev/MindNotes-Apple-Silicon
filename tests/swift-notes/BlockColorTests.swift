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
