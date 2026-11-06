import Foundation

/// Страница рабочего пространства. Ключ — UUID; заголовок не уникален.
struct Page: Equatable, Identifiable {
    var id: UUID
    var parentID: UUID?
    var sortKey: String
    var title: String
    var icon: String?
    var coverAssetID: UUID?
    var fullWidth: Bool
    var favoriteKey: String?
    var createdAt: Int64
    var updatedAt: Int64
    var lastOpenedAt: Int64?
    var deletedAt: Int64?
    var trashBatchID: UUID?
    var contentRev: Int64

    init(id: UUID, parentID: UUID? = nil, sortKey: String, title: String, createdAt: Int64) {
        self.id = id
        self.parentID = parentID
        self.sortKey = sortKey
        self.title = title
        fullWidth = false
        self.createdAt = createdAt
        updatedAt = createdAt
        contentRev = 0
    }
}

/// Тип блока. Строка, а не закрытый enum: неизвестный тип из более новой версии сохраняется как есть.
struct BlockType: RawRepresentable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let paragraph = BlockType(rawValue: "paragraph")
    static let heading1 = BlockType(rawValue: "heading1")
    static let heading2 = BlockType(rawValue: "heading2")
    static let heading3 = BlockType(rawValue: "heading3")
    static let task = BlockType(rawValue: "task")

    /// Типы, которые понимает эта версия. Расширяется вместе с редактором.
    static let known: Set<BlockType> = [.paragraph, .heading1, .heading2, .heading3, .task]
    var isKnown: Bool { Self.known.contains(self) }
}

/// Содержимое понятного блока: отрезки, отметка задачи и неизвестные поля без потерь.
struct BlockContent: Equatable {
    static let currentVersion = 1

    var runs: [TextRun]
    var checked: Bool
    var extra: [String: JSONValue]

    init(runs: [TextRun] = [], checked: Bool = false, extra: [String: JSONValue] = [:]) {
        self.runs = RichText.normalized(runs)
        self.checked = checked
        self.extra = extra
    }

    init(text: String) { self.init(runs: [TextRun(text)]) }

    var plainText: String { RichText.plain(runs) }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              case .object(var o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        var parsed: [TextRun] = []
        if case .array(let list)? = o.removeValue(forKey: "runs") {
            for item in list {
                guard let run = TextRun(json: item) else { return nil }
                parsed.append(run)
            }
        }
        var isChecked = false
        if case .bool(let v)? = o.removeValue(forKey: "checked") { isChecked = v }
        runs = parsed
        checked = isChecked
        extra = o
    }

    func jsonString() throws -> String {
        var o = extra
        o["runs"] = .array(runs.map(\.json))
        if checked { o["checked"] = .bool(true) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(o))
        return String(decoding: data, as: UTF8.self)
    }
}

/// Содержимое блока в модели. `opaque` — неизвестный тип или более новая версия: исходная строка не трогается.
enum BlockPayload: Equatable {
    case content(BlockContent)
    case opaque(String)
}

struct Block: Equatable, Identifiable {
    var id: UUID
    var pageID: UUID
    var parentID: UUID?
    var sortKey: String
    var type: BlockType
    var contentVersion: Int
    var payload: BlockPayload
    /// Текст для поиска. У opaque-блока хранится прочитанное значение.
    var plainText: String
    var createdAt: Int64
    var updatedAt: Int64

    init(id: UUID, pageID: UUID, parentID: UUID? = nil, sortKey: String, type: BlockType = .paragraph,
         content: BlockContent = BlockContent(), createdAt: Int64) {
        self.id = id
        self.pageID = pageID
        self.parentID = parentID
        self.sortKey = sortKey
        self.type = type
        contentVersion = BlockContent.currentVersion
        payload = .content(content)
        plainText = content.plainText
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    /// Восстановление из хранилища: всё непонятное остаётся непрозрачным.
    init(id: UUID, pageID: UUID, parentID: UUID?, sortKey: String, type: BlockType, contentVersion: Int,
         contentJSON: String, plainText: String, createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.pageID = pageID
        self.parentID = parentID
        self.sortKey = sortKey
        self.type = type
        self.contentVersion = contentVersion
        if type.isKnown, contentVersion <= BlockContent.currentVersion, let content = BlockContent(json: contentJSON) {
            payload = .content(content)
        } else {
            payload = .opaque(contentJSON)
        }
        self.plainText = plainText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var content: BlockContent? {
        if case .content(let c) = payload { return c }
        return nil
    }

    var isEditable: Bool { content != nil }

    func contentJSON() throws -> String {
        switch payload {
        case .content(let c): return try c.jsonString()
        case .opaque(let raw): return raw
        }
    }

    mutating func setContent(_ c: BlockContent) {
        payload = .content(c)
        plainText = c.plainText
    }
}

/// Контрольный снимок страницы.
struct Revision: Equatable, Identifiable {
    var id: UUID
    var pageID: UUID
    var seq: Int
    var createdAt: Int64
    var reason: String
    var contentHash: String
    var byteSize: Int
}

/// Управляемое вложение; путь относителен пространству.
struct AssetRecord: Equatable, Identifiable {
    var id: UUID
    var relPath: String
    var originalName: String
    var mime: String?
    var byteSize: Int64
    var sha256: String
    var createdAt: Int64
}
