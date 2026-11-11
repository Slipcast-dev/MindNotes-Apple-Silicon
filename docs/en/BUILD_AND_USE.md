# Build, run and restore

**English** · [Русский](../personal-ru/BUILD_AND_USE.md)

You need an Apple silicon Mac with macOS 26 or later and the Command Line Tools (`xcode-select --install`). Node.js is needed for the JS tests. Intel builds are not supported (ADR-0009).

## Build

```bash
./scripts/build-app.sh
```

Result: `build/MindNotes.app`, arm64, ad-hoc signed (this is not notarization). A debug build into another folder:

```bash
SWIFT_OPT=-Onone OUT=build/debug ./scripts/build-app.sh
```

App data (backups, settings) lives in `~/Library/Application Support/MindNotes`; the workspace itself is in the folder you choose.

## Test run

A copy with the identifier `local.personal.MindNotes.test` gets its own settings and data folder; your real data is not touched. Pick a workspace for it only in a temporary folder.

```bash
./scripts/run-isolated.sh
```

Quit the copy and delete everything it created, except the chosen workspace:

```bash
./scripts/run-isolated.sh clean
```

## Tests

```bash
./scripts/test.sh
```

The fast workspace suite without UI:

```bash
./scripts/test-notes.sh
```

Layer boundaries:

```bash
./scripts/check-layers.sh
```

Thread Sanitizer:

```bash
NOTES_OPT=-sanitize=thread ./scripts/test-notes.sh
```

Benchmarks on AT-17 data. The first run creates a workspace in the given folder, which must be temporary. Benchmarks only make sense with optimisation: the regular `test-notes.sh` builds without it.

```bash
NOTES_OPT="-O" ./scripts/test-notes.sh --bench-large /tmp/mindnotes-large
```

## Workspace

On first launch, create a workspace in an empty folder on a local disk. Do not keep an active workspace in a cloud-synced folder: this is not supported. Use an archive to move it.

The folder contains `workspace.sqlite`, an `assets/` folder and service files. Do not copy `workspace.sqlite` alone: some data may still be in the WAL journal.

## Backup and restore

Backups → “Create Backup” saves an archive to `~/Library/Application Support/MindNotes/Backups/`. “Save Backup As…” lets you pick another place. A backup on the same disk does not protect against that disk failing, so keep one on another drive as well.

“Restore from Archive…” creates a new workspace in a new empty folder after checking checksums and integrity. The current workspace is not changed.

A `.mindnotesbackup` archive is a plain tar; list its contents with `tar -tf`.

## Import and export

“Import” in the sidebar: sources (Markdown or text, CSV table, folder, Notion export as `.zip`) and recent files, which you can preview without changes and import as pages. CSV opens with a preview: encoding, delimiter, header row, the type of each column. A folder or archive is imported under a new page “Import — …” with a report at the top; to undo the import, move that page to the trash. The original files are never changed.

Export: a page — “…” → “Export to Markdown…”, a database — “Export to CSV…”, the whole workspace — Settings → “Export”. Export does not replace a backup: history, views and the trash are not included.

## Updates

Settings → “Updates”: “Automatic” (checks GitHub releases at launch and once a day) or “Manually” (“Check Now”, or MindNotes menu → “Check for Updates…”). When an update is found, the “Version X is available” window offers “Download and Install” or “Later”. The image is verified by SHA-256, then the app installs it and relaunches (ADR-0014).

## Extensions

Custom themes and app icons are folders with a `manifest.json` in the extensions folder (Settings → “Extensions” → “Open Extensions Folder”). Format and example: [EXTENSIONS.md](EXTENSIONS.md) (ADR-0015).

## Page password

“…” on a page, record, database or folder → “Set Password…”. The lock covers everything inside. Unlock with the password, Touch ID or your Mac password; it locks again after the display sleeps, the app restarts or “Lock Now”. This is an app lock, not encryption (ADR-0017): backups and the workspace file are not protected by the password.

## Editor

Block menu: `/` at the start of a line or after a space. Shortcuts: `# `, `## `, `### `, `- `, `1. `, `[] `, `> `, `---`. Formatting: ⌘B, ⌘I, ⌘U, ⇧⌘X, ⌘E, ⇧⌘K; the same actions are in the “Format” menu, the context menu and the toolbar that appears over a selection. Tab and Shift+Tab change nesting.

## Demo workspace

```bash
./scripts/make-demo.sh
```

Creates `build/demo/Демо-пространство` with fictional pages and a “Tasks” database, a verified archive next to it, and prints its SHA-256. An existing demo is not overwritten.
