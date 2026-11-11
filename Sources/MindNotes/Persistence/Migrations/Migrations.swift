import Foundation

struct Migration {
    let version: Int
    let name: String
    let apply: (SQLiteConnection) throws -> Void
}

enum Migrations {
    /// Метка формата файла, а не название приложения: при смене метки существующие пространства перестанут открываться.
    static let applicationID: Int64 = 0x47525A4E // "GRZN"

    /// Полный список миграций. Изменять уже выпущенные миграции нельзя: только добавлять новые и fixture прошлой версии.
    static let all: [Migration] = [v1, v2, v3, v4, v5, v6, v7, v8, v9]

    static var supportedVersion: Int { all.last?.version ?? 0 }

    private static let v9 = Migration(version: 9, name: "разделы страниц") { db in
        try db.execute(schemaV9)
    }

    /// Свои разделы боковой панели (как «Страницы»): страница верхнего уровня входит в один раздел.
    /// Страница без строки — в стандартном разделе; удалённый раздел отпускает свои страницы туда же.
    static let schemaV9 = """
    CREATE TABLE page_sections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sort_key TEXT NOT NULL,
        created_at INTEGER NOT NULL
    );
    CREATE TABLE page_section_members (
        page_id TEXT PRIMARY KEY REFERENCES pages(id) ON DELETE CASCADE,
        section_id TEXT NOT NULL REFERENCES page_sections(id) ON DELETE CASCADE
    );
    CREATE INDEX page_section_members_section ON page_section_members(section_id);
    """

    private static let v8 = Migration(version: 8, name: "люди, файлы, ручной порядок") { db in
        try db.execute(schemaV8)
    }

    /// M10. Справочник людей пространства и свойство «Человек»; свойство «Файлы и медиа» (вложения держатся
    /// ссылкой RESTRICT, как у блоков); ручной порядок записей у каждого представления.
    static let schemaV8 = """
    CREATE TABLE people (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        color TEXT,
        emoji TEXT,
        sort_key TEXT NOT NULL,
        created_at INTEGER NOT NULL
    );
    CREATE TABLE property_value_people (
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        property_id TEXT NOT NULL REFERENCES property_definitions(id) ON DELETE CASCADE,
        person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
        sort_key TEXT NOT NULL,
        PRIMARY KEY(page_id, property_id, person_id)
    ) WITHOUT ROWID;
    CREATE INDEX property_value_people_person ON property_value_people(person_id);
    CREATE INDEX property_value_people_prop ON property_value_people(property_id, person_id);
    CREATE TABLE property_value_assets (
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        property_id TEXT NOT NULL REFERENCES property_definitions(id) ON DELETE CASCADE,
        asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
        sort_key TEXT NOT NULL,
        PRIMARY KEY(page_id, property_id, asset_id)
    ) WITHOUT ROWID;
    CREATE INDEX property_value_assets_asset ON property_value_assets(asset_id);
    CREATE INDEX property_value_assets_prop ON property_value_assets(property_id);
    CREATE TABLE view_record_order (
        view_id TEXT NOT NULL REFERENCES database_views(id) ON DELETE CASCADE,
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        sort_key TEXT NOT NULL,
        PRIMARY KEY(view_id, page_id)
    ) WITHOUT ROWID;
    CREATE INDEX view_record_order_key ON view_record_order(view_id, sort_key);
    """

    private static let v7 = Migration(version: 7, name: "формулы") { db in
        try db.execute(schemaV7)
    }

    /// Ошибка вычисления формулы в записи: значение пустое, текст ошибки показывается в ячейке.
    static let schemaV7 = """
    ALTER TABLE property_values ADD COLUMN calc_error TEXT;
    """

    private static let v6 = Migration(version: 6, name: "связи баз") { db in
        try db.execute(schemaV6)
    }

    /// Связь хранится одной строкой под прямым свойством; обратное свойство (`config_json.pair`) читает её со стороны `to_page`.
    /// Настройки свойства — JSON: цель связи и парное свойство. Типы «Создано» и «Изменено» берут время из `pages`.
    static let schemaV6 = """
    ALTER TABLE property_definitions ADD COLUMN config_json TEXT;
    CREATE TABLE relation_links (
        from_page TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        property_id TEXT NOT NULL REFERENCES property_definitions(id) ON DELETE CASCADE,
        to_page TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        sort_key TEXT NOT NULL,
        PRIMARY KEY(from_page, property_id, to_page)
    ) WITHOUT ROWID;
    CREATE INDEX relation_links_to ON relation_links(to_page, property_id);
    CREATE INDEX relation_links_prop ON relation_links(property_id);
    """

