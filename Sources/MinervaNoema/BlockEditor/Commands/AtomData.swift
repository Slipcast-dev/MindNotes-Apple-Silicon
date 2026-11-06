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

    static func rows(of block: Block) -> [[String]] {
        guard case .array(let rows)? = block.atomJSON["rows"] else { return [] }
        return rows.map { row in
            guard case .array(let cells) = row else { return [] }
            return cells.map { if case .string(let s) = $0 { return s } else { return "" } }
        }
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
