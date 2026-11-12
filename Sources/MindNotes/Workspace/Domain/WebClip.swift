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
        let fallbackTitle = url?.host ?? "Web"
        let clip = WebClip(mode: mode, title: text("title", limit: maxTitle) ?? fallbackTitle, url: url, markdown: markdown,
                           excerpt: text("excerpt", limit: 500), siteName: text("siteName", limit: 120), note: text("note", limit: 10_000),
                           tags: tags, parent: parent, images: images)
        if (mode == .screenshot || mode == .image), images.isEmpty { return .failure(.badField("images")) }
        if mode == .bookmark, url == nil { return .failure(.badField("url")) }
        return .success(clip)
    }

    /// Имя вложения без путей: латиница, цифры, `.-_`, есть расширение.
    static func isSafeImageName(_ name: String) -> Bool {
        guard (1...100).contains(name.count), !name.hasPrefix("."), name.contains(".") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }
}
