import Foundation

/// Закладка и встраивание (M12, ADR-0011): адреса, распознавание сервисов и разбор `og:`-метаданных.
/// Здесь нет сети — только разбор текста; запрос делает оболочка по действию пользователя.
enum LinkCard {
    /// Пределы: ответ страницы, картинка и поля карточки.
    static let maxHTMLBytes = 2 * 1024 * 1024
    static let maxImageBytes = 5 * 1024 * 1024
    static let maxTitle = 300
    static let maxDescription = 600

    struct Preview: Equatable {
        var title: String?
        var description: String?
        var image: URL?
    }

    /// Адрес из вставленного текста: одна строка без пробелов, схема http или https (домен без схемы — https).
    static func url(_ text: String) -> URL? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(where: \.isWhitespace), let url = PropertyParse.openable(clean),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Сервис встраивания и адрес для окна: YouTube и Vimeo — проигрыватель, Figma — режим встраивания, остальное — сама страница.
    static func embed(_ url: URL) -> (provider: String, url: URL) {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host == "youtu.be", let id = parts.first, valid(id) { return ("YouTube", URL(string: "https://www.youtube-nocookie.com/embed/\(id)")!) }
        if host.hasSuffix("youtube.com") {
            if let id = query.first(where: { $0.name == "v" })?.value, valid(id) { return ("YouTube", URL(string: "https://www.youtube-nocookie.com/embed/\(id)")!) }
            if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]), valid(parts[1]) {
                return ("YouTube", URL(string: "https://www.youtube-nocookie.com/embed/\(parts[1])")!)
            }
            return ("YouTube", url)
        }
        if host.hasSuffix("vimeo.com") {
            if let id = parts.last(where: { $0.allSatisfy(\.isNumber) }) { return ("Vimeo", URL(string: "https://player.vimeo.com/video/\(id)")!) }
            return ("Vimeo", url)
        }
        if host.hasSuffix("figma.com") {
            var c = URLComponents(string: "https://www.figma.com/embed")!
            c.queryItems = [URLQueryItem(name: "embed_host", value: "share"), URLQueryItem(name: "url", value: url.absoluteString)]
            return ("Figma", c.url ?? url)
        }
        if host == "maps.app.goo.gl" || host == "goo.gl" && parts.first == "maps" || (host.hasPrefix("google.") || host.contains(".google.")) && parts.first == "maps"
            || host == "maps.google.com" {
            return ("Google Maps", url)
        }
        return (host.isEmpty ? url.absoluteString : host, url)
    }

    private static func valid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Метаданные страницы: `og:` важнее `twitter:`, затем `<title>` и `description`. Картинка — только https.
    static func parse(html: String, base: URL) -> Preview {
        let head = String(html.prefix(400_000))
        var meta: [String: String] = [:]
        for tag in tags(named: "meta", in: head) {
            let attrs = attributes(of: tag)
            guard let key = (attrs["property"] ?? attrs["name"])?.lowercased(), let value = attrs["content"], meta[key] == nil else { continue }
            meta[key] = value
        }
        let title = meta["og:title"] ?? meta["twitter:title"] ?? titleTag(head)
        let description = meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]
        var image: URL?
        if let raw = meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"],
           let resolved = URL(string: decode(raw).trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
           resolved.scheme?.lowercased() == "https" {
            image = resolved
        }
        return Preview(title: clip(title, maxTitle), description: clip(description, maxDescription), image: image)
    }

    private static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let text else { return nil }
        let clean = decode(text).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !clean.isEmpty else { return nil }
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    private static func tags(named name: String, in html: String) -> [Substring] {
        var out: [Substring] = []
        var rest = html[...]
        while let open = rest.range(of: "<" + name, options: .caseInsensitive) {
            guard let close = rest[open.upperBound...].firstIndex(of: ">") else { break }
            out.append(rest[open.upperBound..<close])
            rest = rest[rest.index(after: close)...]
            if out.count > 500 { break }
        }
        return out
    }

    /// Атрибуты тега: значения в двойных или одинарных кавычках.
    private static func attributes(of tag: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var i = tag.startIndex
        while i < tag.endIndex {
            while i < tag.endIndex, tag[i].isWhitespace || tag[i] == "/" { i = tag.index(after: i) }
            let nameStart = i
            while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != "=", tag[i] != ">" { i = tag.index(after: i) }
            let name = tag[nameStart..<i].lowercased()
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex, tag[i] == "=" else { if name.isEmpty { break }; continue }
            i = tag.index(after: i)
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex else { break }
            let quote = tag[i]
            if quote == "\"" || quote == "'" {
                let start = tag.index(after: i)
                guard let end = tag[start...].firstIndex(of: quote) else { break }
                out[name] = String(tag[start..<end])
                i = tag.index(after: end)
            } else {
                let start = i
                while i < tag.endIndex, !tag[i].isWhitespace { i = tag.index(after: i) }
                out[name] = String(tag[start..<i])
            }
        }
        return out
    }

    private static func titleTag(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let start = html[open.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: html.index(after: start)..<html.endIndex) else { return nil }
        return String(html[html.index(after: start)..<close.lowerBound])
    }

    /// Самые частые сущности HTML; остальные остаются как есть.
    static func decode(_ text: String) -> String {
        var out = text
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&mdash;", "—"), ("&laquo;", "«"), ("&raquo;", "»")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out
    }
}
