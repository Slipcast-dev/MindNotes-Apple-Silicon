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
    /// Заменяет выделение (возможно, через несколько блоков) фрагментами; пустой список — удаление.
    case replaceRange(BlockSelection, [BlockFragment])
    /// Форматирование выделенного текста.
    case formatText(BlockSelection, MarkEdit)
    case indent(UUID)
    case outdent(UUID)
    case setCollapsed(block: UUID, collapsed: Bool)
    /// Несколько правок одним шагом отмены.
    case batch([EditCommand])
}

/// Изменение меток: b, i, u, s, code и метки с значением a:адрес, c:цвет, bg:цвет.
enum MarkEdit: Equatable {
    case toggle(String)
    /// Заменяет метку с этим префиксом; nil снимает её.
    case setValue(prefix: String, value: String?)
    case clear
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
            // Enter в начале заголовка: заголовок сдвигается вниз, над ним появляется пустой абзац.
            let headingStart = left.isEmpty && !right.isEmpty && b.type.isHeading
            let keepsType = b.type == .task || b.type == .bullet || b.type == .numbered
            let newType: BlockType = headingStart ? b.type : (keepsType ? b.type : .paragraph)
            let newID = ids.next()
            let placed = place(parent: b.parentID, after: b, upper: document.nextSibling(of: b)?.sortKey, id: newID)
            var new = Block(id: newID, pageID: b.pageID, parentID: b.parentID,
                            sortKey: placed.key, type: newType,
                            content: BlockContent(runs: RichText.normalized(right)), createdAt: now)
            new.updatedAt = now
            // Перенумерация первой: её запись блока b заменяется версией с новым текстом ниже.
            var head = updated(b, first)
            if headingStart { head.type = .paragraph }
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
            var new = type.isAtom || (!type.isKnown && type != .paragraph)
                ? Block(atom: type, id: newID, pageID: document.pageID, parentID: parent, sortKey: placed.key, createdAt: now)
                : Block(id: newID, pageID: document.pageID, parentID: parent, sortKey: placed.key, type: type, createdAt: now)
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

        case let .replaceRange(selection, fragments):
            guard let (start, end) = document.ordered(selection), let si = document.index(of: start.blockID), let ei = document.index(of: end.blockID) else {
                throw EditError.blockNotFound(selection.anchor.blockID)
            }
            let first = document.blocks[si], last = document.blocks[ei]
            // Непонятный блок занимает в тексте один символ и входит в правку, только если покрыт целиком.
            let firstCovered = first.content == nil && start.offset == 0 && (si < ei || end.offset >= 1)
            let lastCovered = last.content == nil && end.offset >= 1 && (si < ei || start.offset == 0)
            let head = first.content.map { RichText.split($0.runs, at: start.offset).left } ?? []
            let tail = last.content.map { RichText.split($0.runs, at: end.offset).right } ?? []
            // Выделена строка целиком (тройной клик): остаётся следующий блок со своим типом и отметкой.
            let wholeLine = fragments.isEmpty && si < ei && head.isEmpty && !tail.isEmpty && last.content != nil
            let host = wholeLine ? last : (first.content != nil ? first : (last.content != nil ? last : nil))

            // Что будет на месте правки.
            struct Piece { var fragment: BlockFragment?; var type: BlockType; var content: BlockContent }
            var pieces: [Piece] = []
            let hostType = host?.type ?? .paragraph
            let hostChecked = host?.content?.checked ?? false
            let hostExtra = host?.content?.extra ?? [:]
            func merged(_ runs: [TextRun]) -> BlockContent { BlockContent(runs: runs, checked: hostChecked, extra: hostExtra) }
            if fragments.isEmpty {
                if host != nil { pieces.append(Piece(type: hostType, content: merged(head + tail))) }
            } else {
                let edited = fragments.map(\.content)
                var openHead = host != nil ? head : []
                var useHostFirst = host != nil
                for (i, fragment) in fragments.enumerated() {
                    guard let c = edited[i] else {
                        if useHostFirst, !openHead.isEmpty { pieces.append(Piece(type: hostType, content: merged(openHead))) }
                        useHostFirst = false
                        openHead = []
                        pieces.append(Piece(fragment: fragment, type: BlockType(rawValue: fragment.type), content: BlockContent()))
                        continue
                    }
                    var runs = c.runs
                    if i == 0 { runs = openHead + runs }
                    if i == fragments.count - 1 { runs += tail }
                    if i == 0 && useHostFirst {
                        // В непустое начало блока фрагмент вливается; в пустое блок принимает его тип.
                        let keepHost = !head.isEmpty || fragments.count == 1
                        pieces.append(Piece(type: keepHost ? hostType : BlockType(rawValue: fragment.type),
                                            content: BlockContent(runs: runs, checked: keepHost ? hostChecked : c.checked, extra: keepHost ? hostExtra : c.extra)))
                    } else {
                        pieces.append(Piece(type: BlockType(rawValue: fragment.type), content: BlockContent(runs: runs, checked: c.checked, extra: c.extra)))
                    }
                }
                if edited.last.flatMap({ $0 }) == nil, !tail.isEmpty {
                    pieces.append(Piece(type: .paragraph, content: BlockContent(runs: tail)))
                }
            }

