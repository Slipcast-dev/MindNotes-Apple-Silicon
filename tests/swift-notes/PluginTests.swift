import Foundation

/// Плагины и локальный API (ADR-0019): описание пакета, разбор HTTP, источник запроса, вырезка и её запись.
func runPluginTests() async {
    await test("Плагин: описание, разрешения, компоненты внутри пакета") {
        let json = #"""
        {"id":"minerva.webclipper","name":"Web Clipper","version":"1.0.0","kind":"plugin","api":1,
         "description":"Сохраняет страницы","permissions":["pages.list","pages.create","pages.create","tags.write"],
         "components":{"chrome":"browser/chrome","safari":"browser/safari/App.app"}}
        """#
        guard case .success(let m) = PluginManifest.parse(Data(json.utf8)) else { check(false, "описание не разобрано"); return }
        checkEqual(m.id, "minerva.webclipper")
        checkEqual(m.permissions, [.pagesList, .pagesCreate, .tagsWrite], "повтор разрешения убран")
        checkEqual(m.components["chrome"], "browser/chrome")
        check(m.problem(app: AppVersion("1.4.2")) == nil, "подходит этой версии")

        func problem(_ s: String) -> PluginManifest.Problem? {
            if case .failure(let p) = PluginManifest.parse(Data(s.utf8)) { return p }
            return nil
        }
        checkEqual(problem(#"{"id":"x","name":"X","kind":"theme"}"#), .notPlugin)
        checkEqual(problem(#"{"id":"x","name":"X","kind":"plugin","components":{"chrome":"../../etc"}}"#), .badComponent("chrome"), "путь наружу пакета")
        checkEqual(problem(#"{"id":"x","name":"X","kind":"plugin","components":{"chrome":"/Applications"}}"#), .badComponent("chrome"), "абсолютный путь")
        checkEqual(problem("не json"), .unreadable)
        if case .success(let newer) = PluginManifest.parse(Data(#"{"id":"x","name":"X","kind":"plugin","api":2,"permissions":["files.delete"]}"#.utf8)) {
            checkEqual(newer.problem(app: nil), .newerAPI(2), "более новый API не включается")
            checkEqual(newer.unknownPermissions, ["files.delete"])
        } else { check(false) }
        if case .success(let unknown) = PluginManifest.parse(Data(#"{"id":"x","name":"X","kind":"plugin","permissions":["files.delete"]}"#.utf8)) {
            checkEqual(unknown.problem(app: nil), .unknownPermissions(["files.delete"]), "незнакомое разрешение не включается")
        } else { check(false) }
        if case .success(let old) = PluginManifest.parse(Data(#"{"id":"x","name":"X","kind":"plugin","minApp":"9.0"}"#.utf8)) {
            checkEqual(old.problem(app: AppVersion("1.4.2")), .newerApp("9.0"))
        } else { check(false) }
    }

    await test("Выпуски плагина: свой префикс тега, самый новый годный, minApp из описания") {
        check(PluginManifest.isSafeTagPrefix("webclipper-v"))
        check(!PluginManifest.isSafeTagPrefix("v"), "префикс приложения не годится: перепутались бы выпуски")
        check(!PluginManifest.isSafeTagPrefix("../x-v") && !PluginManifest.isSafeTagPrefix("Web-v"))
        if case .success(let m) = PluginManifest.parse(Data(#"{"id":"x","name":"X","kind":"plugin","updates":"webclipper-v"}"#.utf8)) {
            checkEqual(m.updates, "webclipper-v")
        } else { check(false) }
        if case .failure(let p) = PluginManifest.parse(Data(#"{"id":"x","name":"X","kind":"plugin","updates":"v"}"#.utf8)) {
            checkEqual(p, .badComponent("updates"))
        } else { check(false) }

        func release(_ tag: String, draft: Bool = false, pre: Bool = false, dmg: String? = "a.dmg", host: String = "github.com", body: String = "") -> [String: Any] {
            var assets: [[String: Any]] = [["name": "SHA256SUMS.txt", "browser_download_url": "https://\(host)/s"]]
            if let dmg { assets.append(["name": dmg, "browser_download_url": "https://\(host)/\(dmg)"]) }
            return ["tag_name": tag, "draft": draft, "prerelease": pre, "assets": assets, "body": body]
        }
        let list: [[String: Any]] = [
            release("v1.9.0"),                                 // выпуск приложения
            release("webclipper-v1.0.1", body: "Исправления\n<!-- minApp: 1.5.0 -->"),
            release("webclipper-v1.2.0", draft: true),
            release("webclipper-v1.1.0", pre: true),
            release("webclipper-v1.0.5", dmg: nil),            // без образа
            release("webclipper-v1.0.9", host: "evil.example"), // не GitHub
            release("otherplugin-v9.0.0"),
            release("webclipper-v1.0.2", body: "<!-- minApp: 1.6 -->"),
        ]
        let data = try JSONSerialization.data(withJSONObject: list)
        let newest = try require(PluginRelease.newest(in: data, prefix: "webclipper-v"))
        checkEqual(newest.tag, "webclipper-v1.0.2", "черновики, предварительные, без образа и не с GitHub пропущены")
        checkEqual(newest.minApp, AppVersion("1.6"))
        checkEqual(newest.image.lastPathComponent, "a.dmg")
        check(PluginRelease.newest(in: data, prefix: "nothing-v") == nil)
        check(PluginRelease.minApp(in: "без пометки") == nil)
        check(AppVersion("webclipper-v1.0.2") == nil, "тег плагина не примется за версию приложения (ADR-0014)")
    }

    await test("Подключения: одно на расширение, старые дубли убираются") {
        func client(_ name: String, origin: String?, created: Int64, used: Int64? = nil, plugin: String = "p") -> PluginClient {
            PluginClient(id: UUID(), plugin: plugin, name: name, tokenHash: "h", createdAt: created, lastUsedAt: used, origin: origin)
        }
        let a = client("Chrome", origin: "chrome-extension://a", created: 1)
        let b = client("Chrome", origin: "chrome-extension://a", created: 2)
        let other = client("Safari", origin: "safari-web-extension://s", created: 3)
        checkEqual(PluginClient.adding(b, to: [a, other]).map(\.id), [other.id, b.id], "новый ключ того же расширения заменяет прежний")
        let second = client("Chrome", origin: "chrome-extension://z", created: 4)
        checkEqual(PluginClient.adding(second, to: [a]).count, 2, "другое расширение (профиль) — отдельное подключение")
        checkEqual(PluginClient.adding(client("App", origin: nil, created: 5), to: [a]).count, 2, "программа без Origin добавляется")

        // Как было у пользователя: три Chrome без источника, расширение пользуется последним.
        let old1 = client("Chrome", origin: nil, created: 10, used: 11)
        let old2 = client("Chrome", origin: nil, created: 12, used: 30)
        let old3 = client("Chrome", origin: nil, created: 13, used: 14)
        let foreign = client("Chrome", origin: nil, created: 1, plugin: "q")
        checkEqual(PluginClient.deduplicated([old1, old2, old3, foreign, other]).map(\.id), [old2.id, foreign.id, other.id],
                   "остаётся последний использованный, другие плагины не трогаются")
        let encoded = try JSONEncoder().encode([old1])
        let legacy = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: ",\"origin\":null", with: "")
        checkEqual(try JSONDecoder().decode([PluginClient].self, from: Data(legacy.utf8)).first?.origin, nil, "старые записи без origin читаются")
    }

    await test("Локальный API: разбор запроса, тело частями, пределы") {
        let body = #"{"a":1}"#
        let raw = "POST /v1/clips?x=1&y=%D0%B0+b HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: chrome-extension://abc\r\nAuthorization: Bearer tok123\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .request(let r) = LocalAPI.parse(Data(raw.utf8)) else { check(false, "запрос не разобран"); return }
        checkEqual(r.method, "POST")
        checkEqual(r.path, "/v1/clips")
        checkEqual(r.query["y"], "а b")
        checkEqual(r.bearer, "tok123")
        checkEqual(r.origin, "chrome-extension://abc")
        checkEqual(String(decoding: r.body, as: UTF8.self), body)
        checkEqual(LocalAPI.route(r), .clips)
        checkEqual(LocalAPI.permission(for: .clips), .pagesCreate)

        checkEqual(LocalAPI.parse(Data(raw.utf8.dropLast(3))), .incomplete, "тело ещё не дошло")
        checkEqual(LocalAPI.parse(Data("GET /v1/status HTTP/1.1\r\nHost: x".utf8)), .incomplete, "заголовки ещё не дошли")
        checkEqual(LocalAPI.parse(Data("POST /v1/clips HTTP/1.1\r\nContent-Length: \(LocalAPI.maxBody + 1)\r\n\r\n".utf8)), .invalid(status: 413))
        checkEqual(LocalAPI.parse(Data("POST /v1/clips HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .invalid(status: 501))
        checkEqual(LocalAPI.parse(Data(String(repeating: "a", count: LocalAPI.maxHeader + 10).utf8)), .invalid(status: 431))
        checkEqual(LocalAPI.parse(Data("hello\r\n\r\n".utf8)), .invalid(status: 400))
        checkEqual(LocalAPI.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)), .invalid(status: 400), "только путь, не адрес")

        let id = UUID()
        if case .request(let open) = LocalAPI.parse(Data("POST /v1/pages/\(id.uuidString.lowercased())/open HTTP/1.1\r\n\r\n".utf8)) {
            checkEqual(LocalAPI.route(open), .openPage(id))
        } else { check(false) }
        if case .request(let bad) = LocalAPI.parse(Data("POST /v1/pages/../open HTTP/1.1\r\n\r\n".utf8)) {
            check(LocalAPI.route(bad) == nil, "неверный UUID — нет маршрута")
        } else { check(false) }
        if case .request(let get) = LocalAPI.parse(Data("GET /v1/clips HTTP/1.1\r\n\r\n".utf8)) {
            check(LocalAPI.route(get) == nil, "метод тоже входит в маршрут")
        } else { check(false) }
    }

    await test("Локальный API: только расширения браузера, CORS только для них") {
        check(LocalAPI.isAllowedOrigin("chrome-extension://abcdef"))
        check(LocalAPI.isAllowedOrigin("safari-web-extension://1234-5678"))
        check(LocalAPI.isAllowedOrigin(nil), "программа без Origin — проверяется токеном")
        check(!LocalAPI.isAllowedOrigin("https://evil.example"), "обычный сайт отклоняется")
        check(!LocalAPI.isAllowedOrigin("null"))
        check(!LocalAPI.isAllowedOrigin("chrome-extension://"))
        checkEqual(LocalAPI.browserName(origin: "safari-web-extension://x", userAgent: nil), "Safari")
        checkEqual(LocalAPI.browserName(origin: "chrome-extension://x", userAgent: "Mozilla Chrome/130 Edg/130"), "Edge")
        checkEqual(LocalAPI.browserName(origin: "chrome-extension://x", userAgent: "Mozilla Chrome/130"), "Chrome")

        let ok = String(decoding: LocalAPI.Response.json(200, ["a": 1]).serialized(origin: "chrome-extension://x"), as: UTF8.self)
        check(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        check(ok.contains("Access-Control-Allow-Origin: chrome-extension://x"))
        check(ok.hasSuffix("\r\n\r\n{\"a\":1}"))
        let site = String(decoding: LocalAPI.Response.json(200, [:]).serialized(origin: "https://evil.example"), as: UTF8.self)
        check(!site.contains("Access-Control-Allow-Origin"), "чужому сайту CORS не открывается")
    }

    await test("Вырезка: разбор, пределы, безопасные имена и адреса") {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let json: [String: Any] = ["mode": "article", "title": "  Статья  ", "url": "https://example.com/a", "markdown": "# Заголовок\n\nТекст",
                                   "tags": ["Чтение", "чтение", " "], "note": "Важно",
                                   "images": [["name": "clip-1.png", "mime": "image/png", "data": png.base64EncodedString()]]]
        guard case .success(let clip) = WebClip.parse(try JSONSerialization.data(withJSONObject: json)) else { check(false); return }
        checkEqual(clip.title, "Статья")
        checkEqual(clip.tags, ["Чтение"], "теги без повторов и пустых")
        checkEqual(clip.images.first?.data, png)

        func problem(_ o: [String: Any]) -> WebClip.Problem? {
            if case .failure(let p) = WebClip.parse(try! JSONSerialization.data(withJSONObject: o)) { return p }
            return nil
        }
        checkEqual(problem(["url": "file:///etc/passwd"]), .badField("url"), "только http(s)")
        checkEqual(problem(["url": "javascript:alert(1)"]), .badField("url"))
        checkEqual(problem(["mode": "exec"]), .badField("mode"))
        checkEqual(problem(["images": [["name": "../x.png", "mime": "image/png", "data": png.base64EncodedString()]]]), .badField("images"), "имя без пути")
        checkEqual(problem(["images": [["name": "x.svg", "mime": "image/svg+xml", "data": png.base64EncodedString()]]]), .badField("images"), "SVG не принимается")
        checkEqual(problem(["mode": "screenshot"]), .badField("images"), "скриншот без картинки")
        checkEqual(problem(["mode": "bookmark"]), .badField("url"), "закладка без адреса")
        checkEqual(problem(["parent": "не-uuid"]), .badField("parent"))
        checkEqual(problem(["tags": Array(repeating: 0, count: 2).enumerated().map { "t\($0.offset)" } + Array((0..<30).map { "x\($0)" })]), .tooLarge("tags"))
        if case .success(let untitled) = WebClip.parse(Data(#"{"url":"https://site.org/p"}"#.utf8)) {
            checkEqual(untitled.title, "site.org", "без заголовка — имя сайта")
        } else { check(false) }
    }

    await test("Вырезка: страница с карточкой источника, заметкой, текстом и картинкой") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let folder = try await ws.createPage(parent: nil, title: "Из браузера", id: UUID(), now: 1)
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let markdown = "## Раздел\n\nТекст со [ссылкой](https://example.com) и [[Чужая вики]] и [злой](javascript:alert(1)).\n\n![Схема](clip-1.png)\n\n![Внешняя](https://cdn.example.com/x.png)\n\n- пункт"
            let clip = WebClip(mode: .article, title: "Статья", url: URL(string: "https://example.com/a"), markdown: markdown, excerpt: "Кратко",
                               siteName: nil, note: "Моя заметка", tags: [], parent: folder.id,
                               images: [WebClip.Image(name: "clip-1.png", mime: "image/png", data: png)])
            let page = try await ClipImport.run(clip, into: ws, parent: folder.id, ids: RandomIDs(), now: 5)
            checkEqual(page.parentID, folder.id)
            checkEqual(page.title, "Статья")
            let blocks = try await ws.blocks(ofPage: page.id)
            checkEqual(blocks.map(\.type), [.bookmark, .callout, .heading2, .paragraph, .image, .paragraph, .bullet])
            checkEqual(AtomData.url(of: blocks[0]), URL(string: "https://example.com/a"), "карточка источника")
            checkEqual(blocks[1].plainText, "Моя заметка")
            let marks = blocks[3].content?.runs.flatMap(\.marks) ?? []
            check(marks.contains("a:https://example.com"), "внешняя ссылка сохранена")
            check(!marks.contains { $0.hasPrefix("a:wiki:") || $0.contains("javascript") }, "ни вики-ссылок, ни опасных схем")
            let asset = try require(blocks[4].assetID)
            let file = try require(try await ws.assetURL(asset))
            checkEqual(try Data(contentsOf: file), png, "картинка — вложение пространства")
            checkEqual(blocks[5].plainText, "Внешняя", "картинка не из вырезки остаётся подписью")
        }
    }

    await test("Вырезка: скриншот — картинка без текста") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let clip = WebClip(mode: .screenshot, title: "Экран", url: URL(string: "https://example.com"), markdown: "", excerpt: nil, siteName: nil,
                               note: nil, tags: [], parent: nil, images: [WebClip.Image(name: "screenshot.png", mime: "image/png", data: Data([1, 2, 3]))])
            let page = try await ClipImport.run(clip, into: ws, parent: nil, ids: RandomIDs(), now: 5)
            checkEqual(try await ws.blocks(ofPage: page.id).map(\.type), [.bookmark, .image])
        }
    }
}

private struct Missing: Error {}

/// Значение обязано быть: иначе тест падает с ошибкой.
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw Missing() }
    return value
}
