# Changelog

**English** · [Русский](CHANGELOG.ru.md)

All notable changes to MindNotes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [1.4.2] - 2026-11-12

### Fixed
- Updates no longer fail with “The request timed out”: the image is downloaded as a file instead of byte by byte on the main thread, which stalled the download. Versions 1.3.0–1.4.1 have the old downloader, so install this version from the `.dmg` once; later updates then work from the app.

## [1.4.1] - 2026-11-12

### Added
- **Keyboard shortcuts in Settings**: every menu command with its standard shortcut; set your own, remove one, or reset one or all to the standard ones.

### Changed
- The AI chat opens with ⌘L (was ⇧⌘J); the sidebar shows ⌘L next to “Notes AI”, like ⌘K next to Search.
- Clear formatting is ⌃⌘\ — it used to share ⌘\ with the sidebar.
- The sidebar item is now called “Notes AI”.
- The AI chat panel can be resized by dragging its left edge; the full provider and model name is shown at the bottom, with a menu to switch the model.
- AI settings: search models by part of their name.

## [1.4.0] - 2026-11-12

### Added
- **Drag sidebar sections** by the title, including “Pages”; “Move up” and “Move down” are available for every section. The order is stored in the workspace.
- **Password for a page, record, database or folder** (ADR-0017): “…” → “Set Password…”. The lock covers everything inside; unlock with the password, Touch ID or your Mac password, and it locks again after the display sleeps, the app restarts or “Lock Now”. Locked text stays out of search, backlinks, inline databases, copies, templates, export and AI. This is an app lock, not encryption.
- **AI providers** (ADR-0018): besides Anthropic, choose OpenAI, OpenRouter, Google Gemini, DeepSeek, Mistral, xAI, Groq, local Ollama or LM Studio, or any OpenAI-compatible server. Each provider has its own key in the keychain and its own model. The AI item in the sidebar now sits between Search and Home.
- **Optional AI assistant** (ADR-0016), off by default: “Ask AI” on selected text and ⌘J, AI on an empty line with Space, an AI chat (⇧⌘J) that answers about the open page or the whole workspace, an agent that proposes changes and applies them only when you click Apply, an empty-line hint, page mentions with “@” and saved chat history, an “AI instructions” page, “Don't send to AI” for pages, AI fill for database properties (text, numbers, dates, checkboxes, links and options) with an “AI-filled” mark, undo, auto-update and half-price batch mode, database tools for the agent, and file attachments in the chat. AI-filled cells show ✦, “Undo fill” survives a restart, refused batch items are retried, the agent can set people and relations, and a model without tool support still answers in the chat. Uses the Claude API with your own key stored in the macOS keychain; nothing is sent until you turn AI on.

## [1.3.0] - 2026-11-11

> Workspace schema v10 (sections, comments): version 1.2.0 cannot open an upgraded workspace. A snapshot is saved before the upgrade.

### Added
- **`@`-mentions** (M12): pages, people and dates with a local reminder. A mention is a single unit and its label follows when the page or person is renamed; page mentions appear in backlinks.
- **Bookmarks and embeds** (M12): a pasted link becomes text, a bookmark with the page's title, description and image, or an embed (YouTube, Vimeo, Figma, Google Maps) with a viewer window. Network access happens only on your action and only with “Link previews” turned on in Settings (off by default).
- **Synced block** (M12): an original and copies on other pages; editing any of them changes all. “Unsync copy”, jump to the original from its label. Copying an original pastes a copy.
- **Columns** (M13): drop a block by its handle onto the left or right edge of another block to place it in a column beside it (up to five per row); drag the gap to resize; on a narrow window columns stack. Blocks move between columns and the main text; a mouse selection across columns selects whole blocks for copy, cut and delete.
- **Live inline databases** (M13): a database right inside the page — table, board and other views with in-place editing, filters and sorts; drag the bottom edge to change the height.
- **Comments** (M14): on selected text (“Comment…” in the context menu) and on the whole page; threads with replies, “Resolved”, author from the people directory, a panel with all comments of the page. Stored in the workspace and in backups; not exported to Markdown.
- **Updates:** checks GitHub releases automatically (at launch and once a day) or manually; the “Version X is available” window offers “Download and install” or “Later”; the image is verified by SHA-256, then the app installs the update and relaunches.
- **Extensions:** custom themes and app icons from the extensions folder (Settings → Extensions); a foundation for future extension kinds. Extensions never run code.

