import Foundation

/// Страница рабочего пространства. Ключ — UUID; заголовок не уникален.
struct Page: Equatable, Identifiable {
    /// Значок страницы-папки в дереве.
    static let folderIcon = "folder"
    var isFolder: Bool { icon == Self.folderIcon }
    /// Значок-emoji; у папки значок задан символом.
    var emoji: String? { icon == Self.folderIcon ? nil : icon }

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
    /// База, в которую входит страница как запись; страница входит не более чем в одну (FR-10).
    var databaseID: UUID?

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
    static let bullet = BlockType(rawValue: "bullet")
    static let numbered = BlockType(rawValue: "numbered")
    static let quote = BlockType(rawValue: "quote")
    static let callout = BlockType(rawValue: "callout")
    static let toggle = BlockType(rawValue: "toggle")
    static let code = BlockType(rawValue: "code")
    static let divider = BlockType(rawValue: "divider")
    static let image = BlockType(rawValue: "image")
    static let file = BlockType(rawValue: "file")
    static let video = BlockType(rawValue: "video")
    static let table = BlockType(rawValue: "table")
    static let databaseView = BlockType(rawValue: "database_view")
    /// Закладка и встраивание (M12): адрес, подпись и превью.
    static let bookmark = BlockType(rawValue: "bookmark")
    static let embed = BlockType(rawValue: "embed")
    /// Синхронизированный блок (M12, ADR-0012): оригинал с детьми и копия, показывающая детей оригинала.
    static let synced = BlockType(rawValue: "synced_block")
    static let syncedRef = BlockType(rawValue: "synced_ref")
    /// Колонки (M13, ADR-0013): ряд `column_list` из 2–5 `column` с долями ширины; в колонках — обычные блоки.
    static let columnList = BlockType(rawValue: "column_list")
    static let column = BlockType(rawValue: "column")

    /// Текстовые типы этой версии. Всё остальное хранится непрозрачно и показывается одним неделимым символом.
    static let known: Set<BlockType> = [.paragraph, .heading1, .heading2, .heading3, .task, .bullet, .numbered, .quote, .callout, .toggle, .code]
    var isKnown: Bool { Self.known.contains(self) }
    /// Известные неделимые блоки: у них нет текста, данные лежат в JSON.
    static let atoms: Set<BlockType> = [.divider, .image, .video, .file, .table, .databaseView, .bookmark, .embed, .synced, .syncedRef, .columnList, .column]
    var isAtom: Bool { Self.atoms.contains(self) }
    var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }
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

/// Цвет блока (M12), как в Notion: цвет текста `red` или фон `red_background` на весь блок с вложенными.
enum BlockColor {
    static let names = ["gray", "brown", "orange", "yellow", "green", "blue", "purple", "pink", "red"]
    static let backgroundSuffix = "_background"

    /// Допустимое значение или nil: незнакомое имя не записывается.
    static func valid(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = value.hasSuffix(backgroundSuffix) ? String(value.dropLast(backgroundSuffix.count)) : value
        return names.contains(name) ? value : nil
    }

    static func isBackground(_ value: String) -> Bool { value.hasSuffix(backgroundSuffix) }
    static func name(_ value: String) -> String { isBackground(value) ? String(value.dropLast(backgroundSuffix.count)) : value }
}

extension BlockContent {
    /// Цвет блока; хранится в неизвестных для старых версий полях, поэтому они его не теряют.
    var color: String? {
        get { if case .string(let s)? = extra["color"] { return BlockColor.valid(s) }; return nil }
        set { extra["color"] = BlockColor.valid(newValue).map { .string($0) } }
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

    /// Неделимый блок, например разделитель.
    init(atom type: BlockType, id: UUID, pageID: UUID, parentID: UUID?, sortKey: String, createdAt: Int64) {
        self.init(id: id, pageID: pageID, parentID: parentID, sortKey: sortKey, type: type, contentVersion: 1,
                  contentJSON: "{}", plainText: "", createdAt: createdAt, updatedAt: createdAt)
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

    /// Данные неделимого блока (изображение, файл, таблица).
    var atomJSON: [String: JSONValue] {
        guard case .opaque(let raw) = payload, let data = raw.data(using: .utf8),
              case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return o
    }

    /// Вложение изображения или файла.
    var assetID: UUID? {
        // У закладки вложение — картинка превью: так она защищена от уборки и попадает в резервную копию.
        guard type == .image || type == .video || type == .file || type == .bookmark, case .string(let s)? = atomJSON["asset"] else { return nil }
        return UUID(uuidString: s)
    }

    /// Свёрнутый блок скрывает потомков.
    var isCollapsed: Bool {
        if type == .toggle, case .bool(true)? = content?.extra["collapsed"] { return true }
        return false
    }

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
