import AppKit

/// M12: `@`-упоминания — неделимые, хранятся по ID, подпись следует за переименованием.
@MainActor
func runMentionTests() async {
    let pageID = UUID(), personID = UUID()

    await test("Упоминание: метки, даты, неделимая правка") {
        let page = Mention.page(pageID, title: "  План ")
        checkEqual(page.text, "План")
        checkEqual(Mention.target(of: page), .page(pageID))
        check(PageLink.targets(of: Block(id: UUID(), pageID: UUID(), sortKey: "a", content: BlockContent(runs: [page]), createdAt: 1)) == [pageID],
              "упоминание страницы — ссылка для обратных ссылок")
        checkEqual(Mention.page(pageID, title: "").text, "Без названия")
        let person = Mention.person(Person(id: personID, name: "Анна"))
        checkEqual(person.text, "@Анна")
        checkEqual(Mention.target(of: person), .person(personID))
        checkEqual(Mention.date("2026-11-12", label: "12 ноября")?.text, "@12 ноября")
        checkEqual(Mention.target(of: Mention.date("2026-11-12T09:30", label: "x")!), .date("2026-11-12T09:30"))
        check(Mention.date("2026-02-30", label: "x") == nil, "несуществующий день")
        check(Mention.date("2026-11-12T25:00", label: "x") == nil, "несуществующий час")
        checkEqual(Mention.reminder(of: Mention.date("2026-11-12", label: "x", reminder: "2026-11-12T08:00")!), "2026-11-12T08:00")
        check(Mention.reminder(of: Mention.date("2026-11-12", label: "x", reminder: "2026-11-12")!) == nil, "напоминание только со временем")
        check(Mention.target(of: TextRun("План", marks: [PageLink.mark(pageID)])) == nil, "обычная ссылка — не упоминание")

        // «Привет @Анна мир»: упоминание 7..<12.
        let runs = [TextRun("Привет "), person, TextRun(" мир")]
        checkEqual(Mention.ranges(in: runs), [7..<12])
        checkEqual(Mention.atomic(11..<12, in: runs), 7..<12, "Backspace в конце стирает упоминание целиком")
        checkEqual(Mention.atomic(9..<9, in: runs), 12..<12, "вставка внутрь уходит за конец")
        checkEqual(Mention.atomic(5..<9, in: runs), 5..<12, "выделение через край берёт упоминание целиком")
        checkEqual(Mention.atomic(7..<12, in: runs), nil, "целое упоминание — без изменений")
        checkEqual(Mention.atomic(12..<12, in: runs), nil, "вставка сразу после — обычная")
        checkEqual(Mention.atomic(0..<3, in: runs), nil)
        let typed = RichText.replace(runs, range: 12..<12, with: "!")
        checkEqual(typed.map(\.text), ["Привет ", "@Анна", "! мир"], "набор после упоминания не продлевает его")
        let before = RichText.replace(runs, range: 7..<7, with: "x")
        checkEqual(Mention.ranges(in: before), [8..<13], "набор перед упоминанием — обычный текст")
    }

    await test("Упоминание: подпись следует за переименованием, ссылка [[ — если не подписана вручную") {
        let runs = [Mention.page(pageID, title: "План"), TextRun(" и "), TextRun("План", marks: [PageLink.mark(pageID)]),
                    TextRun(" и "), TextRun("мой текст", marks: [PageLink.mark(pageID)])]
        let out = Mention.relabel(runs, page: pageID, old: "План", new: "План на год")
        checkEqual(out?.map(\.text), ["План на год", " и ", "План на год", " и ", "мой текст"])
        checkEqual(Mention.relabel(runs, page: UUID(), old: "План", new: "x"), nil, "чужая страница не меняется")
        let people = [Mention.person(Person(id: personID, name: "Анна")), TextRun(" ")]
        checkEqual(Mention.relabel(people, person: Person(id: personID, name: "Анна К."))?.first?.text, "@Анна К.")
        checkEqual(Mention.relabel(people, person: Person(id: personID, name: "Анна")), nil, "имя то же — менять нечего")
    }

    await test("Упоминание: переименование страницы и человека меняет подписи в хранилище, поиск и обратные ссылки") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let target = try await w.createPage(parent: nil, title: "План", id: UUID(), now: 1)
            let source = try await w.createPage(parent: nil, title: "Заметки", id: UUID(), now: 1)
            let anna = try await w.addPerson(name: "Анна", color: nil, emoji: nil, id: UUID(), now: 1)
            let block = UUID()
            var batch = SaveBatch()
            batch.upserts[block] = Block(id: block, pageID: source.id, sortKey: "a",
                                         content: BlockContent(runs: [TextRun("См. "), Mention.page(target.id, title: "План"), TextRun(" — "), Mention.person(anna)]), createdAt: 2)
            try await w.commit(batch)
            checkEqual(try await w.backlinks(to: target.id).map(\.pageID), [source.id], "упоминание входит в обратные ссылки")

            var rename = SaveBatch()
            rename.titles[target.id] = "План на год"
            try await w.commit(rename)
            var stored = try await w.blocks(ofPage: source.id)
            checkEqual(stored.first?.plainText, "См. План на год — @Анна", "подпись страницы обновилась")
            checkEqual(stored.first?.updatedAt, 2, "переименование — не правка этого блока")
            let hits = try await w.search("на год")
            check(hits.contains { $0.pageID == source.id }, "поиск видит новую подпись: \(hits.map(\.title))")

            var renamed = anna
            renamed.name = "Анна К."
            try await w.updatePerson(renamed, now: 3)
            stored = try await w.blocks(ofPage: source.id)
            checkEqual(stored.first?.plainText, "См. План на год — @Анна К.", "подпись человека обновилась")
            if case .person(let id)? = stored.first?.content?.runs.compactMap(Mention.target(of:)).last { checkEqual(id, anna.id) }
            else { check(false, "упоминание человека потеряно") }
        }
    }

    await test("Упоминание в редакторе: «@» открывает меню, выбор вставляет неделимое упоминание") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "Срок ")])
            var shown: [[String]] = []
            r.controller.onSlashChange = { state, items, _ in if state != nil { shown.append(items.map(\.title)) } }
            r.controller.peopleSource = { [Person(id: personID, name: "Анна")] }
            r.controller.pageSearch = { q in q.isEmpty || "план".contains(q.lowercased()) ? [(pageID, "План")] : [] }
            r.caret(0, 5)
            r.type("@")
            checkEqual(r.controller.slash?.kind, .mention, "открылось меню упоминаний")
            check(shown.last?.contains("@Анна") == true && shown.last?.contains("↗ План") == true, "люди и страницы: \(shown.last ?? [])")
            r.type("з")
            r.type("а")
            checkEqual(shown.last, ["Завтра"], "запрос сужает список")
            r.key(#selector(NSResponder.insertNewline(_:)))
            check(r.controller.slash == nil)
            let tomorrow = LocalDate(date: Date(), in: .current).adding(days: 1).iso
            let runs = r.doc.blocks[0].content!.runs
            checkEqual(runs.compactMap(Mention.target(of:)), [.date(tomorrow)], "вставлена дата завтра")
            check(r.texts[0].hasPrefix("Срок @") && r.texts[0].hasSuffix(" "), "«@за» заменено подписью и пробелом: \(r.texts[0])")
            r.checkSync("после вставки")

            // Backspace сразу за упоминанием (перед пробелом — сначала пробел).
            let end = r.texts[0].utf16.count
            r.caret(0, end)
            r.key(#selector(NSResponder.deleteBackward(_:)))
            r.key(#selector(NSResponder.deleteBackward(_:)))
            checkEqual(r.texts[0], "Срок ", "второй Backspace стёр упоминание целиком")
            r.checkSync("после удаления")
            r.tv.undo(nil)
            check(r.doc.blocks[0].content!.runs.contains(where: Mention.isMention), "⌘Z вернул упоминание")
            r.checkSync("после отмены")

            // Курсор не встаёт внутрь: слева направо выходит к концу, справа налево — к началу.
            r.caret(0, 5)
            r.caret(0, 7)
            checkEqual(r.tv.selectedRange().location, 5 + r.doc.blocks[0].content!.runs.first(where: Mention.isMention)!.text.utf16.count,
                       "курсор вышел за конец упоминания")
            let mentionEnd = r.tv.selectedRange().location
            r.caret(0, 8)
            checkEqual(r.tv.selectedRange().location, 5, "справа — к началу упоминания")
            r.tv.setSelectedRange(NSRange(location: 6, length: 0))
            r.tv.insertText("x", replacementRange: NSRange(location: 6, length: 0))
            check(r.texts[0].contains("x"), "символ вставлен")
            check(r.doc.blocks[0].content!.runs.filter(Mention.isMention).allSatisfy { !$0.text.contains("x") }, "упоминание не испорчено")
            _ = mentionEnd
            r.checkSync("набор внутрь")

            // Переименование страницы, пока открыта эта: подпись меняется в редакторе без шага отмены.
            r.caret(0, r.texts[0].utf16.count)
            r.controller.run(.mentionPage(pageID, "План"))
            check(r.texts[0].contains("План"), "упоминание страницы вставлено: \(r.texts[0])")
            r.controller.relabel(.relabelPage(pageID, old: "План", new: "Годовой план"))
            check(r.texts[0].contains("Годовой план"), "подпись в открытом редакторе обновлена: \(r.texts[0])")
            r.checkSync("после переименования")
            r.tv.undo(nil)
            let afterUndo = r.texts[0].replacingOccurrences(of: "Годовой план", with: "")
            check(!afterUndo.contains("План"), "⌘Z отменяет вставку, а не переименование: старая подпись не вернулась (\(r.texts[0]))")
            r.checkSync("после отмены вставки")
            try await r.close()
        }
    }
}
