import CryptoKit
import Foundation

/// Теги, настройки пространства и управляемые файлы.
extension SQLiteWorkspace {
    // MARK: Настройки пространства

    func meta(_ key: String) async throws -> String? {
        try await reader.run { try $0.scalarText("SELECT value FROM workspace_meta WHERE key=?", [.text(key)]) }
    }

    func setMeta(_ key: String, _ value: String) async throws {
        try await writer.run { db in
            try db.run("INSERT INTO workspace_meta(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
        }
    }

    func look() async throws -> WorkspaceLook {
        guard let raw = try await meta("look"), let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WorkspaceLook.self, from: data) else { return WorkspaceLook() }
        return decoded
    }

    func setLook(_ look: WorkspaceLook) async throws {
        let data = try JSONEncoder().encode(look)
        try await setMeta("look", String(decoding: data, as: UTF8.self))
    }

    func rename(to name: String) async throws { try await setMeta("name", name) }

    // MARK: Теги

    private static func decodeTag(_ r: SQLRow) -> Tag? {
        guard let id = r.uuid(0) else { return nil }
        return Tag(id: id, name: r.text(1), color: r.optText(2))
    }

    func tags() async throws -> [Tag] {
        try await reader.run { db in
            try db.query("SELECT id, name, color FROM tags ORDER BY name_key") { Self.decodeTag($0) }.compactMap { $0 }
        }
    }

    /// Создаёт тег; такое же имя с другим регистром вернёт существующий.
    func createTag(name: String, color: String?, id: UUID = UUID(), now: Int64) async throws -> Tag {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Tag.key(clean)
        guard !key.isEmpty else { throw WorkspaceError.storage(code: 0, detail: "пустое имя тега") }
        return try await writer.run { db in
            try db.transaction {
                if let found = try db.query("SELECT id, name, color FROM tags WHERE name_key=?", [.text(key)], { Self.decodeTag($0) }).first ?? nil { return found }
                try db.run("INSERT INTO tags(id, name, name_key, color, created_at) VALUES(?,?,?,?,?)",
                           [SQLValue(id), .text(clean), .text(key), SQLValue(color), .int(now)])
                return Tag(id: id, name: clean, color: color)
            }
        }
    }

    /// Переименование; если имя занято другим тегом, страницы переходят к нему и теги объединяются.
    func renameTag(_ id: UUID, to name: String) async throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Tag.key(clean)
        guard !key.isEmpty else { return }
        try await writer.run { db in
            try db.transaction {
                if let other = try db.query("SELECT id FROM tags WHERE name_key=? AND id<>?", [.text(key), SQLValue(id)], { $0.uuid(0) }).first ?? nil {
                    try db.run("INSERT OR IGNORE INTO page_tags(page_id, tag_id) SELECT page_id, ? FROM page_tags WHERE tag_id=?", [SQLValue(other), SQLValue(id)])
                    try db.run("DELETE FROM tags WHERE id=?", [SQLValue(id)])
                } else {
                    try db.run("UPDATE tags SET name=?, name_key=? WHERE id=?", [.text(clean), .text(key), SQLValue(id)])
                }
            }
        }
    }

    func setTagColor(_ id: UUID, color: String?) async throws {
        try await writer.run { try $0.run("UPDATE tags SET color=? WHERE id=?", [SQLValue(color), SQLValue(id)]) }
    }

    /// Удаляет тег у всех страниц; сами страницы не меняются.
    func deleteTag(_ id: UUID) async throws {
        try await writer.run { try $0.run("DELETE FROM tags WHERE id=?", [SQLValue(id)]) }
    }

    func setTag(_ tag: UUID, on page: UUID, _ enabled: Bool) async throws {
        try await writer.run { db in
            if enabled {
                try db.run("INSERT OR IGNORE INTO page_tags(page_id, tag_id) VALUES(?,?)", [SQLValue(page), SQLValue(tag)])
            } else {
                try db.run("DELETE FROM page_tags WHERE page_id=? AND tag_id=?", [SQLValue(page), SQLValue(tag)])
            }
        }
    }

    /// Теги действующих страниц; страницы в корзине не считаются.
    func pageTags() async throws -> [UUID: [UUID]] {
        try await reader.run { db in
            var out: [UUID: [UUID]] = [:]
            let rows = try db.query("""
            SELECT pt.page_id, pt.tag_id FROM page_tags pt JOIN pages p ON p.id = pt.page_id JOIN tags t ON t.id = pt.tag_id
            WHERE p.deleted_at IS NULL ORDER BY t.name_key
            """) { ($0.uuid(0), $0.uuid(1)) }
            for (page, tag) in rows { if let page, let tag { out[page, default: []].append(tag) } }
            return out
        }
    }

    // MARK: Управляемые файлы

    /// Копирует файл в `assets/`: сначала временный файл и атомарный перенос, затем запись в базе (FR-08).
    func addAsset(copying source: URL, id: UUID = UUID(), now: Int64) async throws -> AssetRecord {
        let cleaned = source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let ext = cleaned.count <= 10 ? cleaned : ""
        let hex = String(id.lowercasedString.prefix(2))
        let rel = "assets/\(hex)/\(id.lowercasedString)\(ext.isEmpty ? "" : ".\(ext)")"
        let root = layout
        let record: AssetRecord = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let tmp = root.tmp.appendingPathComponent("\(id.lowercasedString).part")
            try fm.createDirectory(at: root.tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            fm.createFile(atPath: tmp.path, contents: nil)
            let output = try FileHandle(forWritingTo: tmp)
            defer { try? output.close() }
            var hash = SHA256()
            var size: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                hash.update(data: chunk)
                try output.write(contentsOf: chunk)
                size += Int64(chunk.count)
            }
            try output.synchronize()
            let target = root.root.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: tmp, to: target)
            let sha = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return AssetRecord(id: id, relPath: rel, originalName: source.lastPathComponent, mime: nil, byteSize: size, sha256: sha, createdAt: now)
        }.value
        do {
            try await writer.run { db in
                try db.run("INSERT INTO assets(id, rel_path, original_name, byte_size, sha256, created_at) VALUES(?,?,?,?,?,?)",
                           [SQLValue(record.id), .text(record.relPath), .text(record.originalName), .int(record.byteSize), .text(record.sha256), .int(record.createdAt)])
            }
        } catch {
            try? FileManager.default.removeItem(at: root.root.appendingPathComponent(rel)) // Компенсация: файла без записи не остаётся.
            throw error
        }
        return record
    }

    /// Удаляет запись и файл. Файл вложения неизменяем, поэтому порядок безопасен: сначала ссылка в базе.
    func deleteAsset(_ id: UUID) async throws {
        guard let url = try await assetURL(id) else { return }
        try await writer.run { try $0.run("DELETE FROM assets WHERE id=?", [SQLValue(id)]) }
        try? FileManager.default.removeItem(at: url)
    }

    /// Синхронный путь для отрисовки изображений. Вызывается редко: результат кэшируется в редакторе.
    func assetFileURLSync(_ id: UUID) throws -> URL? {
        guard let rel = try reader.sync({ try $0.scalarText("SELECT rel_path FROM assets WHERE id=?", [SQLValue(id)]) }) else { return nil }
        return layout.root.appendingPathComponent(rel)
    }

    func assetURL(_ id: UUID) async throws -> URL? {
        guard let rel = try await reader.run({ try $0.scalarText("SELECT rel_path FROM assets WHERE id=?", [SQLValue(id)]) }) else { return nil }
        return layout.root.appendingPathComponent(rel)
    }
}
