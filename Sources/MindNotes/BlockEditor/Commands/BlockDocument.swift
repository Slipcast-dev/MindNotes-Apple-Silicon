import Foundation

struct BlockPoint: Equatable {
    var blockID: UUID
    /// Смещение в единицах UTF-16 внутри текста блока.
    var offset: Int
}

struct BlockSelection: Equatable {
    var anchor: BlockPoint
    var focus: BlockPoint
    init(_ point: BlockPoint) { anchor = point; focus = point }
    init(block: UUID, offset: Int) { self.init(BlockPoint(blockID: block, offset: offset)) }
}

enum BlockChange: Equatable {
    case upsert(Block)
    case delete(UUID)
}

/// Блоки одной страницы в порядке показа (обход дерева в глубину).
struct BlockDocument: Equatable {
    let pageID: UUID
    private(set) var blocks: [Block]

    init(pageID: UUID, blocks: [Block]) {
        self.pageID = pageID
        self.blocks = Self.ordered(blocks)
    }

    func block(_ id: UUID) -> Block? { blocks.first { $0.id == id } }
    func index(of id: UUID) -> Int? { blocks.firstIndex { $0.id == id } }

    func nextSibling(of block: Block) -> Block? {
        blocks.filter { $0.parentID == block.parentID && ($0.sortKey, $0.id.uuidString) > (block.sortKey, block.id.uuidString) }.first
    }

    func descendants(of id: UUID) -> [Block] {
        var out: [Block] = []
        for child in blocks where child.parentID == id {
            out.append(child)
            out += descendants(of: child.id)
        }
        return out
    }

    mutating func apply(_ changes: [BlockChange]) {
        var map = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        for change in changes {
            switch change {
            case .upsert(let b): map[b.id] = b
            case .delete(let id): map[id] = nil
            }
        }
        blocks = Self.ordered(Array(map.values))
    }

    private static func ordered(_ all: [Block]) -> [Block] {
        let ids = Set(all.map(\.id))
        var byParent: [UUID?: [Block]] = [:]
        // Блок с недоступным родителем показывается в корне: данные не должны исчезать из вида.
        for b in all { byParent[b.parentID.flatMap { ids.contains($0) ? $0 : nil }, default: []].append(b) }
        var out: [Block] = []
        out.reserveCapacity(all.count)
        func walk(_ parent: UUID?) {
            let list = (byParent[parent] ?? []).sorted { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
            for b in list {
                out.append(b)
                walk(b.id)
            }
        }
        walk(nil)
        return out
    }
}
