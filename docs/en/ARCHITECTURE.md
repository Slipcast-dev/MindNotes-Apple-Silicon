# MindNotes architecture

**English** · [Русский](../personal-ru/ARCHITECTURE.md)

Status: the app's current design after M0–M14 (workspace schema v10). Progress is in `STATUS.md`, decisions are ADRs in `docs/personal-ru/adr/` (both in Russian).

Constraints: one module, built with `swiftc`, no external dependencies, arm64 and macOS 26 only (ADR-0009, `scripts/target.sh`). Network is used only for link previews, updates and the optional AI, inside `Shell/Network/` (ADR-0011, ADR-0014). Target: 10k pages, 100k blocks, one user, one process per workspace.

## 1. Modules and boundaries

```text
Sources/MindNotes/
  App/                       # entry point, AppDelegate, appearance settings
  Core/                      # AppEdition (name, id, data folder, migration from old names), localisation
  Workspace/Domain/          # Page, Block, RichText, databases and formulas, timeline, mentions, comments, sections, extensions, updates
  Workspace/Services/        # WorkspaceSession, EditorSession (incl. synced blocks), SaveCoordinator, data transfer
  Persistence/               # SQLiteConnection, queues, locking, Migrations/ (v1–v10), SQLiteWorkspace+*, SearchIndex
  BlockEditor/Commands/      # BlockDocument, EditCommand, UndoStack, fragments, atomic block data
  BlockEditor/UI/            # native editor (Native/), panels and page model
  Backup/                    # TarArchive, BackupService, RestoreService
  ImportExport/              # Markdown, CSV, folders, Notion export, workspace export
  Shell/                     # RootView, ShellModel, sidebar, Screens/, Database/, extensions, design tokens
  Shell/AI/                  # optional AI (ADR-0016, ADR-0018): settings, selection panel, chat and agent with confirmation, AI properties
  Shell/Plugins/             # plugin host (ADR-0019): .mnplugin install, permissions, client pairing, clips
  Shell/Network/             # the only place with network access: link previews, updates, the AI client and keys in the keychain, the plugins' local API
Plugins/WebClipper/          # plugin: Chrome/Safari extension (built by scripts/build-webclipper.sh)
```

| Layer | Imports | May use |
|---|---|---|
| Workspace/Domain | Foundation | nothing |
| BlockEditor/Commands | Foundation | Domain |
| Workspace/Services | Foundation | Domain, Commands, ports |
| Persistence | Foundation, SQLite3 | Domain |
| Backup | Foundation, CryptoKit | Domain, snapshot port |
| BlockEditor/UI, Shell | SwiftUI, AppKit | everything above; dependencies are wired only in Shell |

`scripts/check-layers.sh` enforces the boundaries: a grep for forbidden imports and `swiftc -typecheck` over growing subsets (a reference to a higher layer fails to compile).

Tests: `tests/swift-notes/` and `scripts/test-notes.sh`, `-Onone`, files collected with `find`. Crashes are simulated by self-relaunch with `--crash-at=<point>` and `_exit`; a full disk with `PRAGMA max_page_count`; missing permissions with `chmod 0500`; time through the `SaveScheduler` port.

## 2. Schema

UUIDs are lowercase TEXT, times are INTEGER (ms UTC). `application_id=0x47525A4E`, `user_version` is the latest migration (now 10), `foreign_keys=ON`.

| Table | Columns | Indexes |
|---|---|---|
| workspace_meta | key PK, value | WITHOUT ROWID |
| schema_migrations | version PK, name, applied_at, app_version | |
| pages | id, parent_id FK SET NULL, sort_key, title, icon, cover_asset_id FK, full_width, favorite_key, created_at, updated_at, last_opened_at, deleted_at, trash_batch_id, content_rev | partial (deleted_at IS NULL): (parent_id, sort_key, id), (favorite_key), (last_opened_at DESC); (deleted_at); (cover_asset_id) |
| blocks | id, page_id FK CASCADE, parent_id FK CASCADE, sort_key, type (no CHECK), content_v, content_json, plain_text, created_at, updated_at | (page_id, parent_id, sort_key, id); (parent_id) |
| revisions | id, page_id FK CASCADE, seq, created_at, reason, format_v, codec, payload, content_hash, byte_size | UNIQUE(page_id, seq); (page_id, created_at DESC) |
| tags (v2) | id, name, name_key UNIQUE, color, created_at | case- and ё/е-insensitive |
| page_tags (v2) | page_id FK CASCADE, tag_id FK CASCADE | WITHOUT ROWID; (tag_id) |
| assets | id, rel_path UNIQUE, original_name, mime, byte_size, sha256, created_at, unreferenced_since | (sha256); partial on unreferenced_since |
| block_assets, revision_assets | owner_id FK CASCADE, asset_id FK RESTRICT | WITHOUT ROWID; (asset_id) |

