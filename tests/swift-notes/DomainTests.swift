import Foundation

func handleChildMode() async -> Bool {
    await handleCrashChild()
}

func runDomainTests() async {
    await test("SortKey: порядок и вставка между соседями") {
        var keys = [SortKey.between(nil, nil)]
        for _ in 0..<2000 { keys.append(SortKey.between(keys.last, nil)) }
        check(keys == keys.sorted(), "append сохраняет порядок")
        check(keys.last!.count < 8, "append почти не удлиняет ключ: \(keys.last!)")
        let first = SortKey.between(nil, keys[0])
        check(first < keys[0], "перед первым")
        var lo = keys[0], hi = keys[1]
        for _ in 0..<1000 {
            let m = SortKey.between(lo, hi)
            check(lo < m && m < hi, "между соседями: \(lo) \(m) \(hi)")
            hi = m
        }
        for _ in 0..<500 {
            let m = SortKey.between(lo, hi)
            check(lo < m && m < hi, "между, сдвиг снизу")
            lo = m
        }
        check(SortKey.isValid(lo), "ключ корректен")
    }

    await test("SortKey: пакет и граничные случаи") {
        let batch = SortKey.keys(after: "a0", before: "a1", count: 50)
        check(batch == batch.sorted() && Set(batch).count == 50, "пакет упорядочен")
        check(batch.allSatisfy { "a0" < $0 && $0 < "a1" }, "пакет внутри диапазона")
        check(!SortKey.between("a5", "a5").isEmpty, "равные ключи не приводят к падению")
        var down = "a0"
        for _ in 0..<100 { let n = SortKey.between(nil, down); check(n < down, "вниз"); down = n }
    }

    await test("RichText: кириллица, emoji и составные символы") {
        let family = "👨‍👩‍👧"
        let runs = [TextRun("Привет "), TextRun(family, marks: ["b"]), TextRun(" мир ё")]
        checkEqual(RichText.plain(runs), "Привет \(family) мир ё")
        let (l, r) = RichText.split(runs, at: 8)
        checkEqual(RichText.plain(l), "Привет ", "разрез внутри emoji сдвигается к началу")
        checkEqual(RichText.plain(r), "\(family) мир ё")
        let e = "e\u{301}x"
        checkEqual(RichText.snap(e, 1), 0, "комбинируемый знак не отделяется")
        let replaced = RichText.replace(runs, range: 0..<6, with: "Пока")
        checkEqual(RichText.plain(replaced), "Пока \(family) мир ё")
        check(replaced.contains { $0.marks == ["b"] }, "метки неизменённой части сохранены")
        let d = RichText.diff(old: "Привет мир", new: "Привет, мир")
        checkEqual(d?.text, ",")
        checkEqual(d?.range, 6..<6)
        check(RichText.diff(old: "а", new: "а") == nil, "нет изменений")
    }

    await test("BlockContent: неизвестные поля и метки переживают запись") {
        let source = #"{"runs":[{"t":"Ёж 🦔","m":["b","future"],"x":7}],"checked":true,"newField":{"a":[1,2.5,null,"я"]}}"#
        let c = BlockContent(json: source)!
        checkEqual(c.plainText, "Ёж 🦔")
        check(c.checked, "отметка")
        checkEqual(c.runs[0].marks, ["b", "future"])
        let round = BlockContent(json: try c.jsonString())!
        checkEqual(round, c, "круговое преобразование")
        checkEqual(round.extra["newField"], .object(["a": .array([.int(1), .double(2.5), .null, .string("я")])]))
    }

    await test("Block: неизвестный тип и более новая версия остаются непрозрачными") {
        let raw = #"{"weird":  [1, 2]}"#
        let id = UUID(), page = UUID()
        let unknown = Block(id: id, pageID: page, parentID: nil, sortKey: "a0", type: BlockType(rawValue: "kanban3d"),
                            contentVersion: 1, contentJSON: raw, plainText: "текст", createdAt: 1, updatedAt: 2)
        check(!unknown.isEditable, "неизвестный тип")
        checkEqual(try unknown.contentJSON(), raw, "исходная строка не изменена")
        checkEqual(unknown.plainText, "текст")
        let newer = Block(id: id, pageID: page, parentID: nil, sortKey: "a0", type: .paragraph,
                          contentVersion: 99, contentJSON: #"{"runs":[]}"#, plainText: "", createdAt: 1, updatedAt: 2)
        check(!newer.isEditable, "более новая версия")
        let broken = Block(id: id, pageID: page, parentID: nil, sortKey: "a0", type: .paragraph,
                           contentVersion: 1, contentJSON: "{not json", plainText: "", createdAt: 1, updatedAt: 2)
        checkEqual(try broken.contentJSON(), "{not json", "повреждённое содержимое не теряется")
    }

    await test("SaveBatch: новое важнее старого") {
        let page = UUID(), id = UUID()
        var a = SaveBatch()
        a.upserts[id] = Block(id: id, pageID: page, sortKey: "a0", content: BlockContent(text: "1"), createdAt: 0)
        var b = SaveBatch()
        b.deletes = [id]
        a.merge(b)
        check(a.upserts[id] == nil && a.deletes.contains(id), "удаление отменяет запись")
        var c = SaveBatch()
        c.upserts[id] = Block(id: id, pageID: page, sortKey: "a0", content: BlockContent(text: "2"), createdAt: 0)
        a.merge(c)
        check(a.upserts[id] != nil && !a.deletes.contains(id), "новая запись отменяет удаление")
    }
}
