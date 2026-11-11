import Foundation

/// Комментарии (схема v10). Хранятся в пространстве и входят в резервную копию.
extension SQLiteWorkspace {
    func comments(page: UUID) async throws -> [Comment] {
        try await reader.run { db in
            try db.query("""
            SELECT c.id, c.page_id, c.block_id, c.thread_id, c.author_id, p.name, c.body, c.anchor_text, c.resolved, c.created_at
            FROM comments c LEFT JOIN people p ON p.id = c.author_id WHERE c.page_id=? ORDER BY c.created_at, c.id
            """, [SQLValue(page)]) { r -> Comment? in
                guard let id = r.uuid(0), let pageID = r.uuid(1), let thread = r.uuid(3) else { return nil }
                return Comment(id: id, pageID: pageID, blockID: r.uuid(2), threadID: thread, authorID: r.uuid(4),
                               authorName: r.uuid(4) == nil ? nil : r.text(5), body: r.text(6), anchorText: r.text(7),
                               resolved: r.int(8) != 0, createdAt: r.int(9))
            }.compactMap { $0 }
        }
    }

    /// Новый комментарий: без `thread` — новая ветка (её ID — ID комментария), иначе ответ в ветку.
    @discardableResult
    func addComment(page: UUID, block: UUID?, thread: UUID?, author: UUID?, body: String, anchor: String, id: UUID, now: Int64) async throws -> Comment {
        guard let text = Comment.clean(body) else { throw WorkspaceError.storage(code: 0, detail: "Пустой комментарий.") }
        return try await writer.run { db in
            if let thread {
                guard try db.scalarInt("SELECT 1 FROM comments WHERE id=? AND thread_id=id AND page_id=?", [SQLValue(thread), SQLValue(page)]) != nil else {
                    throw WorkspaceError.storage(code: 0, detail: "Ветки комментариев нет.")
                }
            }
            let author = try author.flatMap { a in try db.scalarInt("SELECT 1 FROM people WHERE id=?", [SQLValue(a)]) != nil ? a : nil }
            let threadID = thread ?? id
            try db.run("""
            INSERT INTO comments(id, page_id, block_id, thread_id, author_id, body, anchor_text, resolved, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,0,?,?)
            """, [SQLValue(id), SQLValue(page), SQLValue(block), SQLValue(threadID), SQLValue(author), .text(text), .text(String(anchor.prefix(500))), .int(now), .int(now)])
            return Comment(id: id, pageID: page, blockID: block, threadID: threadID, authorID: author, authorName: nil, body: text,
                           anchorText: String(anchor.prefix(500)), resolved: false, createdAt: now)
        }
    }

    func resolveThread(_ thread: UUID, resolved: Bool, now: Int64) async throws {
        try await writer.run { db in
            try db.run("UPDATE comments SET resolved=?, updated_at=? WHERE id=? AND thread_id=id", [.int(resolved ? 1 : 0), .int(now), SQLValue(thread)])
        }
    }

    /// Удаление первого комментария удаляет всю ветку.
    func deleteComment(_ id: UUID) async throws {
        try await writer.run { db in
            try db.transaction {
                if try db.scalarInt("SELECT 1 FROM comments WHERE id=? AND thread_id=id", [SQLValue(id)]) != nil {
                    try db.run("DELETE FROM comments WHERE thread_id=?", [SQLValue(id)])
                } else {
                    try db.run("DELETE FROM comments WHERE id=?", [SQLValue(id)])
                }
            }
        }
    }
}
