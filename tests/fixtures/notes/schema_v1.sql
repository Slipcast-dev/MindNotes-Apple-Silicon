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