            // Удаляемые блоки: всё между границами и покрытые края, кроме блока-хозяина.
            var removed: [UUID] = []
            if si < ei { removed += document.blocks[(si + 1)..<ei].map(\.id) }
            if si < ei, last.id != host?.id, last.content != nil || lastCovered { removed.append(last.id) }
            if first.id != host?.id, firstCovered || first.content != nil { removed.append(first.id) }
            let removedSet = Set(removed)

            let anchorIndex = host.flatMap { document.index(of: $0.id) } ?? (firstCovered ? si - 1 : si)
            let anchor = anchorIndex >= 0 && document.blocks.indices.contains(anchorIndex) && !removedSet.contains(document.blocks[anchorIndex].id) ? document.blocks[anchorIndex] : nil
            let parent = host?.parentID ?? first.parentID
            let upper = document.blocks.dropFirst(ei + 1).first { $0.parentID == parent && !removedSet.contains($0.id) }?.sortKey
            var keys = SortKey.keys(after: host?.sortKey ?? anchor?.sortKey, before: upper, count: max(pieces.count, 1))

            var changes: [BlockChange] = []
            var created: [Block] = []
            for (i, piece) in pieces.enumerated() {
                if i == 0, let host, piece.fragment == nil {
                    var b = host
                    b.type = piece.type
                    b.setContent(piece.content)
                    b.updatedAt = now
                    created.append(b)
                    keys.insert(host.sortKey, at: 0)
                    continue
                }
                let key = keys[min(i, keys.count - 1)]
                var b: Block
                if let f = piece.fragment {
                    b = Block(id: ids.next(), pageID: document.pageID, parentID: parent, sortKey: key, type: piece.type,
                              contentVersion: f.contentVersion, contentJSON: f.json, plainText: f.plain, createdAt: now, updatedAt: now)
                } else {
                    b = Block(id: ids.next(), pageID: document.pageID, parentID: parent, sortKey: key, type: piece.type, content: piece.content, createdAt: now)
                    b.updatedAt = now
                }
                created.append(b)
            }
            // Хозяин заменён фрагментом с непонятным содержимым: его запись уходит вместе с остальными.
            if let host, !created.contains(where: { $0.id == host.id }), !removed.contains(host.id) { changes.append(.delete(host.id)) }
            changes += created.map { .upsert($0) }

            // Страница не остаётся без поля для ввода.
            let remaining = document.blocks.filter { !removedSet.contains($0.id) && $0.id != host?.id }.count
            if created.isEmpty && remaining == 0 {
                var empty = Block(id: ids.next(), pageID: document.pageID, sortKey: SortKey.between(nil, nil), createdAt: now)
                empty.updatedAt = now
                created.append(empty)
                changes.append(.upsert(empty))
            }
            // Потомки удаляемых блоков, оставшиеся за границей правки, переходят к хозяину.
            let newParent = created.last?.id ?? parent
            for b in document.blocks.dropFirst(ei + 1) where b.parentID.map({ removedSet.contains($0) }) == true && !removedSet.contains(b.id) {
                var moved = b
                moved.parentID = newParent
                moved.updatedAt = now
                changes.append(.upsert(moved))
            }
            for id in removed.reversed() { changes.append(.delete(id)) }

