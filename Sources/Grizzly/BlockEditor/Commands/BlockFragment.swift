import Foundation

/// Блок вне документа: для вставки и собственного формата буфера обмена.
struct BlockFragment: Codable, Equatable {
    var type: String
    var contentVersion: Int
    var json: String
    var plain: String

    init(type: BlockType, content: BlockContent) {
        self.type = type.rawValue
        contentVersion = BlockContent.currentVersion
        json = (try? content.jsonString()) ?? #"{"runs":[]}"#
        plain = content.plainText
    }

    init(opaque block: Block) {
        type = block.type.rawValue
        contentVersion = block.contentVersion
        json = (try? block.contentJSON()) ?? "{}"
        plain = block.plainText
    }

    /// Понятное содержимое; nil у неизвестного типа и более новой версии.
    var content: BlockContent? {
        guard BlockType(rawValue: type).isKnown, contentVersion <= BlockContent.currentVersion else { return nil }
        return BlockContent(json: json)
    }

    /// Обычный текст: строка — абзац.
    static func lines(_ text: String) -> [BlockFragment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { BlockFragment(type: .paragraph, content: BlockContent(text: $0)) }
    }

    static func plainText(_ fragments: [BlockFragment]) -> String {
        fragments.map(\.plain).joined(separator: "\n")
    }
}

extension BlockDocument {
    /// Начало и конец выделения в порядке документа.
    func ordered(_ s: BlockSelection) -> (start: BlockPoint, end: BlockPoint)? {
        guard let a = index(of: s.anchor.blockID), let f = index(of: s.focus.blockID) else { return nil }
        if a < f || (a == f && s.anchor.offset <= s.focus.offset) { return (s.anchor, s.focus) }
        return (s.focus, s.anchor)
    }

    /// Копия выделения; частично выделенные блоки обрезаются по границам.
    func fragments(in selection: BlockSelection) -> [BlockFragment] {
        guard let (start, end) = ordered(selection), let si = index(of: start.blockID), let ei = index(of: end.blockID) else { return [] }
        var out: [BlockFragment] = []
        for i in si...ei {
            let b = blocks[i]
            guard var c = b.content else {
                // Непонятный блок копируется, только если выделен целиком.
                let lower = i == si ? start.offset : 0, upper = i == ei ? end.offset : 1
                if lower == 0 && upper >= 1 { out.append(BlockFragment(opaque: b)) }
                continue
            }
            var runs = c.runs
            if i == ei { runs = RichText.split(runs, at: end.offset).left }
            if i == si { runs = RichText.split(runs, at: start.offset).right }
            c.runs = RichText.normalized(runs)
            out.append(BlockFragment(type: b.type, content: c))
        }
        return out
    }
}
