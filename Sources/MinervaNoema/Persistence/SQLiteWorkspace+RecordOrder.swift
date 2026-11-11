import Foundation

/// Ручной порядок записей (M10.3): у каждого представления свой, действует, пока в нём нет сортировок.
extension SQLiteWorkspace {
    /// Запись встаёт перед `before` (nil — в конец). При первом переносе текущий порядок вида записывается целиком,
    /// чтобы остальные записи не сдвинулись. Одна транзакция.
    func moveRecord(_ record: UUID, before: UUID?, view: UUID) async throws {
        guard record != before else { return }
        try await writer.run { db in
            try db.transaction {
                guard let database = try db.query("SELECT database_id FROM database_views WHERE id=?", [SQLValue(view)], { $0.uuid(0) }).first ?? nil else {
                    throw WorkspaceError.storage(code: 0, detail: NSLocalizedString("Ручной порядок есть только у представлений базы.", comment: ""))
                }
                for page in [record] + (before.map { [$0] } ?? []) {
                    guard try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND database_id=? AND deleted_at IS NULL", [SQLValue(page), SQLValue(database)]) != nil else {
                        throw WorkspaceError.storage(code: 0, detail: NSLocalizedString("Запись недоступна.", comment: ""))
                    }
                }
                func ordered() throws -> [(id: UUID, key: String?)] {
                    try db.query("""
                    SELECT p.id, vo.sort_key FROM pages p LEFT JOIN view_record_order vo ON vo.view_id = ? AND vo.page_id = p.id
                    WHERE p.database_id = ? AND p.deleted_at IS NULL ORDER BY vo.sort_key IS NULL, vo.sort_key, p.sort_key, p.id
                    """, [SQLValue(view), SQLValue(database)]) { r -> (id: UUID, key: String?)? in r.uuid(0).map { ($0, r.optText(1)) } }.compactMap { $0 }
                }
                var rows = try ordered()
                if rows.contains(where: { $0.key == nil }) {
                    // Записи без места получают ключи по текущему виду: порядок на экране не меняется.
                    try db.run("DELETE FROM view_record_order WHERE view_id=? AND page_id IN (SELECT id FROM pages WHERE database_id=? AND deleted_at IS NULL)",
                               [SQLValue(view), SQLValue(database)])
                    for (row, key) in zip(rows, SortKey.keys(after: nil, before: nil, count: rows.count)) {
                        try db.run("INSERT INTO view_record_order(view_id, page_id, sort_key) VALUES(?,?,?)", [SQLValue(view), SQLValue(row.id), .text(key)])
                    }
                    rows = try ordered()
                }
                rows.removeAll { $0.id == record }
                let index = before.flatMap { b in rows.firstIndex { $0.id == b } } ?? rows.count
                let lower = index > 0 ? rows[index - 1].key : nil
                let upper = index < rows.count ? rows[index].key : nil
                try db.run("UPDATE view_record_order SET sort_key=? WHERE view_id=? AND page_id=?",
                           [.text(SortKey.between(lower, upper)), SQLValue(view), SQLValue(record)])
            }
        }
    }
}
