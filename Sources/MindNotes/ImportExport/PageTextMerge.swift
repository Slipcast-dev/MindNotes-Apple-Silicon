import Foundation

/// Перенос правок из Markdown (например, с GitHub) в страницу: меняются **только текстовые блоки** (ADR-0019, п. 13).
///
/// Обе стороны сравниваются в одном виде: текущие блоки проходят тот же путь «экспорт → разбор», что и пришедший текст,
/// поэтому неизменённое совпадает само, какие бы особенности ни были у экспорта. Совпавший блок не трогается вовсе
/// (цвет, комментарии, оформление сохраняются). Изменённый текстовый блок получает новый текст на том же месте.
/// Блоки, которые Markdown не выражает (картинки, файлы, таблицы, колонки, синхронизированные блоки, сворачиваемые,
/// выноски, базы), и всё внутри них не меняются и не удаляются, даже если их строки на GitHub убрали.
enum PageTextMerge {
    /// Что можно менять: то, что Markdown передаёт без потерь.
    static let textTypes: Set<BlockType> = [.paragraph, .heading1, .heading2, .heading3, .bullet, .numbered, .task, .quote, .code]
    /// Предел сравнения: страница из тысяч блоков переносится целиком только вручную.
    static let maxFragments = 3000

    struct Result: Equatable {
        /// Блоки страницы после переноса — полностью, в порядке документа.
        var blocks: [Block]
        var changed = 0
        var added = 0
        var removed = 0
        /// Строки, убранные на GitHub, чьи блоки Markdown не выражает: блоки оставлены.
        var kept = 0
        var isEmpty: Bool { changed == 0 && added == 0 && removed == 0 }
    }

    enum Problem: Error, Equatable {
        case tooLarge
    }

    private struct Piece {
        var key: String
        var fragment: BlockFragment
        var owner: Int?
    }

    static func merge(blocks unordered: [Block], pageID: UUID, markdown: String, now: Int64,
                      newID: () -> UUID) throws -> Result {
        let blocks = BlockDocument(pageID: pageID, blocks: unordered).blocks
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hasChildren = Set(blocks.compactMap(\.parentID))

        // Блок можно менять, если он текстовый, сам по себе даёт ровно одну строку и все его предки — тоже текст.
        func insideText(_ block: Block) -> Bool {
            var parent = block.parentID, steps = 0
            while let id = parent, steps < 64 {
                guard let p = byID[id], textTypes.contains(p.type) else { return false }
                parent = p.parentID
                steps += 1
            }
            return true
        }

        var old: [Piece] = []
        var pieceCount: [Int: Int] = [:]
        for (i, block) in blocks.enumerated() {
            var lone = block
            lone.parentID = nil
            let text = MarkdownExport.export(title: "", blocks: [lone], assetFolder: "files") { _ in nil }.markdown
            let pieces = fragments(text, dropTitle: true)
            pieceCount[i] = pieces.count
            old += pieces.map { Piece(key: key($0), fragment: $0, owner: i) }
        }
        let new = fragments(markdown, dropTitle: true).map { Piece(key: key($0), fragment: $0, owner: nil) }
        guard old.count <= maxFragments, new.count <= maxFragments else { throw Problem.tooLarge }

        func editable(_ i: Int) -> Bool {
            let block = blocks[i]
            return textTypes.contains(block.type) && pieceCount[i] == 1 && insideText(block) && block.content != nil
        }

        var result = Result(blocks: [])
        var replaced: [Int: Block] = [:]
        var removed: Set<Int> = []
        // Новые блоки после блока с номером (nil — в начало страницы), по порядку.
        var inserted: [Int?: [BlockFragment]] = [:]
        var anchor: Int?

        func flush(_ deletes: [Int], _ inserts: [BlockFragment]) {
            var queue = inserts
            for i in deletes {
                let owner = old[i].owner!
                if editable(owner), let next = queue.first, let type = textType(next) {
                    // Строку заменили: тот же блок получает новый текст (и вид, если сменился).
                    queue.removeFirst()
                    replaced[owner] = rewritten(blocks[owner], type: type, fragment: next, now: now)
                    result.changed += 1
                    anchor = owner
                } else if editable(owner) && !hasChildren.contains(blocks[owner].id) {
                    removed.insert(owner)
                    result.removed += 1
                } else {
                    result.kept += 1
                    anchor = owner
                }
            }
            let fresh = queue.filter { textType($0) != nil }
            if !fresh.isEmpty { inserted[anchor, default: []] += fresh }
        }

        var deletes: [Int] = [], inserts: [BlockFragment] = []
        for step in align(old.map(\.key), new.map(\.key)) {
            switch step {
            case .same(let i, _):
                flush(deletes, inserts)
                deletes = []; inserts = []
                anchor = old[i].owner
            case .delete(let i): deletes.append(i)
            case .insert(let j): inserts.append(new[j].fragment)
            }
        }
        flush(deletes, inserts)

        // Итог: прежние блоки на месте (заменённые — с новым текстом), удалённые убраны, новые — после своего соседа.
        var out: [Block] = []
        var keys: [UUID?: [String]] = [:]
        for block in blocks { keys[block.parentID, default: []].append(block.sortKey) }
        func nextKey(after key: String?, parent: UUID?) -> String? {
            let siblings = (keys[parent] ?? []).sorted()
            guard let key else { return siblings.first }
            return siblings.first { $0 > key }
        }
        func place(_ list: [BlockFragment], after block: Block?) {
            let parent = block?.parentID
            var previous = block?.sortKey
            let limit = nextKey(after: previous, parent: parent)
            for fragment in list {
                guard let type = textType(fragment), let content = fragment.content else { continue }
                let sortKey = SortKey.between(previous, limit)
                out.append(Block(id: newID(), pageID: pageID, parentID: parent, sortKey: sortKey, type: type,
                                 content: content, createdAt: now))
                previous = sortKey
                keys[parent, default: []].append(sortKey)
                result.added += 1
            }
        }
        place(inserted[nil] ?? [], after: nil)
        for (i, block) in blocks.enumerated() {
            if !removed.contains(i) { out.append(replaced[i] ?? block) }
            if let list = inserted[i] { place(list, after: block) }
        }
        result.blocks = BlockDocument(pageID: pageID, blocks: out).blocks
        return result
    }

