import Foundation

/// Вырезка из браузера (плагин WebClipper, ADR-0019): что прислал клиент, уже проверенное.
struct WebClip: Equatable {
    enum Mode: String, CaseIterable { case article, selection, bookmark, screenshot, image }

    struct Image: Equatable {
        /// Имя, на которое ссылается Markdown: `![подпись](имя)`.
        var name: String
        var mime: String
        var data: Data
    }

    var mode: Mode
    var title: String
    var url: URL?
    var markdown: String
    var excerpt: String?
    var siteName: String?
    var note: String?
    var tags: [String]
    var parent: UUID?
    var images: [Image]
    /// Картинки, которые браузер не смог скачать сам (другой сайт, CDN): их скачивает MindNotes по адресу.
    /// В тексте на них ссылаются по имени, как на обычные: `![подпись](remote-1.img)`.
    var remoteImages: [RemoteImage] = []

    struct RemoteImage: Equatable {
        var name: String
        var url: URL
    }

    static let maxTitle = 300
    static let maxMarkdown = 4 * 1024 * 1024
    static let maxImages = 80
    static let maxImageBytes = 20 * 1024 * 1024
    static let maxTotalImageBytes = 36 * 1024 * 1024
    static let maxTags = 20
    static let imageTypes = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic"]

    enum Problem: Error, Equatable {
        case unreadable
        case badField(String)
        case tooLarge(String)
    }