- Block content is `{"runs":[{"t":"Hello","m":["b"]}], ...}`. Unknown fields are preserved; an unknown `type` or a newer `content_v` is stored opaquely.
- Workspace look (logo, cover) is JSON in `workspace_meta.look`; images are managed files in `assets/`.
- Versions: v2 — tags; v3 — `search_index` (FTS5), `page_links`; v4 — databases (`databases`, `property_definitions`, `property_options`, `property_values`, `property_value_options`, `database_views`, `pages.database_id`); v5 — `templates`; v6 — relations; v7 — formulas; v8 — people, files in properties, manual order (`people`, `property_value_people`, `property_value_assets`, `view_record_order`); v9 — sections (`page_sections`, `page_section_members`); v10 — `comments`.
- A database is a page (`databases.page_id`); a record is a page with `database_id` whose parent is the database page: tree, trash, search, archive and editor are shared. Records are hidden from the sidebar while their database is not in the trash.
- A date without time is a `YYYY-MM-DD` string and is never converted to an instant. An instant is `value_ts` (ms UTC), `value_tz`, and wall-clock time in `value_date` for comparison.
- Queries (`DatabaseQuerySQL`): operators from the `FilterOp.available(for:)` whitelist; values and property IDs are always bound parameters. An incomplete or unknown rule is skipped. Text comparison uses the `mindnotes_norm` function on the reader connection, never in the schema.
- Type change: value → text → new type. One computation for preview and apply; failures are kept in `property_values.unconverted`.
- Views: `table`, `board`, `list`, `calendar`, `gallery`, `timeline`. A group is an ordinary filter rule on top of the state (`narrowed(by:)`), so there is one query mechanism and columns and sections load in chunks. The calendar queries the month's records with the same rules. A move changes the property value with a normal write, and other views see it on read.
- An inline view is an atomic `database_view` block: the database page, a view and its own state in the block's JSON. Records are not copied. In the text it is a live view (the same database screen placed over its slot in the text, ADR-0013); without it, a card with the first records.
- A template is a hidden copy of a page with its subtree: `deleted_at` set, `trash_batch_id` empty (ADR-0008). Creation goes through `copySubtree`, shared with duplication.
- View state is JSON in `database_views.state_json`; unknown fields and operators are preserved. Deleting a property or option and changing a type clean up rules in the same transaction.
- Order keys are fractional base-62 strings, BINARY comparison, ties broken by `id`; longer than 48 characters triggers renumbering of neighbours in the same transaction.
- Trash: a subtree gets a shared `trash_batch_id`. Move: `BEGIN IMMEDIATE`, a cycle check with a recursive CTE, update.

## 3. Storage and saving

- Three connections, each on its own serial `DispatchQueue`: write, UI read, snapshots. An `async` wrapper outside.
- All connections: `foreign_keys=ON`, `busy_timeout=5000`, `trusted_schema=OFF`. Write: WAL, `synchronous=FULL`, `fullfsync=ON`, `checkpoint_fullfsync=ON`. Read: `query_only=ON`.
- Lock: `.workspace.lock`, `flock(LOCK_EX|LOCK_NB)` for the whole session; the file is never deleted.
- Opening: permissions → `flock` → READONLY check of `application_id`, `user_version`, `quick_check` → newer schema: refuse without writing → older: verified full backup and migration → open for write and read.
- Migration: its own `BEGIN EXCLUSIVE`, the step, `foreign_key_check`, `user_version`, `schema_migrations`, `COMMIT`. The base schema for migration tests is `tests/fixtures/notes/schema_v1.sql`; each version is covered by an upgrade test from the previous one.
- `SaveCoordinator`: `editSeq` grows with every edit; timer `min(lastEdit+500 ms, firstDirty+2 s)`; one batch per write. Status is derived: `saved` only when `editSeq == committedSeq` after COMMIT is confirmed.
- Write error: the batch is merged back under new edits, retries after 1/2/5/15 s and manually, emergency export from memory.
- A write never pushes data back into an open editor. Moving to another page and quitting wait for `flush`; after 5 s quitting shows “Retry / Emergency export / Quit without saving”.
- History: a snapshot at most every 10 minutes when changed, on leaving a page and before a restore, zlib, skipped on the same hash. Retention (`RevisionRetention`): everything for 24 h, hourly for 7 days, daily for 30 days, weekly after that; the newest snapshot is always kept. Thinning runs after each page snapshot.
- Attachments: `tmp/` on the same volume, `fsync`, `rename` to `assets/<2hex>/<uuid>[.ext]`, then the transaction. Files are immutable. Orphans are cleaned after a grace period, never during a backup.

