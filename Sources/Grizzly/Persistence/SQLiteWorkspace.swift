import Foundation
import CryptoKit

/// Хранилище одного пространства. Запись — через одну последовательную очередь, чтение — через другую.
final class SQLiteWorkspace: WorkspaceStore, DatabaseSnapshotter {
    /// Вызывается перед миграцией с источником снимков: проверенная копия обязательна до изменения формата.
    typealias BeforeMigration = (DatabaseSnapshotter, URL) throws -> Void

    struct Options {
        var migrations: [Migration] = Migrations.all
        var beforeMigration: BeforeMigration?
        var appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        var clock: WallClock = SystemClock()
        init() {}
    }

    let layout: WorkspaceLayout
    private let lock: WorkspaceLock
    private let writer: DatabaseQueue
    private let reader: DatabaseQueue
    /// Точки для тестов аварий и отказов: `before-commit`, `after-commit`.
    var faultHook: ((String) throws -> Void)?
    private let clock: WallClock

    // MARK: Открытие

    /// Создаёт пространство в новой или пустой папке.
    static func create(at dir: URL, name: String, id: UUID = UUID(), options: Options = Options()) throws -> SQLiteWorkspace {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw WorkspaceError.notADirectory(dir.path) }
            let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            guard items.filter({ $0 != ".DS_Store" }).isEmpty else { throw WorkspaceError.directoryNotEmpty(dir.path) }
        }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw WorkspaceError.noPermission(dir.path) }
        guard fm.isWritableFile(atPath: dir.path) else { throw WorkspaceError.noPermission(dir.path) }

        let layout = WorkspaceLayout(root: dir)
        let lock = try WorkspaceLock(url: layout.lock)
        try fm.createDirectory(at: layout.assets, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.tmp, withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: layout.database.path, create: true)
        try configureWriter(db)
        let now = options.clock.nowMillis()
        try Migrator.migrate(db, migrations: options.migrations, appVersion: options.appVersion, now: now)
        try db.transaction {
            for (k, v) in [("workspace_id", id.lowercasedString), ("name", name), ("created_at", String(now)), ("created_by_app", options.appVersion)] {
                try db.run("INSERT INTO workspace_meta(key, value) VALUES(?,?)", [.text(k), .text(v)])
            }
        }
        return try SQLiteWorkspace(layout: layout, lock: lock, writerConnection: db, clock: options.clock)
    }

    /// Открывает пространство. Порядок важен: новая схема отклоняется раньше первой записи.
    static func open(at dir: URL, options: Options = Options()) throws -> SQLiteWorkspace {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw WorkspaceError.notADirectory(dir.path) }
        let layout = WorkspaceLayout(root: dir)
        guard fm.fileExists(atPath: layout.database.path) else { throw WorkspaceError.notAWorkspace(dir.path) }
        guard fm.isWritableFile(atPath: dir.path), fm.isWritableFile(atPath: layout.database.path) else { throw WorkspaceError.noPermission(dir.path) }
        let lock = try WorkspaceLock(url: layout.lock)

        let supported = options.migrations.map(\.version).max() ?? 0
        do {
            let ro = try SQLiteConnection(path: layout.database.path, readOnly: true)
            defer { ro.close() }
            let appID = try ro.scalarInt("PRAGMA application_id") ?? 0
            guard appID == Migrations.applicationID else { throw WorkspaceError.notAWorkspace(dir.path) }
            let version = Int(try ro.scalarInt("PRAGMA user_version") ?? 0)
            if version > supported { throw WorkspaceError.schemaTooNew(found: version, supported: supported) }
            let check = try ro.scalarText("PRAGMA quick_check(1)") ?? ""
            guard check == "ok" else { throw WorkspaceError.corrupted(check) }
            if version < supported, let backup = options.beforeMigration {
                try backup(ConnectionSnapshotter(connection: ro), dir)
            }
        }

        let db = try SQLiteConnection(path: layout.database.path)
        try configureWriter(db)
        try Migrator.migrate(db, migrations: options.migrations, appVersion: options.appVersion, now: options.clock.nowMillis())
        try fm.createDirectory(at: layout.assets, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.tmp, withIntermediateDirectories: true)
        return try SQLiteWorkspace(layout: layout, lock: lock, writerConnection: db, clock: options.clock)
    }

    private init(layout: WorkspaceLayout, lock: WorkspaceLock, writerConnection: SQLiteConnection, clock: WallClock) throws {
        self.layout = layout
        self.lock = lock
        self.clock = clock
        writer = DatabaseQueue(label: "write", connection: writerConnection)
        let read = try SQLiteConnection(path: layout.database.path, readOnly: true)
        try read.execute("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA query_only=ON")
        reader = DatabaseQueue(label: "read", connection: read)
    }

    private static func configureWriter(_ db: SQLiteConnection) throws {
        // synchronous=FULL и fullfsync: «Сохранено» обязано означать надёжную запись на диск.
        _ = try db.query("PRAGMA journal_mode=WAL") { $0.text(0) }
        try db.execute("""
        PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL;
        PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON; PRAGMA journal_size_limit=67108864;
        """)
    }

    func close() {
        writer.close()
        reader.close()
        lock.release()
    }

    func maintenanceWrite<T>(_ body: @escaping (SQLiteConnection) throws -> T) throws -> T { try writer.sync(body) }

    // MARK: Снимки

    func snapshotDatabase(to url: URL) throws {
        // Отдельное соединение: запись в WAL продолжается, снимок согласован.
        let source = try SQLiteConnection(path: layout.database.path, readOnly: true)
        defer { source.close() }
        try SQLiteSnapshot.copy(from: source, to: url)
    }

    private struct ConnectionSnapshotter: DatabaseSnapshotter {
        let connection: SQLiteConnection
        func snapshotDatabase(to url: URL) throws { try SQLiteSnapshot.copy(from: connection, to: url) }
    }

    // MARK: Чтение

    func workspaceID() async throws -> UUID {
        guard let id = try await reader.run({ try $0.scalarText("SELECT value FROM workspace_meta WHERE key='workspace_id'") }).flatMap(UUID.init(uuidString:)) else {
            throw WorkspaceError.corrupted("нет workspace_id")
        }
        return id
    }

    func workspaceName() async throws -> String {
        try await reader.run { try $0.scalarText("SELECT value FROM workspace_meta WHERE key='name'") } ?? ""
    }

    private static let pageColumns = "id, parent_id, sort_key, title, icon, cover_asset_id, full_width, favorite_key, created_at, updated_at, last_opened_at, deleted_at, trash_batch_id, content_rev"

    private static func decodePage(_ r: SQLRow) -> Page? {
        guard let id = r.uuid(0) else { return nil }
        var p = Page(id: id, parentID: r.uuid(1), sortKey: r.text(2), title: r.text(3), createdAt: r.int(8))
        p.icon = r.optText(4)
        p.coverAssetID = r.uuid(5)
        p.fullWidth = r.int(6) != 0
        p.favoriteKey = r.optText(7)
        p.updatedAt = r.int(9)
        p.lastOpenedAt = r.optInt(10)
        p.deletedAt = r.optInt(11)
        p.trashBatchID = r.uuid(12)
        p.contentRev = r.int(13)
        return p
    }

    func allPages() async throws -> [Page] {
        try await reader.run { db in
            try db.query("SELECT \(Self.pageColumns) FROM pages WHERE deleted_at IS NULL ORDER BY sort_key, id") { Self.decodePage($0) }.compactMap { $0 }
        }
    }

    func page(_ id: UUID) async throws -> Page? {
        try await reader.run { db in
            try db.query("SELECT \(Self.pageColumns) FROM pages WHERE id=?", [SQLValue(id)]) { Self.decodePage($0) }.first ?? nil
        }
    }

    func blocks(ofPage id: UUID) async throws -> [Block] {
        try await reader.run { db in
            try db.query("""
            SELECT id, page_id, parent_id, sort_key, type, content_v, content_json, plain_text, created_at, updated_at
            FROM blocks WHERE page_id=? ORDER BY sort_key, id
            """, [SQLValue(id)]) { r -> Block? in
                guard let bid = r.uuid(0), let pid = r.uuid(1) else { return nil }
                return Block(id: bid, pageID: pid, parentID: r.uuid(2), sortKey: r.text(3), type: BlockType(rawValue: r.text(4)),
                             contentVersion: Int(r.int(5)), contentJSON: r.text(6), plainText: r.text(7),
                             createdAt: r.int(8), updatedAt: r.int(9))
            }.compactMap { $0 }
        }
    }

    // MARK: Запись страниц

    func createPage(parent: UUID?, title: String, id: UUID, now: Int64) async throws -> Page {
        try await writer.run { db in
            try db.transaction {
                if let parent, try !Self.exists(db, parent) { throw WorkspaceError.pageNotFound(parent) }
                let last = try db.scalarText("SELECT sort_key FROM pages WHERE parent_id IS ? AND deleted_at IS NULL ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(parent)])
                let page = Page(id: id, parentID: parent, sortKey: SortKey.between(last, nil), title: title, createdAt: now)
                try db.run("INSERT INTO pages(id, parent_id, sort_key, title, created_at, updated_at) VALUES(?,?,?,?,?,?)",
                           [SQLValue(id), SQLValue(parent), .text(page.sortKey), .text(title), .int(now), .int(now)])
                return page
            }
        }
    }

    private static func exists(_ db: SQLiteConnection, _ id: UUID) throws -> Bool {
        try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND deleted_at IS NULL", [SQLValue(id)]) != nil
    }

    func updatePage(_ page: Page) async throws {
        try await writer.run { db in
            try db.run("""
            UPDATE pages SET title=?, icon=?, cover_asset_id=?, full_width=?, favorite_key=?, updated_at=? WHERE id=?
            """, [.text(page.title), SQLValue(page.icon), SQLValue(page.coverAssetID), .int(page.fullWidth ? 1 : 0),
                  SQLValue(page.favoriteKey), .int(page.updatedAt), SQLValue(page.id)])
            if db.changes == 0 { throw WorkspaceError.pageNotFound(page.id) }
        }
    }

    func movePage(_ id: UUID, toParent parent: UUID?, afterSibling: UUID?, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                guard try Self.exists(db, id) else { throw WorkspaceError.pageNotFound(id) }
                if let parent {
                    guard try Self.exists(db, parent) else { throw WorkspaceError.pageNotFound(parent) }
                    // Цель не должна быть самой страницей или её потомком.
                    let cycle = try db.scalarInt("""
                    WITH RECURSIVE up(id) AS (
                        SELECT ? UNION ALL SELECT p.parent_id FROM pages p JOIN up ON p.id = up.id WHERE p.parent_id IS NOT NULL
                    ) SELECT 1 FROM up WHERE id = ? LIMIT 1
                    """, [SQLValue(parent), SQLValue(id)])
                    if cycle != nil { throw WorkspaceError.wouldCreateCycle }
                }
                let siblings = try db.query("SELECT id, sort_key FROM pages WHERE parent_id IS ? AND deleted_at IS NULL AND id<>? ORDER BY sort_key, id",
                                            [SQLValue(parent), SQLValue(id)]) { ($0.uuid(0), $0.text(1)) }
                var position = 0
                if let afterSibling {
                    guard let i = siblings.firstIndex(where: { $0.0 == afterSibling }) else { throw WorkspaceError.pageNotFound(afterSibling) }
                    position = i + 1
                }
                let before = position > 0 ? siblings[position - 1].1 : nil
                let after = position < siblings.count ? siblings[position].1 : nil
                let key = SortKey.between(before, after)
                if key.utf8.count > SortKey.maxLength {
                    // Ключи соседей стали слишком длинными: перенумеровать в этой же транзакции.
                    var ids = siblings.compactMap(\.0)
                    ids.insert(id, at: position)
                    let keys = SortKey.keys(after: nil, before: nil, count: ids.count)
                    for (pageID, k) in zip(ids, keys) {
                        try db.run("UPDATE pages SET sort_key=? WHERE id=?", [.text(k), SQLValue(pageID)])
                    }
                    try db.run("UPDATE pages SET parent_id=?, updated_at=? WHERE id=?", [SQLValue(parent), .int(now), SQLValue(id)])
                } else {
                    try db.run("UPDATE pages SET parent_id=?, sort_key=?, updated_at=? WHERE id=?", [SQLValue(parent), .text(key), .int(now), SQLValue(id)])
                }
            }
        }
    }

    func markOpened(_ id: UUID, now: Int64) async throws {
        try await writer.run { db in
            try db.run("UPDATE pages SET last_opened_at=? WHERE id=?", [.int(now), SQLValue(id)])
        }
    }

    // MARK: Пакет правок

    func commit(_ batch: SaveBatch) async throws {
        let now = clock.nowMillis()
        // JSON готовится заранее: сериализация не должна удлинять транзакцию.
        let rows = try batch.upserts.values.map { ($0, try $0.contentJSON()) }
        try await writer.run { [weak self] db in
            try db.transaction {
                try db.execute("PRAGMA defer_foreign_keys=ON") // Родитель может войти в пакет позже потомка.
                for id in batch.deletes {
                    try db.run("DELETE FROM blocks WHERE id=?", [SQLValue(id)])
                }
                for (b, json) in rows {
                    try db.run("""
                    INSERT INTO blocks(id, page_id, parent_id, sort_key, type, content_v, content_json, plain_text, created_at, updated_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET page_id=excluded.page_id, parent_id=excluded.parent_id, sort_key=excluded.sort_key,
                        type=excluded.type, content_v=excluded.content_v, content_json=excluded.content_json,
                        plain_text=excluded.plain_text, updated_at=excluded.updated_at
                    """, [SQLValue(b.id), SQLValue(b.pageID), SQLValue(b.parentID), .text(b.sortKey), .text(b.type.rawValue),
                          .int(Int64(b.contentVersion)), .text(json), .text(b.plainText), .int(b.createdAt), .int(b.updatedAt)])
                }
                for (id, title) in batch.titles {
                    try db.run("UPDATE pages SET title=?, updated_at=? WHERE id=?", [.text(title), .int(now), SQLValue(id)])
                }
                for id in batch.touchedPages {
                    try db.run("UPDATE pages SET updated_at=?, content_rev=content_rev+1 WHERE id=?", [.int(now), SQLValue(id)])
                }
                try self?.faultHook?("before-commit")
            }
            try self?.faultHook?("after-commit")
        }
    }

    // MARK: История

    private struct SnapshotBlock: Codable {
        var id: UUID, parent: UUID?, key: String, type: String, v: Int, json: String, text: String, created: Int64, updated: Int64
    }

    func saveRevision(pageID: UUID, reason: String, blocks: [Block], id: UUID, now: Int64) async throws -> Revision? {
        let snapshot = try blocks.map {
            SnapshotBlock(id: $0.id, parent: $0.parentID, key: $0.sortKey, type: $0.type.rawValue, v: $0.contentVersion,
                          json: try $0.contentJSON(), text: $0.plainText, created: $0.createdAt, updated: $0.updatedAt)
        }.sorted { ($0.key, $0.id.uuidString) < ($1.key, $1.id.uuidString) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let raw = try encoder.encode(snapshot)
        // Хэш без отметок времени: повторный снимок того же содержимого не нужен.
        let stable = try encoder.encode(snapshot.map { b -> SnapshotBlock in var c = b; c.updated = 0; return c })
        let hash = SHA256.hash(data: stable).map { String(format: "%02x", $0) }.joined()
        let packed = try (raw as NSData).compressed(using: .zlib) as Data
        return try await writer.run { db in
            try db.transaction {
                let last = try db.scalarText("SELECT content_hash FROM revisions WHERE page_id=? ORDER BY seq DESC LIMIT 1", [SQLValue(pageID)])
                if last == hash { return nil }
                let seq = Int(try db.scalarInt("SELECT COALESCE(MAX(seq),0)+1 FROM revisions WHERE page_id=?", [SQLValue(pageID)]) ?? 1)
                try db.run("""
                INSERT INTO revisions(id, page_id, seq, created_at, reason, format_v, codec, payload, content_hash, byte_size)
                VALUES(?,?,?,?,?,1,'zlib',?,?,?)
                """, [SQLValue(id), SQLValue(pageID), .int(Int64(seq)), .int(now), .text(reason), .blob(packed), .text(hash), .int(Int64(raw.count))])
                return Revision(id: id, pageID: pageID, seq: seq, createdAt: now, reason: reason, contentHash: hash, byteSize: raw.count)
            }
        }
    }

    func revisions(ofPage id: UUID) async throws -> [Revision] {
        try await reader.run { db in
            try db.query("SELECT id, page_id, seq, created_at, reason, content_hash, byte_size FROM revisions WHERE page_id=? ORDER BY seq DESC", [SQLValue(id)]) { r -> Revision? in
                guard let rid = r.uuid(0), let pid = r.uuid(1) else { return nil }
                return Revision(id: rid, pageID: pid, seq: Int(r.int(2)), createdAt: r.int(3), reason: r.text(4), contentHash: r.text(5), byteSize: Int(r.int(6)))
            }.compactMap { $0 }
        }
    }

    func revisionBlocks(_ revisionID: UUID) async throws -> [Block] {
        try await reader.run { db in
            let rows = try db.query("SELECT page_id, payload FROM revisions WHERE id=?", [SQLValue(revisionID)]) { ($0.uuid(0), $0.blob(1)) }
            guard let row = rows.first, let pageID = row.0 else { return [] }
            let raw = try (row.1 as NSData).decompressed(using: .zlib) as Data
            return try JSONDecoder().decode([SnapshotBlock].self, from: raw).map {
                Block(id: $0.id, pageID: pageID, parentID: $0.parent, sortKey: $0.key, type: BlockType(rawValue: $0.type),
                      contentVersion: $0.v, contentJSON: $0.json, plainText: $0.text, createdAt: $0.created, updatedAt: $0.updated)
            }
        }
    }
}

