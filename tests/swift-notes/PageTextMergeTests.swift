import Foundation

/// Перенос правок из Markdown в страницу (ADR-0019, п. 13): меняются только текстовые блоки.
func runPageTextMergeTests() async {
    let page = UUID()
    var counter = 0
    func id() -> UUID { counter += 1; return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))! }
    func text(_ type: BlockType, _ s: String, key: String, parent: UUID? = nil, color: String? = nil) -> Block {
        var extra: [String: JSONValue] = [:]
        if let color { extra["color"] = .string(color) }
        return Block(id: id(), pageID: page, parentID: parent, sortKey: key, type: type, content: BlockContent(runs: [TextRun(s)], extra: extra), createdAt: 1)
    }
    func export(_ blocks: [Block]) -> String {
        MarkdownExport.export(title: "Проект", blocks: BlockDocument(pageID: page, blocks: blocks).blocks, assetFolder: "Проект_files") { _ in nil }.markdown
    }
    func merge(_ blocks: [Block], _ md: String) throws -> PageTextMerge.Result {
        try PageTextMerge.merge(blocks: blocks, pageID: page, markdown: md, now: 99, newID: id)
    }

    await test("Перенос правок: без изменений на GitHub страница не меняется") {
        let blocks = [text(.heading1, "Заголовок", key: "a0"), text(.paragraph, "Абзац", key: "a1", color: "red"),
                      text(.bullet, "Пункт", key: "a2"), text(.numbered, "Шаг", key: "a3"), text(.task, "Дело", key: "a4"),
                      text(.quote, "Цитата", key: "a5")]
        let r = try merge(blocks, export(blocks))
        check(r.isEmpty, "свой же экспорт — ничего не меняется")
        checkEqual(r.blocks, BlockDocument(pageID: page, blocks: blocks).blocks)
    }

    await test("Перенос правок: изменённый абзац — тот же блок, цвет сохранён") {
        let para = text(.paragraph, "Старый текст", key: "a1", color: "red")
        let blocks = [text(.paragraph, "Первый", key: "a0"), para, text(.paragraph, "Последний", key: "a2")]
        let md = export(blocks).replacingOccurrences(of: "Старый текст", with: "Новый **текст**")
        let r = try merge(blocks, md)
        checkEqual(r.changed, 1)
        checkEqual(r.added + r.removed, 0)
        let after = r.blocks.first { $0.id == para.id }
        checkEqual(after?.plainText, "Новый текст")
        checkEqual(after?.content?.extra["color"], .string("red"), "цвет блока остаётся")
        checkEqual(after?.updatedAt, 99)
        checkEqual(r.blocks.map(\.id), BlockDocument(pageID: page, blocks: blocks).blocks.map(\.id), "порядок и id прежние")
    }

    await test("Перенос правок: добавленные и удалённые строки, смена вида блока") {
        let a = text(.paragraph, "Один", key: "a0"), b = text(.paragraph, "Два", key: "a1"), c = text(.paragraph, "Три", key: "a2")
        var md = export([a, b, c])
        md = md.replacingOccurrences(of: "Два\n", with: "")                       // «Два» удалён
        md = md.replacingOccurrences(of: "Три\n", with: "Три\n\n- Новый пункт\n") // пункт добавлен в конец
        md = md.replacingOccurrences(of: "Один\n", with: "## Один\n")             // абзац стал заголовком
        let r = try merge([a, b, c], md)
        checkEqual(r.removed, 1)
        checkEqual(r.added, 1)
        checkEqual(r.changed, 1)
        checkEqual(r.blocks.map(\.plainText), ["Один", "Три", "Новый пункт"])
        checkEqual(r.blocks.first?.id, a.id)
        checkEqual(r.blocks.first?.type, .heading1, "## на GitHub — заголовок 1 в странице")
        checkEqual(r.blocks.last?.type, .bullet)
        check(r.blocks[1].sortKey < r.blocks[2].sortKey, "новый блок после соседа")
    }

    await test("Перенос правок: вставка в начало и между блоками") {
        let a = text(.paragraph, "А", key: "a1"), b = text(.paragraph, "Б", key: "a3")
        let md = "# Проект\n\nНачало\n\nА\n\nСередина\n\nБ\n"
        let r = try merge([a, b], md)
        checkEqual(r.blocks.map(\.plainText), ["Начало", "А", "Середина", "Б"])
        checkEqual(r.added, 2)
    }

    await test("Перенос правок: блоки, которые Markdown не выражает, не удаляются и не меняются") {
        let image = Block(atom: .image, id: id(), pageID: page, parentID: nil, sortKey: "a1", createdAt: 1)
        let toggle = text(.toggle, "Сворачиваемый", key: "a2")
        let inside = text(.paragraph, "Внутри", key: "a0", parent: toggle.id)
        let p = text(.paragraph, "Текст", key: "a3")
        let blocks = [image, toggle, inside, p]
        // На GitHub убрали всё, кроме абзаца, и переписали строку сворачиваемого блока.
        let r = try merge(blocks, "# Проект\n\n- Другое\n\nТекст\n")
        check(r.blocks.contains { $0.id == image.id }, "картинка осталась")
        checkEqual(r.blocks.first { $0.id == toggle.id }?.plainText, "Сворачиваемый", "сворачиваемый блок не тронут")
        checkEqual(r.blocks.first { $0.id == inside.id }?.plainText, "Внутри", "содержимое сворачиваемого не тронуто")
        checkEqual(r.removed, 0)
        check(r.kept >= 2, "убранные строки нетекстовых блоков посчитаны как оставленные")
    }

    await test("Перенос правок: блок с вложенными не удаляется, задачи различают отметку") {
        let parent = text(.bullet, "Родитель", key: "a0")
        let child = text(.bullet, "Ребёнок", key: "a0", parent: parent.id)
        let task = text(.task, "Дело", key: "a1")
        let r = try merge([parent, child, task], "# Проект\n\n- Ребёнок\n- [x] Дело\n")
        check(r.blocks.contains { $0.id == parent.id }, "у блока есть вложенные — не удаляется")
        checkEqual(r.blocks.first { $0.id == task.id }?.content?.checked, true, "отметка задачи перенесена")
    }

    await test("Перенос правок: заголовок страницы и код не путаются с заголовками блоков") {
        let code = Block(id: id(), pageID: page, sortKey: "a0", type: .code, content: BlockContent(text: "## не заголовок"), createdAt: 1)
        let r = try merge([code], export([code]))
        check(r.isEmpty, "строка `##` внутри кода — код, а не заголовок")
        let renamed = try merge([], "# Другое название\n\nТекст\n")
        checkEqual(renamed.blocks.map(\.plainText), ["Текст"], "первая строка `# …` — заголовок страницы, не блок")
    }

    await test("Перенос правок: сравнение по наибольшей общей части") {
        checkEqual(PageTextMerge.align(["a", "b", "c"], ["a", "x", "c"]), [.same(0, 0), .insert(1), .delete(1), .same(2, 2)])
        checkEqual(PageTextMerge.align([], ["a"]), [.insert(0)])
        checkEqual(PageTextMerge.align(["a"], []), [.delete(0)])
    }
}