            let caret: BlockSelection?
            if let target = created.last {
                if let c = target.content {
                    let tailLength = fragments.last?.content == nil && !fragments.isEmpty ? 0 : RichText.length(tail)
                    caret = BlockSelection(block: target.id, offset: max(0, RichText.length(c.runs) - tailLength))
                } else {
                    caret = BlockSelection(block: target.id, offset: 1)
                }
            } else if !firstCovered, si == ei || !lastCovered {
                caret = BlockSelection(block: first.id, offset: min(start.offset, 1))
            } else {
                let next = document.blocks.dropFirst(ei + 1).first { !removedSet.contains($0.id) }
                let previous = document.blocks.prefix(si).last
                caret = next.map { BlockSelection(block: $0.id, offset: 0) } ?? previous.map { BlockSelection(block: $0.id, offset: $0.content.map { RichText.length($0.runs) } ?? 1) }
            }
            guard !changes.isEmpty else {
                return EditResult(document: document, changes: [], inverse: [], selection: caret, coalesceKey: nil)
            }
            return result(changes, selection: caret)

        case let .formatText(selection, edit):
            guard let (start, end) = document.ordered(selection), let si = document.index(of: start.blockID), let ei = document.index(of: end.blockID) else {
                throw EditError.blockNotFound(selection.anchor.blockID)
            }
            let targets = document.blocks[si...ei].compactMap { b -> (Block, BlockContent, Range<Int>)? in
                guard let c = b.content, b.type != .code else { return nil }
                let lower = b.id == start.blockID ? start.offset : 0
                let upper = b.id == end.blockID ? end.offset : RichText.length(c.runs)
                return upper > lower ? (b, c, lower..<upper) : nil
            }
            var transform: ([String]) -> [String]
            switch edit {
            case .toggle(let mark):
                let allMarked = !targets.isEmpty && targets.allSatisfy { RichText.hasMark($0.1.runs, range: $0.2, mark) }
                transform = { marks in allMarked ? marks.filter { $0 != mark } : (marks.contains(mark) ? marks : marks + [mark]) }
            case let .setValue(prefix, value):
                transform = { marks in marks.filter { !$0.hasPrefix(prefix) } + (value.map { [prefix + $0] } ?? []) }
            case .clear:
                transform = { _ in [] }
            }
            let changes: [BlockChange] = targets.map { b, c, range in
                var n = c
                n.runs = RichText.mapMarks(c.runs, range: range, transform)
                return .upsert(updated(b, n))
            }
            return result(changes, selection: selection)

        case let .indent(id):
            guard let b = document.block(id) else { throw EditError.blockNotFound(id) }
            let siblings = document.blocks.filter { $0.parentID == b.parentID }
            guard let i = siblings.firstIndex(where: { $0.id == id }), i > 0 else {
                return EditResult(document: document, changes: [], inverse: [], selection: nil, coalesceKey: nil)
            }
            let newParent = siblings[i - 1]
            let lastChild = document.blocks.last { $0.parentID == newParent.id }
            var n = b
            n.parentID = newParent.id
            n.sortKey = SortKey.between(lastChild?.sortKey, nil)
            n.updatedAt = now
            return result([.upsert(n)], selection: nil)

        case let .outdent(id):
            guard let b = document.block(id) else { throw EditError.blockNotFound(id) }
            guard let parentID = b.parentID, let parent = document.block(parentID) else {
                return EditResult(document: document, changes: [], inverse: [], selection: nil, coalesceKey: nil)
            }
            var n = b
            n.parentID = parent.parentID
            n.sortKey = SortKey.between(parent.sortKey, document.nextSibling(of: parent)?.sortKey)
            n.updatedAt = now
            return result([.upsert(n)], selection: nil)

        case let .setCollapsed(id, collapsed):
            let (b, c) = try editable(id)
            var n = c
            n.extra["collapsed"] = collapsed ? .bool(true) : nil
            return result([.upsert(updated(b, n))], selection: nil)

        case let .batch(commands):
            var current = document
            var changes: [BlockChange] = []
            var inverse: [BlockChange] = []
            var selection: BlockSelection?
            for command in commands {
                let step = try apply(command, to: current, ids: ids, now: now)
                current = step.document
                changes += step.changes
                inverse = step.inverse + inverse
                if let s = step.selection { selection = s }
            }
            return EditResult(document: current, changes: changes, inverse: inverse, selection: selection, coalesceKey: nil)

        case let .setChecked(id, checked):
            let (b, c) = try editable(id)
            var n = c
            n.checked = checked
            return result([.upsert(updated(b, n))], selection: nil)
        }
    }
}
