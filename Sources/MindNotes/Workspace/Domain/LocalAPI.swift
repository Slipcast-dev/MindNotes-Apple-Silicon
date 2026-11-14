import Foundation

/// Локальный API для плагинов (ADR-0019): разбор HTTP/1.1, проверка источника и маршруты. Без сети: слушатель —
/// `Shell/Network/LocalAPIServer.swift`, здесь только данные, поэтому всё проверяется тестами.
enum LocalAPI {
    static let host = "127.0.0.1"
    static let port: UInt16 = 27183
    static let maxHeader = 16 * 1024
    static let maxBody = 40 * 1024 * 1024
    /// Что умеет это приложение (ADR-0019, п. 9). Клиент подстраивается под список, а не под номер версии MindNotes:
    /// так плагин обновляется независимо. Новая возможность — новое слово; `api` растёт только при несовместимости.
    static let features = ["clips", "targets", "openPage", "remoteImages", "pagesRead", "pagesWrite"]
    /// Вложение отдаётся целиком; больше — не отдаётся (у GitHub предел файла — 100 МБ).
    static let maxAssetBytes = 50 * 1024 * 1024

    struct Request: Equatable {
        var method: String
        var path: String
        var query: [String: String]
        /// Имена в нижнем регистре.
        var headers: [String: String]
        var body: Data

        var origin: String? { headers["origin"] }
        var bearer: String? {
            guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
            let token = value.dropFirst(7).trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? nil : token
        }
    }

    enum Parse: Equatable {
        case incomplete
        case request(Request)
        case invalid(status: Int)
    }

    /// Разбирает накопленные байты соединения. `incomplete` — нужно дочитать.
    static func parse(_ data: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeader ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeader, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 431)
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), start[0].allSatisfy({ $0.isUppercase }) else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .invalid(status: 400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Тело — только с Content-Length: chunked плагинам не нужен.
        if headers["transfer-encoding"] != nil { return .invalid(status: 501) }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid(status: 400) }
            guard n <= maxBody else { return .invalid(status: 413) }
            length = n
        }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(start[1])
        guard target.hasPrefix("/") else { return .invalid(status: 400) }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        return .request(Request(method: String(start[0]), path: path, query: query, headers: headers, body: Data(body)))
    }

    /// Обычный сайт не должен достучаться до API: из браузера принимаются только страницы расширений.
    /// Без заголовка Origin запрос пришёл не из браузера (программа на этом же Mac) — его проверяет токен.
    static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        let schemes = ["chrome-extension://", "safari-web-extension://", "moz-extension://"]
        return schemes.contains { origin.lowercased().hasPrefix($0) && origin.count > $0.count }
    }

    /// Имя браузера по источнику: для вопроса о привязке и списка подключений.
    static func browserName(origin: String?, userAgent: String?) -> String {
        let o = origin?.lowercased() ?? ""
        if o.hasPrefix("safari-web-extension://") { return "Safari" }
        if o.hasPrefix("moz-extension://") { return "Firefox" }
        let ua = userAgent ?? ""
        if o.hasPrefix("chrome-extension://") {
            if ua.contains("Edg/") { return "Edge" }
            if ua.contains("OPR/") { return "Opera" }
            if ua.contains("YaBrowser/") { return "Yandex" }
            if ua.contains("Arc/") { return "Arc" }
            return "Chrome"
        }
        return "Программа"
    }

    enum Route: Equatable {
        case options
        case status
        case pair
        case targets
        case clips
        case openPage(UUID)
        case pages
        case pageMarkdown(UUID)
        case writeMarkdown(UUID)
        case pageAsset(page: UUID, asset: UUID)
    }

    static func route(_ request: Request) -> Route? {
        if request.method == "OPTIONS" { return .options }
        switch (request.method, request.path) {
        case ("GET", "/v1/status"): return .status
        case ("POST", "/v1/pair"): return .pair
        case ("GET", "/v1/targets"): return .targets
        case ("POST", "/v1/clips"): return .clips
        case ("GET", "/v1/pages"): return .pages
        default: break
        }
        let parts = request.path.split(separator: "/")
        if request.method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "pages", parts[3] == "open", let id = UUID(uuidString: String(parts[2])) {
            return .openPage(id)
        }
        if request.method == "GET", parts.count == 4, parts[0] == "v1", parts[1] == "pages", parts[3] == "markdown", let id = UUID(uuidString: String(parts[2])) {
            return .pageMarkdown(id)
        }
        if request.method == "PUT", parts.count == 4, parts[0] == "v1", parts[1] == "pages", parts[3] == "markdown", let id = UUID(uuidString: String(parts[2])) {
            return .writeMarkdown(id)
        }
        if request.method == "GET", parts.count == 5, parts[0] == "v1", parts[1] == "pages", parts[3] == "assets",
           let id = UUID(uuidString: String(parts[2])), let asset = UUID(uuidString: String(parts[4])) {
            return .pageAsset(page: id, asset: asset)
        }
        return nil
    }

    /// Папка вложений в Markdown страницы: её выбирает плагин (путь в репозитории), приложение проверяет.
    /// Только относительный путь без `..`, до 200 символов; нет параметра — `files`.
    static func assetFolder(_ request: Request) -> String? {
        guard let raw = request.query["assets"] else { return "files" }
        guard (1...200).contains(raw.count), PluginManifest.isSafeRelativePath(raw), !raw.contains("\\"),
              raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return raw
    }

    /// Какое разрешение нужно маршруту; nil — без токена.
    static func permission(for route: Route) -> PluginPermission? {
        switch route {
        case .options, .status, .pair: return nil
        case .targets: return .pagesList
        case .clips: return .pagesCreate
        case .openPage: return .pagesOpen
        case .pages, .pageMarkdown, .pageAsset: return .pagesRead
        case .writeMarkdown: return .pagesWrite
        }
    }

    struct Response: Equatable {
        var status: Int
        var body: Data
        var contentType = "application/json; charset=utf-8"

        static func json(_ status: Int, _ object: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return Response(status: status, body: data)
        }

        /// Ошибка с машинным кодом и текстом для человека.
        static func error(_ status: Int, _ code: String, _ message: String) -> Response {
            json(status, ["error": ["code": code, "message": message]])
        }

        static let reasons: [Int: String] = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                                             403: "Forbidden", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large",
                                             429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
                                             501: "Not Implemented", 503: "Service Unavailable"]

        /// Ответ целиком. CORS — только для разрешённого источника; соединение закрывается после ответа.
        func serialized(origin: String?) -> Data {
            var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
            head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            if let origin, origin != "null", LocalAPI.isAllowedOrigin(origin) {
                head += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\n"
                head += "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\n"
                head += "Access-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 600\r\n"
            }
            var out = Data((head + "\r\n").utf8)
            out.append(body)
            return out
        }
    }
}
