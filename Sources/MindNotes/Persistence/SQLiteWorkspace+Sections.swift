import Foundation

/// Разделы боковой панели (схема v9).
extension SQLiteWorkspace {
    func sections() async throws -> [PageSection] {
        try await reader.run { db in
            try db.query("SELECT id, name, sort_key FROM page_sections ORDER BY sort_key, id") { r -> PageSection? in
                guard let id = r.uuid(0) else { return nil }
                return PageSection(id: id, name: r.text(1), sortKey: r.text(2))
            }.compactMap { $0 }
        }
    }

    /// Страница верхнего уровня → её раздел.
    func sectionMembers() async throws -> [UUID: UUID] {
        try await reader.run { db in
            var out: [UUID: UUID] = [:]
            for (page, section) in try db.query("SELECT page_id, section_id FROM page_section_members", [], { ($0.uuid(0), $0.uuid(1)) }) {
                if let page, let section { out[page] = section }
            }
            return out
        }
    }

    @discardableResult
    func addSection(name: String, id: UUID, now: Int64) async throws -> PageSection {
        guard let clean = PageSection.clean(name) else { throw Self.sectionError("Название раздела пустое.") }
        return try await writer.run { db in
            let last = try db.scalarText("SELECT sort_key FROM page_sections ORDER BY sort_key DESC LIMIT 1")
            let key = SortKey.between(last, nil)
            try db.run("INSERT INTO page_sections(id, name, sort_key, created_at) VALUES(?,?,?,?)", [SQLValue(id), .text(clean), .text(key), .int(now)])
            return PageSection(id: id, name: clean, sortKey: key)
        }
    }

    func renameSection(_ id: UUID, to name: String) async throws {
        guard let clean = PageSection.clean(name) else { throw Self.sectionError("Название раздела пустое.") }
        try await writer.run { db in try db.run("UPDATE page_sections SET name=? WHERE id=?", [.text(clean), SQLValue(id)]) }
    }

    /// Страницы раздела возвращаются в стандартный раздел — ничего не удаляется.
    func deleteSection(_ id: UUID) async throws {
        try await writer.run { db in try db.run("DELETE FROM page_sections WHERE id=?", [SQLValue(id)]) }
    }

    /// Раздел встаёт после `after` (nil — первым).
    func moveSection(_ id: UUID, after: UUID?) async throws {
        try await writer.run { db in
            let list = try db.query("SELECT id, sort_key FROM page_sections WHERE id<>? ORDER BY sort_key, id", [SQLValue(id)]) { ($0.uuid(0), $0.text(1)) }
            let index = after.flatMap { a in list.firstIndex { $0.0 == a } }.map { $0 + 1 } ?? 0
            let before = index > 0 ? list[index - 1].1 : nil
            let next = index < list.count ? list[index].1 : nil
            try db.run("UPDATE page_sections SET sort_key=? WHERE id=?", [.text(SortKey.between(before, next)), SQLValue(id)])
        }
    }

    /// Раздел страницы верхнего уровня; nil — стандартный «Страницы».
    func setSection(page: UUID, section: UUID?) async throws {
        try await writer.run { db in
            try db.transaction {
                try db.run("DELETE FROM page_section_members WHERE page_id=?", [SQLValue(page)])
                if let section {
                    try db.run("INSERT INTO page_section_members(page_id, section_id) SELECT ?, id FROM page_sections WHERE id=?", [SQLValue(page), SQLValue(section)])
                }
            }
        }
    }

    static func sectionError(_ text: String) -> WorkspaceError { .storage(code: 0, detail: text) }
}
