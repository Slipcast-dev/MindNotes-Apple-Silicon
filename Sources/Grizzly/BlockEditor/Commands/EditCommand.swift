import Foundation

/// Правки документа. Любое изменение блоков идёт только через эти команды: они проверяются без UI.
/// В M2 — операции внутри одного блока; выделение через блоки и вложенность добавляет прототип M3.
enum EditCommand: Equatable {
    case replaceText(block: UUID, range: Range<Int>, text: String)
    /// Заменяет текст поля целиком, вычисляя минимальную правку: форматирование остальной части сохраняется.
    case setPlainText(block: UUID, text: String)
    case splitBlock(BlockPoint)
    case mergeBackward(block: UUID)
    case insertBlock(after: UUID?, type: BlockType)
    case deleteBlock(UUID)
    case changeType(block: UUID, type: BlockType)
    case setChecked(block: UUID, checked: Bool)
}

enum EditError: Error, Equatable {
    case blockNotFound(UUID)
    /// Неизвестный тип или более новая версия: блок показывается, но не меняется.
    case notEditable(UUID)
}

struct EditResult: Equatable {
    var document: BlockDocument
    var changes: [BlockChange]
    var inverse: [BlockChange]
    var selection: BlockSelection?
    /// Правки с одним ключом склеиваются в один шаг отмены.
    var coalesceKey: String?
}