/// Проверка файла снимка: используется при создании и восстановлении резервной копии.
struct SQLiteSnapshotInspector: SnapshotInspector {
    var supportedSchemaVersion: Int = Migrations.supportedVersion

    func inspect(_ databaseFile: URL) throws -> SnapshotInfo {
        let db = try SQLiteConnection(path: databaseFile.path, readOnly: true)
        defer { db.close() }
        guard try db.scalarInt("PRAGMA application_id") == Migrations.applicationID else {
            throw WorkspaceError.backupInvalid("это не база Grizzly Notes")
        }
        let integrity = try db.scalarText("PRAGMA integrity_check(1)") ?? ""
        guard integrity == "ok" else { throw WorkspaceError.backupInvalid("integrity_check: \(integrity)") }
        guard try db.query("PRAGMA foreign_key_check", [], { $0.text(0) }).isEmpty else {
            throw WorkspaceError.backupInvalid("нарушены связи между записями")
        }
        guard let id = try db.scalarText("SELECT value FROM workspace_meta WHERE key='workspace_id'").flatMap(UUID.init(uuidString:)) else {
            throw WorkspaceError.backupInvalid("нет идентификатора пространства")
        }
        let assets = try db.query("SELECT id, rel_path, original_name, mime, byte_size, sha256, created_at FROM assets") { r -> AssetRecord? in
            guard let aid = r.uuid(0) else { return nil }
            return AssetRecord(id: aid, relPath: r.text(1), originalName: r.text(2), mime: r.optText(3), byteSize: r.int(4), sha256: r.text(5), createdAt: r.int(6))
        }.compactMap { $0 }
        return SnapshotInfo(workspaceID: id, schemaVersion: Int(try db.scalarInt("PRAGMA user_version") ?? 0), assets: assets)
    }

    func assignNewIdentity(_ databaseFile: URL, newID: UUID, now: Int64) throws {
        let db = try SQLiteConnection(path: databaseFile.path)
        defer { db.close() }
        try db.transaction {
            let old = try db.scalarText("SELECT value FROM workspace_meta WHERE key='workspace_id'") ?? ""
            try db.run("UPDATE workspace_meta SET value=? WHERE key='workspace_id'", [SQLValue(newID)])
            try db.run("INSERT OR REPLACE INTO workspace_meta(key, value) VALUES('restored_from', ?)", [.text(old)])
            try db.run("INSERT OR REPLACE INTO workspace_meta(key, value) VALUES('restored_at', ?)", [.text(String(now))])
        }
    }
}
