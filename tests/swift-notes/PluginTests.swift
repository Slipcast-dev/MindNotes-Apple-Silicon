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
        if case .success(let early) = PluginManifest.parse(Data(#"{"id":"minerva.webclipper","name":"Web Clipper","kind":"plugin"}"#.utf8)) {
            checkEqual(early.updateSource, "webclipper-v", "ранняя сборка без поля updates находит выпуски по id")
        } else { check(false) }
        if case .success(let explicit) = PluginManifest.parse(Data(#"{"id":"a.b","name":"X","kind":"plugin","updates":"other-v"}"#.utf8)) {
            checkEqual(explicit.updateSource, "other-v", "явное поле важнее правила")
        } else { check(false) }
        // Отдельный репозиторий плагина (ADR-0019, п. 10): только «владелец/имя» на GitHub.
        for ok in ["Slipcast-dev/MindNotes-WebClipper", "a/b", "owner1/repo.name_2"] { check(PluginManifest.isValidRepository(ok), ok) }
        for bad in ["", "a", "a/b/c", "/b", "a/", "-a/b", "a/..", "a/.", "https://github.com/a/b", "github.com/a/b", "a b/c",
                    "evil.example/x", String(repeating: "a", count: 40) + "/b", "a/" + String(repeating: "b", count: 101), "аб/вг"] {
            check(!PluginManifest.isValidRepository(bad), "отклонено: \(bad)")
        }
        if case .success(let moved) = PluginManifest.parse(Data(#"{"id":"minerva.webclipper","name":"W","kind":"plugin","updates":"webclipper-v","repository":"Slipcast-dev/MindNotes-WebClipper"}"#.utf8)) {
            checkEqual(moved.releasesURL(fallback: "Slipcast-dev/MindNotes-Apple-Silicon")?.absoluteString,
                       "https://api.github.com/repos/Slipcast-dev/MindNotes-WebClipper/releases?per_page=50", "выпуски — из репозитория плагина")
        } else { check(false) }
        if case .success(let early) = PluginManifest.parse(Data(#"{"id":"minerva.webclipper","name":"W","kind":"plugin"}"#.utf8)) {
            checkEqual(early.releasesURL(fallback: "Slipcast-dev/MindNotes-Apple-Silicon")?.absoluteString,
                       "https://api.github.com/repos/Slipcast-dev/MindNotes-WebClipper/releases?per_page=50",
                       "Web Clipper, поставленный до переезда (без поля), — сразу из своего репозитория")
        } else { check(false) }
        if case .success(let local) = PluginManifest.parse(Data(#"{"id":"x.other","name":"W","kind":"plugin"}"#.utf8)) {
            checkEqual(local.releasesURL(fallback: "Slipcast-dev/MindNotes-Apple-Silicon")?.absoluteString,
                       "https://api.github.com/repos/Slipcast-dev/MindNotes-Apple-Silicon/releases?per_page=50", "другой плагин без поля — как раньше")
        } else { check(false) }
        for (id, repo) in PluginManifest.knownRepositories { check(PluginManifest.isValidRepository(repo), id) }
        if case .failure(let p) = PluginManifest.parse(Data(#"{"id":"x","name":"X","kind":"plugin","repository":"https://evil.example/x"}"#.utf8)) {
            checkEqual(p, .badComponent("repository"), "адрес вместо имени не принимается")
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

    await test("Обновление плагина без вопроса — только тот же плагин, новее и без новых разрешений") {
        func manifest(_ version: String, _ permissions: [String], id: String = "minerva.webclipper", api: Int = 1) -> PluginManifest {
            let json = #"{"id":"\#(id)","name":"Web Clipper","version":"\#(version)","kind":"plugin","api":\#(api),"permissions":[\#(permissions.map { "\"\($0)\"" }.joined(separator: ","))]}"#
            guard case .success(let m) = PluginManifest.parse(Data(json.utf8)) else { fatalError(json) }
            return m
        }
        let installed = manifest("1.0.0", ["pages.list", "pages.create", "assets.create"])
        let app = AppVersion("1.5.1")
        check(manifest("1.0.1", ["pages.list", "pages.create", "assets.create"]).isTrustedUpdate(of: installed, app: app), "те же разрешения")
        check(manifest("1.1.0", ["pages.create"]).isTrustedUpdate(of: installed, app: app), "меньше разрешений")
        check(!manifest("1.0.1", ["pages.list", "pages.create", "assets.create", "tags.write"]).isTrustedUpdate(of: installed, app: app), "новое разрешение — только с вопросом")
        check(!manifest("1.0.0", ["pages.create"]).isTrustedUpdate(of: installed, app: app), "та же версия — не обновление")
        check(!manifest("0.9.0", ["pages.create"]).isTrustedUpdate(of: installed, app: app), "старая версия")
        check(!manifest("1.0.1", ["pages.create"], id: "evil.plugin").isTrustedUpdate(of: installed, app: app), "чужой плагин")
        check(!manifest("1.0.1", ["pages.create"], api: 2).isTrustedUpdate(of: installed, app: app), "несовместимый API")

        let list: [[String: Any]] = [["tag_name": "webclipper-v1.0.1", "draft": false, "prerelease": false, "body": "", "assets": [
            ["name": "MindNotes-Web-Clipper-1.0.1.dmg", "browser_download_url": "https://github.com/x/a.dmg"],
            ["name": "SHA256SUMS.txt", "browser_download_url": "https://github.com/x/s"],
            ["name": "plugin-manifest.json", "browser_download_url": "https://github.com/x/m.json"]]]]
        let release = try require(PluginRelease.newest(in: try JSONSerialization.data(withJSONObject: list), prefix: "webclipper-v"))
        checkEqual(release.manifest?.absoluteString, "https://github.com/x/m.json", "описание плагина из выпуска")
        check(release.minApp == nil, "minApp необязателен")
        check(LocalAPI.features.contains("remoteImages") && LocalAPI.features.contains("clips"), "приложение сообщает свои возможности")
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

    await test("Локальный API: чтение страниц (pages.read) и папка вложений") {
        func request(_ line: String) -> LocalAPI.Request? {
            if case .request(let r) = LocalAPI.parse(Data("\(line) HTTP/1.1\r\n\r\n".utf8)) { return r }
            return nil
        }
        let id = UUID(), asset = UUID()
        let page = id.uuidString.lowercased()
        checkEqual(request("GET /v1/pages").flatMap(LocalAPI.route), .pages)
        checkEqual(request("GET /v1/pages/\(page)/markdown").flatMap(LocalAPI.route), .pageMarkdown(id))
        checkEqual(request("GET /v1/pages/\(page)/assets/\(asset.uuidString)").flatMap(LocalAPI.route), .pageAsset(page: id, asset: asset))
        check(request("POST /v1/pages").flatMap(LocalAPI.route) == nil, "список — только GET")
        checkEqual(request("PUT /v1/pages/\(page)/markdown").flatMap(LocalAPI.route), .writeMarkdown(id))
        checkEqual(LocalAPI.permission(for: .writeMarkdown(id)), .pagesWrite, "запись — своё разрешение")
        check(request("DELETE /v1/pages/\(page)/markdown").flatMap(LocalAPI.route) == nil)
        check(request("GET /v1/pages/\(page)/assets/../../x").flatMap(LocalAPI.route) == nil, "id вложения — только UUID")
        for route in [LocalAPI.Route.pages, .pageMarkdown(id), .pageAsset(page: id, asset: asset)] {
            checkEqual(LocalAPI.permission(for: route), .pagesRead)
        }
        check(LocalAPI.features.contains("pagesRead"))

        checkEqual(request("GET /v1/pages/\(page)/markdown").flatMap(LocalAPI.assetFolder), "files", "без параметра — files")
        checkEqual(request("GET /v1/pages/\(page)/markdown?assets=notes/My%20page_files").flatMap(LocalAPI.assetFolder), "notes/My page_files")
        for bad in ["..%2Fx", "%2Fetc", "a/../b", "a//b", "~x", "a%5Cb", "a%0Ab"] {
            check(request("GET /v1/pages/\(page)/markdown?assets=\(bad)").flatMap(LocalAPI.assetFolder) == nil, "отклонено: \(bad)")
        }

        let readJSON = #"{"id":"x.github","name":"GitHub","kind":"plugin","api":1,"permissions":["pages.list","pages.read"]}"#
        if case .success(let m) = PluginManifest.parse(Data(readJSON.utf8)) {
            checkEqual(m.permissions, [.pagesList, .pagesRead])
            check(m.problem(app: AppVersion("1.7.1")) == nil, "новое разрешение понятно этой версии")
        } else { check(false, "описание с pages.read не разобрано") }

        // Программа-установщик плагина (ADR-0019, п. 14): bundle ID, по которому MindNotes находит и обновляет её.
        let withInstaller = #"{"id":"minerva.github","name":"GitHub","kind":"plugin","api":1,"permissions":["pages.read"],"installer":"local.personal.MindNotes.GitHub"}"#
        if case .success(let m) = PluginManifest.parse(Data(withInstaller.utf8)) { checkEqual(m.installer, "local.personal.MindNotes.GitHub") }
        else { check(false, "описание с installer не разобрано") }
        for bad in ["", "one", "a..b", "../x", "a.b/c", "a b.c", String(repeating: "a.", count: 90)] {
            let json = #"{"id":"x.y","name":"X","kind":"plugin","installer":"\#(bad)"}"#
            if case .success = PluginManifest.parse(Data(json.utf8)) { check(false, "отклонено: \(bad)") }
        }
        if case .success(let m) = PluginManifest.parse(Data(readJSON.utf8)) { check(m.installer == nil, "поле необязательно") }

        // Описание на языке интерфейса (ADR-0019, п. 15).
        let multi = #"{"id":"x.y","name":"X","kind":"plugin","description":"Русское","descriptions":{"en":"English","x y":"bad"}}"#
        if case .success(let m) = PluginManifest.parse(Data(multi.utf8)) {
            checkEqual(m.summary(language: "en"), "English")
            checkEqual(m.summary(language: "ru"), "Русское", "нет перевода — основное описание")
            checkEqual(m.summary(language: "de"), "Русское")
            check(m.summaries["x y"] == nil, "ключ языка — только буквы")
        } else { check(false, "описание с descriptions не разобрано") }
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

    await test("Картинки с других сайтов: только публичный https, подстановка и запасная ссылка") {
        for ok in ["https://cdn.example.com/a.png", "https://images.site.ru/x/y.webp?w=800", "https://8.8.8.8/p.png"] {
            check(WebClip.isPublicWebURL(URL(string: ok)!), ok)
        }
        for bad in ["http://cdn.example.com/a.png", "https://localhost/a.png", "https://127.0.0.1/a.png", "https://192.168.1.1/a.png",
                    "https://10.0.0.5/a.png", "https://172.20.1.1/a.png", "https://169.254.169.254/latest", "https://router.local/a.png",
                    "https://[::1]/a.png", "https://printer/a.png", "https://user:pw@cdn.example.com/a.png", "file:///etc/hosts",
                    "https://2130706433/a.png", "https://0x7f.0.0.1/a.png", "https://0177.0.0.1/a.png", "https://127.1/a.png",
                    "https://nas.home/a.png", "https://256.1.1.1/a.png"] {
            check(!WebClip.isPublicWebURL(URL(string: bad)!), "запрещён: \(bad)")
        }
        let json: [String: Any] = ["mode": "article", "url": "https://example.com/post", "markdown": "Текст\n\n![Схема](remote-1.img)\n\n![](remote-2.img)",
                                   "remoteImages": [["name": "remote-1.img", "url": "https://cdn.example.com/1.png"],
                                                    ["name": "remote-2.img", "url": "https://cdn.example.com/2(1).jpg"]]]
        let clip = try require(try? WebClip.parse(JSONSerialization.data(withJSONObject: json)).get())
        checkEqual(clip.remoteImages.count, 2)
        func problem(_ remote: [[String: Any]]) -> WebClip.Problem? {
            if case .failure(let p) = WebClip.parse(try! JSONSerialization.data(withJSONObject: ["remoteImages": remote])) { return p }
            return nil
        }
        checkEqual(problem([["name": "r.img", "url": "https://192.168.0.1/a.png"]]), .badField("remoteImages"), "локальный адрес не принимается")
        checkEqual(problem([["name": "../r.img", "url": "https://cdn.example.com/a.png"]]), .badField("remoteImages"))
        if case .success(let image) = WebClip.parse(try JSONSerialization.data(withJSONObject: ["mode": "image", "remoteImages": [["name": "image.img", "url": "https://cdn.example.com/a.png"]]])) {
            checkEqual(image.remoteImages.count, 1, "картинка по правому щелчку может прийти адресом")
        } else { check(false) }

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let resolved = clip.resolvingRemote(["remote-1.img": WebClip.Image(name: "remote-1.png", mime: "image/png", data: png)], label: "Картинка")
        checkEqual(resolved.markdown, "Текст\n\n![Схема](remote-1.png)\n\n[Картинка](https://cdn.example.com/2%281%29.jpg)",
                   "скачанная — вложение с настоящим расширением, нескачанная — ссылка на оригинал")
        checkEqual(resolved.images.map(\.name), ["remote-1.png"])
        check(resolved.remoteImages.isEmpty)

        checkEqual(WebClip.sniffImage(png)?.ext, "png")
        checkEqual(WebClip.sniffImage(Data([0xFF, 0xD8, 0xFF, 0xE0]))?.ext, "jpg")
        checkEqual(WebClip.sniffImage(Data("RIFF....WEBPVP8 ".utf8))?.ext, "webp")
        check(WebClip.sniffImage(Data("<svg xmlns=".utf8)) == nil, "SVG не принимается")
        check(WebClip.sniffImage(Data("<html>".utf8)) == nil, "страница ошибки вместо картинки отбрасывается")

        // Через импорт: картинка с CDN становится вложением страницы.
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let page = try await ClipImport.run(resolved, into: ws, parent: nil, ids: RandomIDs(), now: 1)
            let blocks = try await ws.blocks(ofPage: page.id)
            checkEqual(blocks.map(\.type), [.bookmark, .paragraph, .image, .paragraph])
        }
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
