import Foundation

/// Связи из экспорта Notion. В CSV связь записана текстом: `Заголовок (путь/к/записи.md)` через «, »;
/// в новых выгрузках вместо пути адрес `https://www.notion.so/…<id>`. Обе формы несут 32-значный ID записи.
enum NotionRelations {
    struct Reference: Equatable {
        var title: String
        /// Путь или адрес в скобках, как в ячейке (путь закодирован процентами).
        var target: String
    }

    private static let notionID = try! NSRegularExpression(pattern: #"[0-9a-f]{32}"#, options: [.caseInsensitive])
    /// Длиннее ячейка не разбирается: 1000 связей по ~100 символов, больше в одной ячейке не бывает.
    static let maxCell = 200_000

    /// Ссылки ячейки или nil, если ячейка целиком не из них. Пустая ячейка — пустой список.
    /// Разбор без регулярных выражений с возвратами: каждая ссылка кончается на «)» перед «, » или концом,
    /// а в скобках нет других скобок. Из возможных концов берётся ближайший, как у ленивого заголовка.
    static func references(_ cell: String) -> [Reference]? {
        let text = Array(cell.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
        guard !text.isEmpty else { return [] }
        guard text.count <= maxCell else { return nil }
        let open = UInt16(UInt8(ascii: "(")), close = UInt16(UInt8(ascii: ")")), space = UInt16(UInt8(ascii: " ")), comma = UInt16(UInt8(ascii: ","))
        var out: [Reference] = []
        var position = 0
        var lastOpen = -1        // последняя «(» в пределах текущей ссылки
        var closedSinceOpen = false  // после неё уже была «)»: в скобках цели скобок нет
        var k = position
        while k < text.count {
            let c = text[k]
            if c == open { lastOpen = k; closedSinceOpen = false }
            if c == close {
                defer { closedSinceOpen = true }
                let atEnd = k == text.count - 1
                let beforeNext = k + 2 < text.count && text[k + 1] == comma && text[k + 2] == space
                // Каждая «(» даёт не больше одной проверки: разбор линейный по длине ячейки.
                if (atEnd || beforeNext), !closedSinceOpen, lastOpen > position, text[lastOpen - 1] == space {
                    let title = String(decoding: text[position..<(lastOpen - 1)], as: UTF16.self)
                    let target = String(decoding: text[(lastOpen + 1)..<k], as: UTF16.self)
                    if isTarget(target) {
                        out.append(Reference(title: title, target: target))
                        position = atEnd ? text.count : k + 3
                        lastOpen = -1
                        closedSinceOpen = false
                        k = position
                        continue
                    }
                }
            }
            k += 1
        }
        return position == text.count ? out : nil
    }

    private static func isTarget(_ text: String) -> Bool {
        text.lowercased().hasSuffix(".md") || id(in: text) != nil
    }

    /// Столбец — связь, если в нём есть ссылки и каждая непустая ячейка состоит только из них.
    static func isRelationColumn(_ cells: [String]) -> Bool {
        var any = false
        for cell in cells {
            guard let refs = references(cell) else { return false }
            any = any || !refs.isEmpty
        }
        return any
    }

    /// Последний 32-значный ID в пути, адресе или имени файла, строчными буквами.
    static func id(in text: String) -> String? {
        let decoded = text.removingPercentEncoding ?? text
        let ns = decoded as NSString
        return notionID.matches(in: decoded, range: NSRange(location: 0, length: ns.length)).last.map { ns.substring(with: $0.range).lowercased() }
    }

    /// Notion повторяет свойства записи строками `Имя: значение` сразу под заголовком; в базе они уже есть.
    /// Убираются только ведущие абзацы, каждая строка которых начинается с имени свойства этой базы.
    static func dropPropertyCard(_ fragments: [BlockFragment], names: Set<String>) -> [BlockFragment] {
        guard !names.isEmpty else { return fragments }
        var rest = fragments[...]
        while let first = rest.first, first.type == BlockType.paragraph.rawValue, isCard(first.plain, names: names) { rest = rest.dropFirst() }
        return Array(rest)
    }

    private static func isCard(_ text: String, names: Set<String>) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return !lines.isEmpty && lines.allSatisfy { line in
            guard let colon = line.range(of: ": ") ?? (line.hasSuffix(":") ? line.range(of: ":", options: .backwards) : nil) else { return false }
            return names.contains(SearchText.normalize(String(line[..<colon.lowerBound])))
        }
    }
}