enum BlockEditing {
    /// Чистая функция: id и время внедряются, результат зависит только от аргументов.
    static func apply(_ command: EditCommand, to document: BlockDocument, ids: IDGenerator, now: Int64) throws -> EditResult {
        func editable(_ id: UUID) throws -> (Block, BlockContent) {
            guard let b = document.block(id) else { throw EditError.blockNotFound(id) }
            guard let c = b.content else { throw EditError.notEditable(id) }
            return (b, c)
        }
        func result(_ changes: [BlockChange], selection: BlockSelection?, key: String? = nil) -> EditResult {
            var d = document
            d.apply(changes)
            let inverse = changes.reversed().map { change -> BlockChange in
                switch change {
                case .upsert(let b): return document.block(b.id).map { .upsert($0) } ?? .delete(b.id)
                case .delete(let id): return .upsert(document.block(id)!)
                }
            }
            return EditResult(document: d, changes: changes, inverse: Array(inverse), selection: selection, coalesceKey: key)
        }
        /// Ключ между соседями; слишком длинный ключ перенумеровывает соседей той же операцией.
        func place(parent: UUID?, after anchor: Block?, upper: String?, id: UUID) -> (key: String, renumbered: [BlockChange]) {
            let key = SortKey.between(anchor?.sortKey, upper)
            guard key.utf8.count > SortKey.maxLength else { return (key, []) }
            let siblings = document.blocks.filter { $0.parentID == parent }
            let at = anchor.flatMap { a in siblings.firstIndex { $0.id == a.id } }.map { $0 + 1 } ?? 0
            let keys = SortKey.keys(after: nil, before: nil, count: siblings.count + 1)
            var changes: [BlockChange] = []
            for (i, sibling) in siblings.enumerated() {
                var moved = sibling
                moved.sortKey = keys[i < at ? i : i + 1]
                changes.append(.upsert(moved))
            }
            return (keys[at], changes)
        }
        func updated(_ b: Block, _ c: BlockContent) -> Block {
            var n = b
            n.setContent(c)
            n.updatedAt = now
            return n
        }

        switch command {
        case let .replaceText(id, range, text):
            let (b, c) = try editable(id)
            var n = c
            n.runs = RichText.replace(c.runs, range: range, with: text)
            let caret = RichText.snap(n.plainText, range.lowerBound) + text.utf16.count
            return result([.upsert(updated(b, n))], selection: BlockSelection(block: id, offset: caret), key: "text:\(id)")

        case let .setPlainText(id, text):
            let (b, c) = try editable(id)
            guard let d = RichText.diff(old: c.plainText, new: text) else {
                return EditResult(document: document, changes: [], inverse: [], selection: nil, coalesceKey: nil)
            }
            var n = c
            n.runs = RichText.replace(c.runs, range: d.range, with: d.text)
            let caret = d.range.lowerBound + d.text.utf16.count
            return result([.upsert(updated(b, n))], selection: BlockSelection(block: id, offset: caret), key: "text:\(id)")

        case let .splitBlock(point):
            let (b, c) = try editable(point.blockID)
            let (left, right) = RichText.split(c.runs, at: point.offset)
            var first = c
            first.runs = RichText.normalized(left)
            let newType: BlockType = b.type == .task ? .task : .paragraph
            let newID = ids.next()
            let placed = place(parent: b.parentID, after: b, upper: document.nextSibling(of: b)?.sortKey, id: newID)
            var new = Block(id: newID, pageID: b.pageID, parentID: b.parentID,
                            sortKey: placed.key, type: newType,
                            content: BlockContent(runs: RichText.normalized(right)), createdAt: now)
            new.updatedAt = now
            // Перенумерация первой: её запись блока b заменяется версией с новым текстом ниже.
            var head = updated(b, first)
            for case .upsert(let moved) in placed.renumbered where moved.id == b.id { head.sortKey = moved.sortKey }
            let others = placed.renumbered.filter { if case .upsert(let m) = $0 { return m.id != b.id } else { return true } }
            return result(others + [.upsert(head), .upsert(new)], selection: BlockSelection(block: new.id, offset: 0))

        case let .mergeBackward(id):
            let (b, c) = try editable(id)
            guard let i = document.index(of: id), i > 0 else {
                return EditResult(document: document, changes: [], inverse: [], selection: nil, coalesceKey: nil)
            }
            let previous = document.blocks[i - 1]
            // Предсказуемое правило: с непонятным блоком не объединяем, чтобы не потерять его данные.
            guard let pc = previous.content else {
                return EditResult(document: document, changes: [], inverse: [], selection: BlockSelection(block: id, offset: 0), coalesceKey: nil)
            }
            var joined = pc
            joined.runs = RichText.normalized(pc.runs + c.runs)
            var changes: [BlockChange] = [.upsert(updated(previous, joined))]
            for child in document.blocks where child.parentID == id {
                var moved = child
                moved.parentID = previous.id
                moved.updatedAt = now
                changes.append(.upsert(moved))
            }
            changes.append(.delete(b.id))
            return result(changes, selection: BlockSelection(block: previous.id, offset: RichText.length(pc.runs)))

        case let .insertBlock(after, type):
            let anchor = after.flatMap { document.block($0) }
            let parent = anchor?.parentID
            let upper = anchor.flatMap { document.nextSibling(of: $0) }?.sortKey
                ?? (anchor == nil ? document.blocks.first { $0.parentID == nil }?.sortKey : nil)
            let newID = ids.next()
            let placed = place(parent: parent, after: anchor, upper: upper, id: newID)
            var new = Block(id: newID, pageID: document.pageID, parentID: parent,
                            sortKey: placed.key, type: type, createdAt: now)
            new.updatedAt = now
            return result(placed.renumbered + [.upsert(new)], selection: BlockSelection(block: new.id, offset: 0))

        case let .deleteBlock(id):
            guard let i = document.index(of: id) else { throw EditError.blockNotFound(id) }
            let doomed = document.descendants(of: id)
            let focus = i > 0 ? document.blocks[i - 1] : document.blocks.dropFirst(1 + doomed.count).first
            let changes = doomed.reversed().map { BlockChange.delete($0.id) } + [.delete(id)]
            return result(changes, selection: focus.map { BlockSelection(block: $0.id, offset: RichText.length($0.content?.runs ?? [])) })

        case let .changeType(id, type):
            let (b, c) = try editable(id)
            var n = updated(b, c)
            n.type = type
            return result([.upsert(n)], selection: nil)

        case let .setChecked(id, checked):
            let (b, c) = try editable(id)
            var n = c
            n.checked = checked
            return result([.upsert(updated(b, n))], selection: nil)
        }
    }
}
