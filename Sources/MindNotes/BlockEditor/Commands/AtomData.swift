import Foundation

/// Данные неделимых блоков в виде фрагментов для вставки.
enum AtomData {
    private static func json(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSONValue.object(object))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func attachment(type: BlockType, asset: AssetRecord) -> BlockFragment {
        BlockFragment(type: type.rawValue, contentVersion: 1,
                      json: json(["asset": .string(asset.id.uuidString.lowercased()), "name": .string(asset.originalName), "size": .int(asset.byteSize)]),
                      plain: asset.originalName)
    }

    /// Прочие поля блока сохраняются: их могла записать более новая версия.
    static func tableJSON(_ rows: [[String]], keeping base: [String: JSONValue] = [:]) -> String {
        var object = base
        object["rows"] = .array(rows.map { .array($0.map { .string($0) }) })
        return json(object)
    }

    /// Таблицу можно править, только если её формат понятен этой версии.
    static func isEditableTable(_ block: Block) -> Bool {
        guard block.type == .table, block.contentVersion <= 1, case .array(let rows)? = block.atomJSON["rows"] else { return false }
        return rows.allSatisfy { row in
            guard case .array(let cells) = row else { return false }
            return cells.allSatisfy { if case .string = $0 { return true } else { return false } }
        }
    }

    static func tablePlain(_ rows: [[String]]) -> String { rows.flatMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }

    static func table(_ rows: [[String]]) -> BlockFragment {
        BlockFragment(type: BlockType.table.rawValue, contentVersion: 1, json: tableJSON(rows), plain: tablePlain(rows))
    }

    /// Встроенное представление: страница базы, вид и собственное состояние. Записи не копируются (FR-11).
    static func databaseView(page: UUID, kind: String, state: String) -> BlockFragment {
        BlockFragment(type: BlockType.databaseView.rawValue, contentVersion: 1, json: databaseViewJSON(page: page, kind: kind, state: state), plain: "")
    }

    static func databaseViewJSON(page: UUID, kind: String, state: String, keeping base: [String: JSONValue] = [:]) -> String {
        var object = base
        object["page"] = .string(page.uuidString.lowercased())
        object["kind"] = .string(kind)
        if let data = state.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) { object["state"] = parsed }
        return json(object)
    }

    static func viewPage(of block: Block) -> UUID? {
        guard case .string(let s)? = block.atomJSON["page"] else { return nil }
        return UUID(uuidString: s)
    }

    static func viewKind(of block: Block) -> String {
        if case .string(let s)? = block.atomJSON["kind"] { return s }
        return "table"
    }

    /// Состояние встроенного представления строкой JSON: разбор и неизвестные поля — забота `DatabaseViewState`.
    static func viewState(of block: Block) -> String {
        guard let state = block.atomJSON["state"], let data = try? JSONEncoder().encode(state) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func rows(of block: Block) -> [[String]] {
        guard case .array(let rows)? = block.atomJSON["rows"] else { return [] }
        return rows.map { row in
            guard case .array(let cells) = row else { return [] }
            return cells.map { if case .string(let s) = $0 { return s } else { return "" } }
        }
    }

    /// Закладка: адрес, заголовок, описание и картинка превью; пустые поля не пишутся. Прочие поля сохраняются.
    static func bookmarkJSON(url: URL, title: String?, description: String?, asset: UUID?, keeping base: [String: JSONValue] = [:]) -> String {
        var object = base
        object["url"] = .string(url.absoluteString)
        object["title"] = title.map { .string($0) }
        object["description"] = description.map { .string($0) }
        object["asset"] = asset.map { .string($0.uuidString.lowercased()) }
        return json(object)
    }

    static func bookmark(url: URL, title: String? = nil, description: String? = nil, asset: UUID? = nil) -> BlockFragment {
        BlockFragment(type: BlockType.bookmark.rawValue, contentVersion: 1, json: bookmarkJSON(url: url, title: title, description: description, asset: asset),
                      plain: linkPlain(url: url, title: title))
    }

    static func embed(url: URL) -> BlockFragment {
        let provider = LinkCard.embed(url).provider
        return BlockFragment(type: BlockType.embed.rawValue, contentVersion: 1,
                             json: json(["url": .string(url.absoluteString), "provider": .string(provider)]), plain: linkPlain(url: url, title: provider))
    }

    /// Текст для поиска: заголовок и адрес.
    static func linkPlain(url: URL, title: String?) -> String { [title, url.absoluteString].compactMap { $0 }.joined(separator: " ") }

    static func url(of block: Block) -> URL? {
        guard case .string(let s)? = block.atomJSON["url"] else { return nil }
        return LinkCard.url(s)
    }

    static func string(_ key: String, of block: Block) -> String? {
        if case .string(let s)? = block.atomJSON[key], !s.isEmpty { return s }
        return nil
    }

    static func name(of block: Block) -> String {
        if case .string(let s)? = block.atomJSON["name"] { return s }
        return block.plainText
    }

    static func size(of block: Block) -> Int64 {
        if case .int(let v)? = block.atomJSON["size"] { return v }
        return 0
    }
}