    // MARK: Разбор

    /// Markdown страницы в строки-фрагменты. Экспорт пишет заголовок страницы `# …`, а заголовки блоков — на уровень ниже
    /// (`##`…`####`); здесь заголовок снимается, а уровни возвращаются, чтобы разбор дал те же виды блоков.
    static func fragments(_ markdown: String, dropTitle: Bool) -> [BlockFragment] {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if dropTitle, let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# ") {
            lines.remove(at: first)
        }
        var inCode = false
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            guard !inCode else { continue }
            for level in [4, 3, 2] where trimmed.hasPrefix(String(repeating: "#", count: level) + " ") {
                lines[i] = String(trimmed.dropFirst())
                break
            }
        }
        let image: (String, String) -> BlockFragment? = { alt, _ in
            BlockFragment(type: BlockType.image.rawValue, contentVersion: 1, json: "{}", plain: alt)
        }
        return MarkdownImport.fragments(from: lines.joined(separator: "\n"), image: image)
    }

    private static func key(_ fragment: BlockFragment) -> String {
        // Нумерация и отметка задачи — часть смысла: «[x]» отличается от «[ ]».
        let checked = fragment.content?.checked == true ? "1" : "0"
        return fragment.type + "\u{1}" + checked + "\u{1}" + fragment.plain
    }

    private static func textType(_ fragment: BlockFragment) -> BlockType? {
        let type = BlockType(rawValue: fragment.type)
        return textTypes.contains(type) && fragment.content != nil ? type : nil
    }

    /// Тот же блок с новым текстом: цвет и прочие свойства блока остаются, оформление текста — из Markdown.
    private static func rewritten(_ block: Block, type: BlockType, fragment: BlockFragment, now: Int64) -> Block {
        let incoming = fragment.content ?? BlockContent()
        let extra = block.content?.extra ?? [:]
        var out = Block(id: block.id, pageID: block.pageID, parentID: block.parentID, sortKey: block.sortKey, type: type,
                        content: BlockContent(runs: incoming.runs, checked: incoming.checked, extra: extra), createdAt: block.createdAt)
        out.updatedAt = now
        return out
    }

    // MARK: Сравнение

    enum Step: Equatable {
        case same(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// Наибольшая общая подпоследовательность: какие строки остались, какие убраны и какие добавлены.
    static func align(_ a: [String], _ b: [String]) -> [Step] {
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var steps: [Step] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { steps.append(.same(i, j)); i += 1; j += 1 }
            else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] { steps.append(.insert(j)); j += 1 }
            else { steps.append(.delete(i)); i += 1 }
        }
        return steps
    }
}