### Changed
- **Black-and-white theme matched to Notion:** 16 pt text, 30/24/20 semibold headings, tighter block spacing, 708 text width, 14 pt sidebar rows, section titles in normal case.
- **Peek:** a database record opens at the side (about 45% of the width) or in the centre without leaving the current page; choose in View → Open records. ⌥-click on a link opens the page at the side. “Open as page”; Esc closes.
- **Collapsible sidebar** (⌘\\ or the button in the path bar), shown over the text when the pointer reaches the left edge; drag its border to resize (200–480), the width is remembered.
- **Page tree rows:** on hover, “+” (new subpage) and “…” (actions, including “Rename…”); the disclosure arrow is a separate target.
- Removed the “Local on this Mac” caption under the workspace name.
- **“Templates”** moved next to “New page”, “New folder”, “New database”; the empty “Workspace” group is gone.
- **Custom sidebar sections**, like “Pages”: “New section”, rename, “Move up/down”, “New page in section”; drag a page onto a section title or between its pages, or use the page menu (“Move to section”); all sections, including “Pages”, collapse with the arrow by the title. Deleting a section keeps its pages — they return to “Pages”.
- **“Delete all…” in the trash:** one confirmation with the page count, then everything is deleted permanently.
- **The “Pages” section can be renamed** (right-click its title; a normal click collapses it). The name is stored in the workspace: another workspace has its own or “Pages”.
- **“Files” and “Import” merged** into one sidebar item “Import”: sources at the top (Markdown or text, CSV table, folder, Notion export), recent files with preview and import below.

### Fixed
- Choosing a cover, logo or image: a file from iCloud is downloaded first and read the way Finder does; on failure the message names the reason (no folder access, file not downloaded, format not recognised) instead of a generic “Could not read the image”.
- Double-clicking the window's title bar zooms it again (or minimises it — as set in macOS): toolbar items were swallowing the click.
- A `[[` link shows the new title after the page is renamed, unless its text was edited by hand.

## [1.2.0] - 2026-11-11

### Added
- **Block colour** (M12): text colour or background for the whole block with its children, as in Notion.

## [1.1.0] - 2026-11-11

> **Workspace upgrade.** On first open, 1.1.0 upgrades the workspace schema to v8 after saving a verified snapshot. Version 1.0.0 cannot open an upgraded workspace: to go back to 1.0.0, restore the snapshot. Settings and backups of 1.0.0 are carried over automatically and its archives still open; new backups use the `.mindnotesbackup` extension. macOS may ask for folder access again.

### Added
- **Relations between databases.** Two-way by default: the reverse property appears in the other database. “No reverse relation” creates a one-way relation. A database can relate to itself. Related records are chosen by search. Filters and sorts work on relations. Relations to records in the trash are hidden and come back with the restored record.
- **Rollups.** A value from related records: 16 aggregates (count, sum, average, min, max, percent checked, earliest and latest date, and more), recalculated on every edit.
- **Formulas.** A formula language with English function names (38 functions, built-in help), `prop("Name")` references and `today()`. Validation shows the error position, result type and a preview on the first records. Renaming a property does not break a formula. Cycles between formulas and rollups are rejected. An error in a single record shows in its cell.
- **“Created” and “Edited” properties.** “Edited” counts both text and property edits.
- **“Person” property** and a people directory in Settings → People (name, colour, emoji). Filters “contains” and “empty”, sort by name, board grouping.
- **“Files & media” property:** a list of attachments, previews in the gallery; files are exported along with Markdown.
- **Timeline view:** bars by date on an hour, day, week or month scale that extends while scrolling and remembers its position; move and resize by the edges, time of day respected; manual row order; dependency arrows from a “Depends on” relation; undated records in a separate list; grouping.
- **Manual record order:** drag table rows, list rows, gallery and board cards. Each view has its own order; it does not apply while sorted.
- **Column width** in tables by dragging the header border, saved in the view.
- **⌘Z and ⇧⌘Z** for value edits, bulk changes and record moves in a database.
- **Data transfer.** CSV export writes relations as titles and rollups and formulas as values. A record's Markdown export starts with a property card where relations are `[[Title]]` links. Notion export import restores relations: the two columns of a two-way relation become one pair. Notion property lines at the start of a record no longer end up in its text.

### Changed
- **Renamed to MindNotes**, with a new identifier and data folder (ADR-0010).
- **Sidebar.** “Trash” and “Settings” are now at the bottom. “Backups” open from Settings. The “Local mode” caption is removed.
- **Search and similar windows** close on a click outside, just like with Esc.

### Fixed
- ⌘K, ⌘N and ⌘⇧N did not work if the workspace was opened after the app launched.

## [1.0.0] - 2026-11-10

First release: a personal knowledge base for Apple silicon Macs (macOS 26 and later), based on Grizzly 1.4.2.

### Added
- SQLite workspace: pages and subpages, block editor, trash, version history with restore.
- ⌘K search, `[[` links, backlinks, favourites, tags, templates.
- Databases: table, board, list, calendar, gallery, inline views.
- Attachments: images, files, video with a player.
- Import of Markdown, CSV, folders and Notion exports; export to Markdown and CSV.
- Manual and automatic backups, restore into a new folder.
