import Foundation

/// Комментарий (M14). Ветка — первый комментарий (`threadID == id`) и ответы. У комментария к тексту есть блок и
/// метка `cm:<ветка>` на отрезках текста; у комментария к странице блока нет.
struct Comment: Equatable, Identifiable {
    var id: UUID
    var pageID: UUID
    var blockID: UUID?
    var threadID: UUID
    var authorID: UUID?
    var authorName: String?
    var body: String
    var anchorText: String
    var resolved: Bool
    var createdAt: Int64

    var isRoot: Bool { id == threadID }

    static let maxBody = 10_000
    static let markPrefix = "cm:"
    static func mark(_ thread: UUID) -> String { markPrefix + thread.uuidString.lowercased() }
    static func thread(fromMark mark: String) -> UUID? {
        mark.hasPrefix(markPrefix) ? UUID(uuidString: String(mark.dropFirst(markPrefix.count))) : nil
    }

    static func clean(_ body: String) -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxBody))
    }
}

/// Ветка комментариев: первый комментарий и ответы по времени.
struct CommentThread: Equatable, Identifiable {
    var root: Comment
    var replies: [Comment]
    var id: UUID { root.id }

    static func group(_ comments: [Comment]) -> [CommentThread] {
        let byThread = Dictionary(grouping: comments, by: \.threadID)
        return comments.filter(\.isRoot).map { root in
            CommentThread(root: root, replies: (byThread[root.id] ?? []).filter { !$0.isRoot }.sorted { $0.createdAt < $1.createdAt })
        }
    }
}
