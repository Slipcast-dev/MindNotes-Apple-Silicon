import Foundation

/// M13, шаг 2 (ADR-0013): модель колонок — ряд, колонки, доли ширины, распускание.
func runColumnsTests() async {
    func doc(_ texts: [String]) -> (BlockDocument, [UUID]) {
        let page = UUID()
        let keys = SortKey.keys(after: nil, before: nil, count: texts.count)
        let blocks = zip(texts, keys).map { Block(id: UUID(), pageID: page, sortKey: $1, content: BlockContent(text: $0), createdAt: 1) }
        return (BlockDocument(pageID: page, blocks: blocks), blocks.map(\.id))
    }
    func apply(_ c: EditCommand, _ d: BlockDocument) throws -> BlockDocument { try BlockEditing.apply(c, to: d, ids: RandomIDs(), now: 2).document }
    func columns(_ d: BlockDocument) -> [[String]] {
        guard let row = d.blocks.first(where: { $0.type == .columnList }) else { return [] }
        return d.blocks.filter { $0.parentID == row.id && $0.type == .column }.map { c in d.blocks.filter { $0.parentID == c.id }.map(\.plainText) }
    }

    await test("Колонки: ряд из двух, третья колонка, доли, пределы") {
        var (d, ids) = doc(["А", "Б", "В", "Г", "Д", "Е", "Ж"])
        d = try apply(.makeColumns(target: ids[0], dropped: ids[1], left: false), d)
        checkEqual(columns(d), [["А"], ["Б"]], "Б справа от А")
        checkEqual(d.blocks.first?.type, .columnList, "ряд встал на место А")
        let row = d.blocks.first { $0.type == .columnList }!.id
        checkEqual(d.blocks.filter { $0.type == .column }.compactMap(AtomData.columnRatio(of:)), [0.5, 0.5])
        d = try apply(.makeColumns(target: ids[0], dropped: ids[2], left: true), d)
        checkEqual(columns(d), [["В"], ["А"], ["Б"]], "В слева от А — новая колонка в том же ряду")
        let thirds = d.blocks.filter { $0.type == .column }.compactMap(AtomData.columnRatio(of:))
        check(thirds.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 }, "ширина поровну: \(thirds)")
        d = try apply(.makeColumns(target: ids[1], dropped: ids[3], left: false), d)
        d = try apply(.makeColumns(target: ids[1], dropped: ids[4], left: false), d)
        checkEqual(columns(d).count, 5)
        let full = try BlockEditing.apply(.makeColumns(target: ids[1], dropped: ids[5], left: false), to: d, ids: RandomIDs(), now: 3)
        check(full.changes.isEmpty, "не больше пяти колонок")
        d = try apply(.setColumnRatios(row, [0.5, 0.01, 0.2, 0.2, 0.09]), d)
        let ratios = d.blocks.filter { $0.type == .column }.compactMap(AtomData.columnRatio(of:))
        check(abs(ratios.reduce(0, +) - 1) < 1e-9 && ratios.allSatisfy { $0 >= 0.09 }, "сумма 1, узкая колонка не меньше предела: \(ratios)")
        let mismatch = try BlockEditing.apply(.setColumnRatios(row, [1]), to: d, ids: RandomIDs(), now: 4)
        check(mismatch.changes.isEmpty, "число долей должно совпадать с числом колонок")
        let selfDrop = try BlockEditing.apply(.makeColumns(target: ids[6], dropped: ids[6], left: true), to: d, ids: RandomIDs(), now: 4)
        check(selfDrop.changes.isEmpty, "блок не встаёт колонкой рядом с собой")
    }

    await test("Колонки: пустые убираются, ряд из одной распускается, экспорт по очереди, отмена") {
        var (d, ids) = doc(["А", "Б", "хвост"])
        let original = d
        let made = try BlockEditing.apply(.makeColumns(target: ids[0], dropped: ids[1], left: false), to: d, ids: RandomIDs(), now: 2)
        d = made.document
        var undone = d
        undone.apply(made.inverse)
        checkEqual(undone.blocks.map(\.plainText), original.blocks.map(\.plainText), "отмена возвращает как было")
        checkEqual(undone.blocks.filter { $0.type == .columnList || $0.type == .column }.count, 0)
        let md = MarkdownExport.export(title: "Т", blocks: d.blocks, assetFolder: "f") { _ in nil }
        check(md.markdown.contains("\nА\n") && md.markdown.contains("\nБ\n") && !md.markdown.contains("    А"), "колонки по очереди, без отступа: \(md.markdown)")
        let row = d.blocks.first { $0.type == .columnList }!.id
        // Б вынесли из колонки: колонка пуста, ряд из одной — распускается, А встаёт на место ряда.
        d = try apply(.moveBlock(ids[1], parent: nil, after: nil), d)
        d = try apply(.tidyColumns(row), d)
        checkEqual(d.blocks.map(\.plainText), ["Б", "А", "хвост"], "ряд распущен, порядок сохранён")
        check(!d.blocks.contains { $0.type == .column || $0.type == .columnList }, "ни ряда, ни колонок")
    }
}