    private static let v5 = Migration(version: 5, name: "шаблоны") { db in
        try db.execute(schemaV5)
    }

    /// Шаблон — скрытая копия страницы: `deleted_at` задан, `trash_batch_id` пуст, поэтому страница не видна нигде и не считается корзиной.
    static let schemaV5 = """
    CREATE TABLE templates (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        root_page_id TEXT NOT NULL UNIQUE REFERENCES pages(id) ON DELETE CASCADE,
        database_id TEXT REFERENCES databases(id) ON DELETE CASCADE,
        created_at INTEGER NOT NULL
    );
    CREATE INDEX templates_db ON templates(database_id);
    """

    private static let v4 = Migration(version: 4, name: "базы данных") { db in
        try db.execute(schemaV4)
    }

    /// Запись — страница с `database_id`. Дата без времени — строка `ГГГГ-ММ-ДД` в `value_date`;
    /// момент — `value_ts` (мс UTC), пояс `value_tz` и настенное время в `value_date` для сравнения и сортировки.
    static let schemaV4 = """
    CREATE TABLE databases (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL UNIQUE REFERENCES pages(id) ON DELETE CASCADE,
        created_at INTEGER NOT NULL
    );
    ALTER TABLE pages ADD COLUMN database_id TEXT REFERENCES databases(id) ON DELETE SET NULL;
    CREATE INDEX pages_records ON pages(database_id, sort_key, id) WHERE database_id IS NOT NULL AND deleted_at IS NULL;
    CREATE TABLE property_definitions (
        id TEXT PRIMARY KEY,
        database_id TEXT NOT NULL REFERENCES databases(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        sort_key TEXT NOT NULL,
        created_at INTEGER NOT NULL
    );
    CREATE INDEX property_definitions_db ON property_definitions(database_id, sort_key, id);
    CREATE TABLE property_options (
        id TEXT PRIMARY KEY,
        property_id TEXT NOT NULL REFERENCES property_definitions(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        color TEXT,
        sort_key TEXT NOT NULL
    );
    CREATE INDEX property_options_prop ON property_options(property_id, sort_key, id);
    CREATE TABLE property_values (
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        property_id TEXT NOT NULL REFERENCES property_definitions(id) ON DELETE CASCADE,
        value_text TEXT,
        value_num REAL,
        value_date TEXT,
        value_date_end TEXT,
        value_ts INTEGER,
        value_ts_end INTEGER,
        value_tz TEXT,
        unconverted TEXT,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY(page_id, property_id)
    ) WITHOUT ROWID;
    CREATE INDEX property_values_prop ON property_values(property_id);
    CREATE INDEX property_values_num ON property_values(property_id, value_num) WHERE value_num IS NOT NULL;
    CREATE INDEX property_values_date ON property_values(property_id, value_date) WHERE value_date IS NOT NULL;
    CREATE TABLE property_value_options (
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        property_id TEXT NOT NULL REFERENCES property_definitions(id) ON DELETE CASCADE,
        option_id TEXT NOT NULL REFERENCES property_options(id) ON DELETE CASCADE,
        PRIMARY KEY(page_id, property_id, option_id)
    ) WITHOUT ROWID;
    CREATE INDEX property_value_options_option ON property_value_options(option_id);
    CREATE INDEX property_value_options_prop ON property_value_options(property_id, option_id);
    CREATE TABLE database_views (
        id TEXT PRIMARY KEY,
        database_id TEXT NOT NULL REFERENCES databases(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        sort_key TEXT NOT NULL,
        state_json TEXT NOT NULL
    );
    CREATE INDEX database_views_db ON database_views(database_id, sort_key, id);
    """

    private static let v3 = Migration(version: 3, name: "поиск и ссылки") { db in
        try db.execute(schemaV3)
        try SearchIndex.rebuild(db)
    }

    private static let v2 = Migration(version: 2, name: "теги") { db in
        try db.execute(schemaV2)
    }

    private static let v1 = Migration(version: 1, name: "начальная схема") { db in
        try db.execute("PRAGMA application_id=\(applicationID)")
        try db.execute(schemaV1)
    }

    /// Индекс и ссылки — производные данные: полностью перестраиваются из страниц и блоков.
    static let schemaV3 = """
    CREATE VIRTUAL TABLE search_index USING fts5(page_id UNINDEXED, block_id UNINDEXED, text, tokenize = "unicode61 remove_diacritics 0");
    CREATE TABLE page_links (
        block_id TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
        from_page TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        to_page TEXT NOT NULL,
        PRIMARY KEY(block_id, to_page)
    ) WITHOUT ROWID;
    CREATE INDEX page_links_to ON page_links(to_page);
    """

