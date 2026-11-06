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

    static func tableJSON(_ rows: [[String]]) -> String {
        json(["rows": .array(rows.map { .array($0.map { .string($0) }) })])
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
