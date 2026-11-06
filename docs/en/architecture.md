# Architecture

Grizzly is two implementations of one design: a native macOS app and an Electron port for Windows. They share the
translation tables and file-type rules, not code.

```
Sources/Grizzly/          macOS app (SwiftUI, ~9k lines)
  App/        AppState (tabs, drafts, tags, notifications), Settings, Theme, `UpdateManager` (check, download, install), entry point and menu commands
  Core/       Document model, file loading/encodings, Markdown parser, CSV, syntax coloring (`SyntaxEngine` scans comments/strings across lines, `Syntax` maps roles to theme colors), search, `Updater` (release parsing, versions, checksums), `AppPatch` / `BinaryDelta` (update patches: only the changed files, binaries as deltas), `RichFormat` (formatting commands as text edits), `InlineMarkup`, `Attachments`, `FontLibrary` (bundled fonts), `ContentsLister` (contents of folders, archives and disk images without opening them: `bsdtar -t`, or a hidden read-only attach for a dmg)
  Features/   Tab bar, panes with a draggable divider, the editor (`EditorView`, `LiveTextView`: User mode hides the formatting code with `LiveStyler` and draws markers, tables and attachments in `LiveLayoutManager`; Developer mode uses `MarkdownStyler` and a line-number gutter), format bar and menus, attachments, find bar, sidebar with tag browser, settings (glass effect, interface font), notifications
  Render/     CSV table view
  Library/    Virtual library (folders / favorites / tags) and the open history, persisted as JSON
QuickLook/    Quick Look preview extension (.appex): HTML rendering of Markdown, CSV, YAML and logs;
              reuses Core/FileLoader, FileType, CSVTable and MarkdownParser
resources/    App icon, Localizable.strings (ru, en) and fonts/ (16 families under the SIL Open Font License)
electron/     Windows port
  main.js       Main process: window, menu, file I/O, spell check, single-instance handoff, portable data dir
  updater.js    Release check, download, checksum and the helper script that swaps the portable exe
  preload.js    Narrow bridge exposed to the renderer (contextIsolation)
  renderer/     UI in plain JS/CSS: state, core (parsers), ui
scripts/      build-app.sh, make-dmg.sh, make-patch.sh, test.sh
tests/        Swift test (swiftc) and JS tests (node --test); VERSION is the single source of the version
samples/      One file of each supported type for manual testing
```

## Data flow

1. A file URL arrives (open panel, drag and drop, command line).
2. `FileLoader` decodes it — UTF-8, UTF-8 BOM, UTF-16 BOM, then Windows-1251 and ISO-8859-1 as fallbacks — and remembers
   the encoding so that saving round-trips.
3. `FileType` maps the extension to a type; `Document` builds the representation (CSV table, or syntax-colored lines).
4. Each pane shows the document in its own mode (the text is always the Markdown of the file; User mode only hides and redraws the formatting code); `Search` produces matches that panes highlight.
5. After an in-app update the app saves its tabs, panes, mode and scroll position (UserDefaults on macOS, `session.json` on Windows), restarts, and restores them once; a record older than ten minutes is ignored.
6. A file watcher flags on-disk changes; the pane shows a reload banner and never overwrites unsaved edits silently.

## Security model

- The only network code is the update check: a GET to `api.github.com/repos/Slipcast-dev/Grizzly/releases/latest` at launch and from Settings. Downloads are accepted only from `github.com` / `*.githubusercontent.com` over HTTPS, must match the SHA-256 in the release notes (a release without one is refused). When the release carries a patch for the installed version, only the patch is downloaded: it is applied to a copy of the installed app and every file of the result is checked against the manifest, with the full image as the fallback, are limited in size, every redirect must stay on GitHub, and are installed only after unsaved edits were dealt with. There is no telemetry.
- HTML files are displayed as source, never rendered or executed.
- Electron renderer: `sandbox: true`, `contextIsolation: true`, `nodeIntegration: false`, and a
  Content-Security-Policy of `default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'`.
  File access happens in the main process through the preload bridge. The page cannot request device permissions, and DevTools are disabled in the packaged app.
- Every Electron IPC handler answers only the app's own page. File IPC accepts only absolute paths with supported extensions; writing is further limited to files the user opened, created or chose in a dialog, and files over 100 MB are not read.
- Quick Look HTML escapes quotes and makes only `http`, `https` and `mailto` links clickable.
- The library stores references (paths) and tags only. The one operation that edits the files it points to is *Rename tag* / *Delete tag*, which rewrites `#tag` in their text after a confirmation (RTF files and files with unsaved edits are skipped).
- Release builds are unsigned/ad-hoc signed; integrity is established with published SHA-256 checksums.

## Localization

`resources/{ru,en}.lproj/Localizable.strings` hold the UI strings. Russian keys double as source text; the Electron
port derives `strings-en.json` from the English file via `npm run strings`.