    static let schemaV2 = """
    CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        name_key TEXT NOT NULL UNIQUE,
        color TEXT,
        created_at INTEGER NOT NULL
    );
    CREATE TABLE page_tags (
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY(page_id, tag_id)
    ) WITHOUT ROWID;
    CREATE INDEX page_tags_tag ON page_tags(tag_id);
    """

    static let schemaV1 = """
    CREATE TABLE workspace_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at INTEGER NOT NULL, app_version TEXT NOT NULL);
    CREATE TABLE assets (
        id TEXT PRIMARY KEY,
        rel_path TEXT NOT NULL UNIQUE,
        original_name TEXT NOT NULL,
        mime TEXT,
        byte_size INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        unreferenced_since INTEGER
    );
    CREATE INDEX assets_sha256 ON assets(sha256);
    CREATE INDEX assets_unreferenced ON assets(unreferenced_since) WHERE unreferenced_since IS NOT NULL;
    CREATE TABLE pages (
        id TEXT PRIMARY KEY,
        parent_id TEXT REFERENCES pages(id) ON DELETE SET NULL,
        sort_key TEXT NOT NULL,
        title TEXT NOT NULL,
        icon TEXT,
        cover_asset_id TEXT REFERENCES assets(id),
        full_width INTEGER NOT NULL DEFAULT 0,
        favorite_key TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_opened_at INTEGER,
        deleted_at INTEGER,
        trash_batch_id TEXT,
        content_rev INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX pages_tree ON pages(parent_id, sort_key, id) WHERE deleted_at IS NULL;
    CREATE INDEX pages_favorites ON pages(favorite_key) WHERE deleted_at IS NULL AND favorite_key IS NOT NULL;
    CREATE INDEX pages_recent ON pages(last_opened_at DESC) WHERE deleted_at IS NULL;
    CREATE INDEX pages_trash ON pages(deleted_at) WHERE deleted_at IS NOT NULL;
    CREATE INDEX pages_cover ON pages(cover_asset_id) WHERE cover_asset_id IS NOT NULL;
    CREATE TABLE blocks (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        parent_id TEXT REFERENCES blocks(id) ON DELETE CASCADE,
        sort_key TEXT NOT NULL,
        type TEXT NOT NULL,
        content_v INTEGER NOT NULL,
        content_json TEXT NOT NULL,
        plain_text TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );
    CREATE INDEX blocks_order ON blocks(page_id, parent_id, sort_key, id);
    CREATE INDEX blocks_parent ON blocks(parent_id);
    CREATE TABLE revisions (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
        seq INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        reason TEXT NOT NULL,
        format_v INTEGER NOT NULL,
        codec TEXT NOT NULL,
        payload BLOB NOT NULL,
        content_hash TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        UNIQUE(page_id, seq)
    );
    CREATE INDEX revisions_recent ON revisions(page_id, created_at DESC);
    CREATE TABLE block_assets (
        owner_id TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
        asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
        PRIMARY KEY(owner_id, asset_id)
    ) WITHOUT ROWID;
    CREATE INDEX block_assets_asset ON block_assets(asset_id);
    CREATE TABLE revision_assets (
        owner_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,
        asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
        PRIMARY KEY(owner_id, asset_id)
    ) WITHOUT ROWID;
    CREATE INDEX revision_assets_asset ON revision_assets(asset_id);
    """
}

enum Migrator {
    /// Применяет недостающие миграции, каждую в своей транзакции. При ошибке всё откатывается.
    static func migrate(_ db: SQLiteConnection, migrations: [Migration], appVersion: String, now: Int64,
                        initialize: ((SQLiteConnection) throws -> Void)? = nil) throws {
        let current = Int(try db.scalarInt("PRAGMA user_version") ?? 0)
        let first = migrations.map(\.version).min()
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            do {
                try db.transaction(.exclusive) {
                    try migration.apply(db)
                    // Метаданные нового пространства — в той же транзакции: половинчатой базы быть не может.
                    if current == 0 && migration.version == first { try initialize?(db) }
                    let violations = try db.query("PRAGMA foreign_key_check") { $0.text(0) }
                    if !violations.isEmpty { throw WorkspaceError.corrupted("нарушены связи: \(violations.count)") }
                    try db.execute("PRAGMA user_version=\(migration.version)")
                    try db.run("INSERT INTO schema_migrations(version, name, applied_at, app_version) VALUES(?,?,?,?)",
                               [.int(Int64(migration.version)), .text(migration.name), .int(now), .text(appVersion)])
                }
            } catch {
                throw WorkspaceError.migrationFailed(version: migration.version, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }
}