    /// JSON вырезки: `{mode, title, url, markdown, excerpt, siteName, note, tags, parent, images:[{name, mime, data(base64)}]}`.
    static func parse(_ data: Data) -> Result<WebClip, Problem> {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.unreadable) }
        guard let mode = Mode(rawValue: (o["mode"] as? String) ?? "article") else { return .failure(.badField("mode")) }
        func text(_ key: String, limit: Int) -> String? {
            guard let s = (o[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return String(s.prefix(limit))
        }
        // Адрес — только http(s): file: и прочие схемы в карточку не попадают.
        var url: URL?
        if let raw = o["url"] as? String, !raw.isEmpty {
            guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else {
                return .failure(.badField("url"))
            }
            url = u
        }
        let markdown = (o["markdown"] as? String) ?? ""
        guard markdown.utf8.count <= maxMarkdown else { return .failure(.tooLarge("markdown")) }
        var parent: UUID?
        if let raw = o["parent"] as? String, !raw.isEmpty {
            guard let id = UUID(uuidString: raw) else { return .failure(.badField("parent")) }
            parent = id
        }
        var tags: [String] = []
        for raw in (o["tags"] as? [Any]) ?? [] {
            guard let s = raw as? String else { return .failure(.badField("tags")) }
            let clean = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            if !clean.isEmpty, !tags.contains(where: { $0.lowercased() == clean.lowercased() }) { tags.append(clean) }
        }
        guard tags.count <= maxTags else { return .failure(.tooLarge("tags")) }

        let rawImages = (o["images"] as? [Any]) ?? []
        guard rawImages.count <= maxImages else { return .failure(.tooLarge("images")) }
        var images: [Image] = [], total = 0
        for raw in rawImages {
            guard let i = raw as? [String: Any], let name = i["name"] as? String, isSafeImageName(name),
                  let mime = (i["mime"] as? String)?.lowercased(), imageTypes[mime] != nil,
                  let b64 = i["data"] as? String, let bytes = Data(base64Encoded: b64), !bytes.isEmpty else { return .failure(.badField("images")) }
            guard bytes.count <= maxImageBytes else { return .failure(.tooLarge("images")) }
            guard !images.contains(where: { $0.name == name }) else { return .failure(.badField("images")) }
            total += bytes.count
            guard total <= maxTotalImageBytes else { return .failure(.tooLarge("images")) }
            images.append(Image(name: name, mime: mime, data: bytes))
        }
        let rawRemote = (o["remoteImages"] as? [Any]) ?? []
        guard rawRemote.count + images.count <= maxImages else { return .failure(.tooLarge("images")) }
        var remote: [RemoteImage] = []
        for raw in rawRemote {
            guard let r = raw as? [String: Any], let name = r["name"] as? String, isSafeImageName(name),
                  let link = (r["url"] as? String).flatMap(URL.init(string:)), isPublicWebURL(link),
                  !remote.contains(where: { $0.name == name }), !images.contains(where: { $0.name == name }) else { return .failure(.badField("remoteImages")) }
            remote.append(RemoteImage(name: name, url: link))
        }
        let fallbackTitle = url?.host ?? "Web"
        let clip = WebClip(mode: mode, title: text("title", limit: maxTitle) ?? fallbackTitle, url: url, markdown: markdown,
                           excerpt: text("excerpt", limit: 500), siteName: text("siteName", limit: 120), note: text("note", limit: 10_000),
                           tags: tags, parent: parent, images: images, remoteImages: remote)
        if (mode == .screenshot || mode == .image), images.isEmpty, remote.isEmpty { return .failure(.badField("images")) }
        if mode == .bookmark, url == nil { return .failure(.badField("url")) }
        return .success(clip)
    }

    /// Адрес, который MindNotes может скачать по просьбе расширения: только https и только публичный сайт.
    /// Локальные имена и адреса (localhost, .local, 10.x, 127.x, 169.254.x, 172.16–31.x, 192.168.x, IPv6) запрещены,
    /// чтобы через вырезку нельзя было обратиться к устройствам домашней сети. То же проверяется при переадресации.
    static func isPublicWebURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty, host.contains(".") else { return false }
        if host.contains(":") || host.hasPrefix("[") { return false }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home", ".arpa"] where host.hasSuffix(suffix) { return false }
        if host == "localhost" { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // Последняя часть — число (или 0x…): это IP-адрес, а у настоящих сайтов зона не бывает числом.
        // Принимается только строгая десятичная запись a.b.c.d без ведущих нулей: 0x7f.0.0.1 и 0177.0.0.1 — это 127.0.0.1.
        if let last = labels.last, last.allSatisfy({ $0.isHexDigit || $0 == "x" }), last.first?.isNumber == true {
            let strict = labels.count == 4 && labels.allSatisfy { label in
                !label.isEmpty && label.allSatisfy(\.isNumber) && (label == "0" || label.first != "0") && (Int(label).map { $0 <= 255 } ?? false)
            }
            guard strict else { return false }
            let parts = labels.map { Int($0) }
            guard let a = parts[0], let b = parts[1] else { return false }
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 100 && (64...127).contains(b) { return false }
        }
        return true
    }

    /// Публичный ли IP-адрес, в который разрешилось имя сайта (сеть ничего не делает: только разбор адреса).
    /// Текстовая проверка имени не видит, что обычное имя может указывать в домашнюю сеть, поэтому
    /// после DNS проверяется каждый адрес. Непонятная запись — не публичная.
    static func isPublicAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return isPublicIPv4(b[0], b[1], b[2], b[3])
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        // IPv4 внутри IPv6 (::ffff:a.b.c.d, ::a.b.c.d, NAT64 64:ff9b::/96) проверяется как IPv4.
        if b[0..<10].allSatisfy({ $0 == 0 }) && ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0)) {
            return isPublicIPv4(b[12], b[13], b[14], b[15])
        }
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy({ $0 == 0 }) {
            return isPublicIPv4(b[12], b[13], b[14], b[15])
        }
        if b[0] & 0xfe == 0xfc { return false }                       // fc00::/7 — частные
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }       // fe80::/10 — локальные для канала
        if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return false }       // fec0::/10 — устаревшие локальные
        if b[0] == 0xff { return false }                              // многоадресные
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false } // 2001:db8::/32 — документация
        return true
    }

    private static func isPublicIPv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        switch (a, b) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31), (100, 64...127), (198, 18...19): return false
        case (192, 0) where c == 0 || c == 2: return false
        case (198, 51) where c == 100: return false
        case (203, 0) where c == 113: return false
        default: return a < 224
        }
    }

    /// Подставляет скачанные приложением картинки: ссылка в тексте получает имя вложения с настоящим расширением.
    /// Не скачалась — остаётся ссылкой на оригинал с подписью (или `label`, если подписи нет).
    func resolvingRemote(_ fetched: [String: Image], label: String) -> WebClip {
        var clip = self
        for remote in remoteImages {
            if let image = fetched[remote.name] {
                clip.markdown = clip.markdown.replacingOccurrences(of: "](\(remote.name))", with: "](\(image.name))")
                clip.images.append(image)
            } else {
                let pattern = "!\\[([^\\]\\n]*)\\]\\(" + NSRegularExpression.escapedPattern(for: remote.name) + "\\)"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let target = remote.url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                let text = clip.markdown as NSString
                var out = clip.markdown
                for match in regex.matches(in: clip.markdown, range: NSRange(location: 0, length: text.length)).reversed() {
                    let alt = text.substring(with: match.range(at: 1))
                    out = (out as NSString).replacingCharacters(in: match.range, with: "[\(alt.isEmpty ? label : alt)](\(target))")
                }
                clip.markdown = out
            }
        }
        clip.remoteImages = []
        return clip
    }

    /// Тип картинки по первым байтам: заголовку Content-Type сайтов верить нельзя. SVG и прочее не принимаются.
    static func sniffImage(_ data: Data) -> (mime: String, ext: String)? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("image/gif", "gif") }
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return ("image/webp", "webp") }
        return nil
    }

    /// Имя вложения без путей: латиница, цифры, `.-_`, есть расширение.
    static func isSafeImageName(_ name: String) -> Bool {
        guard (1...100).contains(name.count), !name.hasPrefix("."), name.contains(".") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }
}