## 4. Backup

Format: a single `.mindnotesbackup` file (archives of earlier versions in the same format are read too), uncompressed ustar (see `adr/0003-backup-format.md`).

Creation: `sqlite3_backup` into a temporary file → `integrity_check`, `foreign_key_check` on the copy → attachment list from the copy → streaming into `.partial` with SHA-256 checked against `assets.sha256` → `manifest.json` and `manifest.sha256` last → `fsync`, `rename`. No manifest means a truncated archive. Missing files go into `missing`, and the backup is not considered complete.

Restore: only into a new or empty folder, working in `<target>.restoring`. Regular files only; names from a whitelist; extra or duplicate entries are refused. Checks of SHA-256, contents, schema version, `integrity_check`, attachments. A new `workspace_id`, the old one in `restored_from`, then `rename`.

A full verified backup is always made before a migration.

## 5. Isolation

A single point: `Core/AppEdition.swift`. Separate identifier and data folder; `UserDefaults` are separated automatically; the build does not register itself as a default handler.

Real data belongs only to the build with the official identifier (`AppDataScope`). A copy with another identifier gets the folder `MindNotes-Test-<identifier>` and skips migration from old names. `scripts/run-isolated.sh` launches such a copy.

## 6. Shell

- The window root is `RootView` with the `NotesLayout` layout: sidebar (240 by default, 200–480, collapses with ⌘\\), a 54-point path bar, content; Peek and the update window on top.
- Window title bar: the name and the theme switcher, nothing else.
- `ShellModel` is owned by `AppDelegate`; no new singletons. Navigation is sequential (`enqueue`).
- `Shell/DesignTokens.swift`: dynamic `NSColor`s with values from the mock-up CSS.
- The “Import” screen: sources (Markdown, CSV, folder, Notion export) and recent files with preview.
- Values derived from the page list (`PageTree`, favourites, recents) are computed once per change in `ShellModel`: the UI reads them on every redraw.
- The sidebar is a flat `LazyVStack` of `PageTree.rows`: only visible rows are built. Moving a page uses the `MovePageSheet` window rather than a context submenu, because SwiftUI computes context-menu contents together with the row.

## 7. Editor

One `NSTextView` per page, TextKit 1: see `adr/0005-block-editor.md`.

Menu items, the toolbar and `/` are built from one `EditorAction` list.

Commands are a pure function `apply(EditCommand, BlockDocument, BlockSelection, IDGenerator) -> EditResult`: `changes` go to `SaveCoordinator`, `inverse` to `UndoStack`.

View: `BlockEditor/UI/Native/` (`BlockEditorController`, `BlockTextView`), covered by tests without the shell. Columns and live views are separate views placed over their slot in the text (ADR-0013): each column has its own controller with a `scope` on the same session. The synced block is a translation layer in `EditorSession` (ADR-0012).

## 8. Rules

- SwiftUI/AppKit are forbidden in Domain, Services, Commands, Persistence and Backup; `sqlite3_*` only in Persistence.
- Writes only through `WriteQueue`, one transaction per batch; a connection never leaves its queue.
- “Saved” is derived only from a confirmed `committedSeq`.
- Every block edit goes through `EditCommand`.
- Unknown types, versions and fields are preserved losslessly.
- File first, then the database reference; paths are relative only and validated.
- A newer schema version is never opened for writing.

## 9. Risks

1. Views nested over `NSTextView` (columns, live views): slot height and position are recomputed after edits; mistakes show up as misplacement, not data loss.
2. Benchmarks on a device weaker than the reference one are not acceptance results.
3. `fullfsync` latency: if it becomes a problem, only batching helps.
4. Our own SQLite wrapper: statement lifetime, `SQLITE_TRANSIENT`.
5. Our own TAR reader handles untrusted input: tests for `../`, symlinks, duplicates, truncation.
6. Updates without a Developer ID signature verify the image only against the checksum from the same release (ADR-0014).
