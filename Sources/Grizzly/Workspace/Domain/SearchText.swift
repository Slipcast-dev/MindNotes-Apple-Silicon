import Foundation

/// Нормализация поиска: регистр и ё/е не различаются. Русская морфология не поддерживается: поиск по словам и префиксам.
enum SearchText {
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    static func tokens(_ query: String) -> [String] {
        normalize(query).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Запрос FTS5: все слова как префиксы. Слова только из букв и цифр, поэтому разметка запроса невозможна.
    static func match(_ query: String) -> String? {
        let words = tokens(query)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Фрагмент текста вокруг первого совпадения.
    static func snippet(_ text: String, query: String, radius: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let lowered = normalize(flat)
        guard let word = tokens(query).first, let hit = lowered.range(of: word) else { return String(flat.prefix(radius * 2)) }
        let at = lowered.distance(from: lowered.startIndex, to: hit.lowerBound)
        let start = max(0, at - radius)
        let slice = String(flat.dropFirst(start).prefix(radius * 2 + word.count))
        return (start > 0 ? "…" : "") + slice + (start + slice.count < flat.count ? "…" : "")
    }
}

/// Адрес страницы во внутренней ссылке.
enum PageLink {
    static let prefix = "notes://page/"

    static func mark(_ id: UUID) -> String { "a:\(prefix)\(id.uuidString.lowercased())" }

    static func page(fromMark mark: String) -> UUID? {
        guard mark.hasPrefix("a:\(prefix)") else { return nil }
        return UUID(uuidString: String(mark.dropFirst(2 + prefix.count).prefix(36)))
    }

    static func page(from url: URL) -> UUID? {
        guard url.absoluteString.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(url.absoluteString.dropFirst(prefix.count).prefix(36)))
    }

    /// Страницы, на которые ссылается блок.
    static func targets(of block: Block) -> Set<UUID> {
        guard let content = block.content else { return [] }
        return Set(content.runs.flatMap(\.marks).compactMap(page(fromMark:)))
    }
}

struct SearchHit: Equatable, Identifiable {
    var pageID: UUID
    var blockID: UUID?
    var title: String
    var snippet: String
    var id: UUID { pageID }
}

struct Backlink: Equatable, Identifiable {
    var pageID: UUID
    var blockID: UUID
    var title: String
    var text: String
    var id: UUID { blockID }
}

extension PageLink {
    /// Адрес блока: страница и якорь. Заголовки и тексты в адрес не входят.
    static func url(page: UUID, block: UUID) -> String { "\(prefix)\(page.uuidString.lowercased())#\(block.uuidString.lowercased())" }

    static func block(from url: URL) -> UUID? {
        url.fragment.flatMap(UUID.init(uuidString:))
    }
}
