import AppKit

/// M12: закладка и встраивание (ADR-0011). Сеть здесь не нужна: разбор страницы и редактор с подменой загрузки.
@MainActor
func runLinkCardTests() async {
    await test("Закладка: адрес, разбор og:, сущности, относительная картинка, только https") {
        checkEqual(LinkCard.url("  https://example.com/a?b=1 ")?.absoluteString, "https://example.com/a?b=1")
        checkEqual(LinkCard.url("example.com")?.absoluteString, "https://example.com", "домен без схемы — https")
        check(LinkCard.url("javascript:alert(1)") == nil, "чужая схема")
        check(LinkCard.url("https://a.com b") == nil, "пробел внутри")
        check(LinkCard.url("ftp://a.com") == nil)
        let html = """
        <html><head><title>Запасной</title>
        <meta property="og:title" content="Статья &amp; заметки">
        <meta name='description' content='Описание из name'>
        <META PROPERTY="og:image" CONTENT="/img/cover.png">
        <meta name="twitter:title" content="Твиттер">
        </head><body>…</body></html>
        """
        let p = LinkCard.parse(html: html, base: URL(string: "https://example.com/post/1")!)
        checkEqual(p.title, "Статья & заметки", "og:title важнее twitter и <title>, сущности раскрыты")
        checkEqual(p.description, "Описание из name")
        checkEqual(p.image?.absoluteString, "https://example.com/img/cover.png", "относительная картинка разрешена от адреса страницы")
        let plain = LinkCard.parse(html: "<title>\n  Только   заголовок </title>", base: URL(string: "https://a.com")!)
        checkEqual(plain.title, "Только заголовок", "пробелы схлопнуты")
        check(plain.image == nil && plain.description == nil)
        let insecure = LinkCard.parse(html: #"<meta property="og:image" content="http://a.com/x.png">"#, base: URL(string: "https://a.com")!)
        check(insecure.image == nil, "картинка только по https")
        let long = LinkCard.parse(html: "<meta property=\"og:title\" content=\"\(String(repeating: "я", count: 1000))\">", base: URL(string: "https://a.com")!)
        checkEqual(long.title?.count, LinkCard.maxTitle + 1, "заголовок обрезан")
        let broken = LinkCard.parse(html: "<meta property=\"og:title\" content=\"без конца", base: URL(string: "https://a.com")!)
        check(broken.title == nil, "незакрытая кавычка не ломает разбор")
    }

    await test("Встраивание: YouTube, Vimeo, Figma, Google Maps и обычная страница") {
        func embed(_ s: String) -> (String, String) { let e = LinkCard.embed(URL(string: s)!); return (e.provider, e.url.absoluteString) }
        checkEqual(embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10").1, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
        checkEqual(embed("https://youtu.be/dQw4w9WgXcQ").1, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
        checkEqual(embed("https://youtube.com/shorts/abc_DEF-1").1, "https://www.youtube-nocookie.com/embed/abc_DEF-1")
        checkEqual(embed("https://youtube.com/watch?v=../../evil").1, "https://youtube.com/watch?v=../../evil", "чужой ID не подставляется в адрес")
        checkEqual(embed("https://vimeo.com/76979871").1, "https://player.vimeo.com/video/76979871")
        checkEqual(embed("https://www.figma.com/file/abc/Name").0, "Figma")
        check(embed("https://www.figma.com/file/abc/Name").1.hasPrefix("https://www.figma.com/embed?embed_host=share&url="))
        checkEqual(embed("https://www.google.com/maps/place/Moscow").0, "Google Maps")
        checkEqual(embed("https://maps.app.goo.gl/xyz").0, "Google Maps")
        checkEqual(embed("https://example.org/page").0, "example.org")
    }

    await test("Закладка и встраивание: данные блока, вложение превью, экспорт") {
        let url = URL(string: "https://example.com/post")!
        let asset = UUID()
        let fragment = AtomData.bookmark(url: url, title: "Пост", description: "Кратко", asset: asset)
        let block = Block(id: UUID(), pageID: UUID(), parentID: nil, sortKey: "a", type: .bookmark, contentVersion: 1,
                          contentJSON: fragment.json, plainText: fragment.plain, createdAt: 1, updatedAt: 1)
        check(block.type.isAtom, "закладка — неделимый блок")
        checkEqual(AtomData.url(of: block), url)
        checkEqual(AtomData.string("title", of: block), "Пост")
        checkEqual(block.assetID, asset, "картинка превью — вложение блока: защищена от уборки и попадает в копию")
        checkEqual(block.plainText, "Пост https://example.com/post", "поиск видит заголовок и адрес")
        let kept = AtomData.bookmarkJSON(url: url, title: "Новый", description: nil, asset: nil, keeping: ["future": .bool(true)])
        check(kept.contains("\"future\":true") && !kept.contains("description"), "чужие поля сохраняются, пустые не пишутся")
        let video = AtomData.embed(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!)
        checkEqual(video.type, BlockType.embed.rawValue)
        let embedBlock = Block(id: UUID(), pageID: UUID(), parentID: nil, sortKey: "b", type: .embed, contentVersion: 1,
                               contentJSON: video.json, plainText: video.plain, createdAt: 1, updatedAt: 1)
        check(embedBlock.assetID == nil)
        let md = MarkdownExport.export(title: "Т", blocks: [block, embedBlock], assetFolder: "f") { _ in nil }
        check(md.markdown.contains("[Пост](<https://example.com/post>)") && md.markdown.contains("Кратко"), md.markdown)
        check(md.markdown.contains("(<https://youtu.be/dQw4w9WgXcQ>)"))
        check(md.report.contains { $0.reason == "Встраивания стали ссылками" }, "встраивание отмечено в отчёте")
    }

    await test("Закладка в редакторе: вставка адреса с выбором, превью без шага отмены, обычный текст по Esc") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "")])
            let board = NSPasteboard(name: NSPasteboard.Name("notes.test.\(UUID().uuidString)"))
            board.clearContents()
            board.setString("https://example.com/post", forType: .string)
            var choice: BlockType? = .bookmark
            var asked: [URL] = []
            r.controller.chooseLinkKind = { url in asked.append(url); return choice }
            r.controller.fetchLinkPreview = { _ in ("Пост из сети", "Описание", nil) }
            r.caret(0, 0)
            r.controller.paste(from: board)
            checkEqual(asked.map(\.absoluteString), ["https://example.com/post"], "спросили, что сделать с адресом")
            checkEqual(r.types.filter { $0 == .bookmark }.count, 1, "вставлена закладка")
            for _ in 0..<20 where AtomData.string("title", of: r.doc.blocks.first { $0.type == .bookmark }!) != "Пост из сети" {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let card = r.doc.blocks.first { $0.type == .bookmark }!
            checkEqual(AtomData.string("title", of: card), "Пост из сети", "превью записано в блок")
            checkEqual(AtomData.string("description", of: card), "Описание")
            r.checkSync("после превью")
            r.tv.undo(nil)
            check(!r.types.contains(.bookmark), "одна отмена убирает закладку целиком, без промежуточного шага превью")

            choice = .embed
            r.caret(0, 0)
            r.controller.paste(from: board)
            check(r.types.contains(.embed), "встраивание")
            r.tv.undo(nil)

            choice = .paragraph
            r.caret(0, 0)
            r.controller.paste(from: board)
            check(r.doc.blocks[0].content?.runs.contains { $0.marks.contains("a:https://example.com/post") } == true, "«Ссылка» — текст со ссылкой")
            r.tv.undo(nil)

            choice = nil
            r.caret(0, 0)
            r.controller.paste(from: board)
            checkEqual(r.texts[0], "https://example.com/post", "меню закрыто — обычный текст")
            check(r.doc.blocks[0].content?.runs.allSatisfy { $0.marks.isEmpty } == true)
            r.checkSync("обычный текст")
            try await r.close()
        }
    }
}
