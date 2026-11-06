# Changelog

All notable changes are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [1.4.2] - 2026-11-03

### Changed
- **License**: Grizzly is now under the proprietary Grizzly Proprietary License instead of MIT. Modifying and redistributing the app without the author's written consent is prohibited. The license is shown in *Settings → Updates*, in the README, in the app bundle and in the repository.

## [1.4.1] - 2026-11-02

> The fixes and the glass settings are in the **macOS** app. The Windows build is version-aligned and unchanged.

### Changed
- **Glass effect** (macOS): the sidebar, the tab bar and the document now have their own transparency sliders (*Settings → Appearance*), instead of one slider for everything. The material picker (Window, Sidebar, Dark Glass) is gone: the blur is always the standard window material. The sidebar slider at 100% keeps the system look and makes the sidebar denser as it goes down. The tab bar starts from your previous transparency.

### Fixed
- **Themes** (macOS): Light, Dark and *Same as system* now change the whole app (sidebar, toolbar, Settings and panels), not only the document area, so nothing stays in the previous scheme; *Same as system* follows the system switch, also the automatic one.
- **Window shrinking into the Dock** (macOS): a file opened from Finder while another is already open no longer minimizes the window; the window comes back to the front.

## [1.4.0] - 2026-11-01

> Both new features are in the **macOS** app. The Windows build is version-aligned and keeps the feature set of 1.3.0.

### Added
- **Smart folders** (macOS): the *New folder* button of the sidebar opens a menu with *New Folder* and *Smart Folder…*. A smart folder (folder-and-gear icon, as in Apple Notes) has a settings sheet with a name, tags (all or any of them), file types and a sort order (name, file type, date opened). Files come into the folder by themselves as soon as a chosen `#tag` appears in their text, or by type alone when no tag is set; the sheet shows how many files fit. Files stay where they are, deleting the folder never removes them, tags renamed or deleted are updated in the rules.
- **Look inside folders, archives and disk images** (macOS): Space on a folder of the sidebar (or *Quick Look* in its menu) lists its contents with sizes. Opening or dropping a `.zip`, `.tar(.gz/.bz2/.xz)`, `.7z`, `.rar`, `.jar`, `.pkg`, `.iso` or `.dmg` shows the same list instead of opening a tab. Nothing is unpacked; a `.dmg` is attached read-only, hidden from Finder and detached again at once.

## [1.3.0] - 2026-10-31

> **Updating from 1.2.2 or older:** those versions can get stuck on "Installing…" (fixed in this release). If that happens, quit Grizzly
> and install this version from the `.dmg` by hand once; updates from 1.3.0 onward do not have the problem.
>
> The new editing, formatting, attachment and sidebar features are in the **macOS** app. The Windows build is version-aligned
> and keeps the feature set of 1.2.2.

### Added
- **Update patches** (macOS): a release can carry `Grizzly-patch-<from>-to-<to>-<arch>.zip` with only the files that changed (binaries as deltas). An app on exactly that version downloads the patch instead of the whole `.dmg`; every file of the result is checked against the manifest, and any mismatch falls back to the full image. `scripts/make-patch.sh` builds the patch.
- **Two modes instead of three**: *User* and *Developer* replace Reading / Source / Edit. *User* edits the text with the formatting code hidden: headings, bold, italic, highlights, lists with real markers, check boxes you can click (the ticked item moves to the end of its list, see *Settings → Text*), quotes with a bar, dividers, bordered tables, and an arrow next to Title and Heading lines that folds the section. *Developer* shows the file exactly as it is: all the markup, syntax colors, line numbers and bookmarks. The file is plain Markdown in both.
- **Formatting** (Markdown): a bar above the editor, a *Format* menu and the right-click menu (also modes, font, size and settings) with Title / Heading / Subheading / Body / Monospaced, bold, italic, underline, strikethrough, five soft highlight colors (violet, pink, orange, mint, blue), alignment, bulleted, dashed and numbered lists, check lists, quotes, a divider and tables (insert, add or delete rows and columns, move them, convert back to text). Return continues a list.
- **Attachments** (Markdown): photos, videos, PDF files, any files and links to web pages from the paperclip button, the *Format → Insert* menu, the right-click menu, by dragging files onto the text, or by pasting (a copied picture or screenshot too; a web address pasted over selected text makes it a link). Files are copied next to the document into `<name>.assets` (very large ones are referenced in place) and written as ordinary Markdown. User mode shows the picture, a video preview with a play button, a PDF card with its first page, a file card; a click opens a video, PDF or file (a photo opens on a double click), ⌘-click opens a web link. Right-click an attachment to open, reveal or delete it.
- **Each pane has its own mode** in split view (User on one side, Developer on the other, so the code and the result are side by side) and **the divider between the panes can be dragged** (double-click makes the panes equal; the width is remembered).
- **Folders inside folders** in the sidebar (create inside a folder, move by drag and drop or *Move to…*); *Add folder* mirrors the whole directory tree.
- **Open a folder**: the *Open* dialog accepts folders; the folder appears in the sidebar with its supported files.
- **Fonts**: 16 popular families with Cyrillic come with the app (PT Sans, PT Serif, Inter, Roboto, Open Sans, Lato, Montserrat, Source Sans 3, Fira Sans, IBM Plex Sans / Serif, Lora, Playfair Display, JetBrains Mono, Fira Code, Source Code Pro; SIL Open Font License) and appear in *Settings → Text*.
- **Several folders and files at once** in the sidebar: ⌘-click and ⇧-click pick rows, and the right-click menu, drag and drop and the Delete key then act on all of them (move into a folder, update from disk, open, expand or collapse, remove). Removing asks once for the whole selection.
- **Glass effect** (macOS): the window is see-through and blurs what is behind it, like system apps. *Settings → Appearance* has a switch to turn it off, a transparency slider (0–100%) and a choice of material (Window, Sidebar, Dark Glass). On by default at 35%.
- **Interface font**: *Settings → Appearance* sets the font and the size (10–20 pt) of the sidebar, tabs, panels and settings. Menus of macOS and the window title stay in the system font.
- The **Tags** section of the sidebar can be folded and its height changed by dragging its upper edge.
- A **Settings button** (gear) at the right end of the toolbar.

### Changed
- In Markdown, `- item` is a dashed list and `* item` / `+ item` a bulleted one (both used to look the same).

### Fixed
- **Deleting a folder** in the sidebar removes it together with its subfolders and the files inside (after a question when it is not empty). The files on disk are never touched. Before, what was inside moved up a level.
- **Speed with big libraries**: the app no longer freezes when a folder with thousands of files is added or the library holds many files. Adding a folder is one step done in the background (it used to rewrite the whole library for every file), the sidebar keeps its folder lists and counts ready instead of recounting them on each redraw, the *Tags* and *Move to…* menus of the rows are built when clicked (they were built for every row at once), the library is saved a moment after the last change instead of on every one, subfolders of an added folder start collapsed, and the editor repaints the text only when it or a setting really changed (it did on every update of the window). Folders named `node_modules`, `Pods` and the like are skipped (at most 5000 files per folder); `#14b1f2`-like color codes are not taken for tags.
- **Open a folder**: the *Open* dialog no longer greys folders out; a folder is added to the sidebar with its supported files (other files in it are ignored).
- **The Settings button** in the toolbar opens the Settings window.
- **Update stuck on "Installing…"**: the app now quits for the restart even when AppKit declines to (a sheet or panel is open), and the helper tools run with a time limit.

## [1.2.2] - 2026-10-30

### Fixed
- **Updating from inside the app**: a dropped or slow connection no longer ends with "couldn't install". The download is retried up to five times and continues where it stopped; the message now says what went wrong. The macOS helper that swaps the app keeps the old copy until the new one is in place and writes a log (`grizzly-update.log` in the temporary folder).

### Added
- **The app comes back where you left it after an update**: open tabs, the active tab, split view, the Reading / Source / Edit mode and the scroll position are restored after the automatic restart (macOS and Windows).

## [1.2.1] - 2026-10-30

### Security
- **Updates**: a release without a published SHA-256 is no longer installed (macOS and Windows). Every redirect must stay on GitHub, download size is capped at 500 MB, and the Windows helper script is written to a private temporary folder.
- **Windows**: saving is limited to files you opened, created or picked in a dialog; all IPC handlers verify the calling page; files over 100 MB are not read; the library file is size-checked; DevTools are disabled in the packaged app; the page can no longer request device permissions; the Content-Security-Policy also forbids `object`, `base` and form submission.
- CodeQL workflow uses the same `checkout` version as CI.

## [1.2.0] - 2026-10-30

### Added
- **Check for updates** (*Settings → Updates*): asks GitHub for the latest release, says whether a newer version is out and, if so, downloads and installs it from inside the app (macOS: replaces the app from the `.dmg`; Windows: replaces the portable `.exe`). The SHA-256 from the release notes is verified when present, downloads are limited to GitHub over HTTPS. The check also runs silently on every launch and only speaks up when there is something new.
- **Spelling and grammar check** (Russian and English) in Edit mode for Markdown, TXT, RTF and TeX, with underlined mistakes (macOS: system checker with grammar; Windows: spelling with suggestions in the context menu). Switch in *Settings → Text*.
- **Tags**: create, rename and delete tags, assign them from a file's context menu, see all tags as chips at the bottom of the sidebar, click a tag to list its files. `#tag` in the search field searches tags.
- **Emoji**: an emoji button in Edit mode; saving a file in an 8-bit encoding (Windows-1251, ISO-8859-1) that cannot hold emoji offers UTF-8 instead of failing.

### Changed
- The sidebar filter is now **Search files**: it matches the beginning of a file or folder name, or of any word in it.
- Closing the window with unsaved edits asks about every changed file: save, don't save or cancel (macOS and Windows).

### Fixed
- **Tags appear while you type** (after a short pause), no save needed; discarding the edits takes them back. Tag names may contain **emoji** (`#🍕`, `#идея💡`).
- **Edit mode buttons**: *Undo* (reverts one step at a time: a word, a deletion, a paste) and *Save* share the look of the other buttons, with icons; the status line is gone.
- **Notifications**: short pop-ups for saving, copying, creating a file, reloading, tags, bookmarks and favorites.
- **Reading and Source are real text views**: drag across lines and paragraphs, `⌘A` / `Ctrl+A` selects everything, `⌘C` copies it (macOS; replaces the earlier overlay). Source keeps its line numbers and bookmarks.
- **Tags work like in Apple Notes**: a `#hashtag` written in a Markdown / text file is a tag of that file. Tags are colored in the text (Reading, Source, Edit) and a click on one lists the files that carry it. Typing `#` in Edit mode suggests the known tags. The sidebar tag browser has *All Tags* and chips you can combine (several tags show files that have all of them). *Rename Tag* and *Delete Tag* change the tag in the text of every file that uses it (after a confirmation; RTF files and files with unsaved edits are skipped). The library is scanned at launch.
- The emoji button moved to the rightmost spot of the toolbar.
- **Find** works in Edit mode too (hits are highlighted in the text being edited).
- macOS: after saving in Edit mode the text no longer disappears until the mode is switched.
- macOS: ⌘A in Reading and Source selects the whole document, ⌘C copies all of it (also *View → Select All Text*).

## [1.1.0] - 2026-10-30

### Added
- **Syntax highlighting for programming languages**: Python, Swift, C / C++, C#, JavaScript (JSX), TypeScript (TSX), CSS / SCSS and PHP, next to the existing JSON, YAML, INI/TOML, XML/HTML, TeX and log coloring. Keywords, types, literals, numbers, strings, comments, decorators / attributes, preprocessor lines and CSS properties follow the current theme. Multi-line block comments, triple-quoted strings and template literals are tracked across lines. Fenced code blocks in Markdown (```` ```python ````, `cpp`, `cs`, `js`, ...) use the same colors, and macOS colors the text live in Edit mode.
- **Syntax highlighting settings** (*Settings → Syntax highlighting*): one switch for everything and a switch per language, with *Turn On All* / *Turn Off All*.
- **New file** (`⌘N` / `Ctrl+N`, also a sidebar button): choose name, folder and format; the file is created from a small template and opens in Edit mode.
- Source-code extensions are supported: `py pyw swift c h cpp cc cxx hpp hh hxx cs js mjs cjs jsx ts tsx css scss php`. On macOS Grizzly is offered under *Open With* for them without claiming them as the default app. Sample files for every language are in `samples/`.
- **Hover and press effects on every button**: a soft tint of the theme's accent color on hover, a stronger tint and a small shrink while pressed.

### Changed
- **Settings are split into sections** (Appearance, Text, Syntax highlighting, Files, Language, and File types on macOS): a list on the left, cards on the right. The window can be resized in width and height, long sections scroll, scrollbars are always visible on Windows.
- **File actions live in the sidebar**: one row of equal buttons — New File, Open File, New Folder, Save As…. *Add Folder from Disk…* is in the File menu (`⇧⌘O` / `Ctrl+Shift+O`). The Reading / Source / Edit switch is centered at the top of the window.
- Sidebar and toolbar controls share one set of sizes and corner radii.

### Fixed
- **Select all**: the whole text of an open file can be selected at once (rows are lazily built only for files over 4000 lines). *View → Copy All Text* (`⌥⌘C`) copies the document; `Ctrl+A` on Windows.
- **Window size is remembered** between launches (macOS).
- The *Format* row of the Save As / New File dialog is centered like the other rows.

## [0.4.0] - 2026-10-30

### Added
- **Language setting**: *Settings → Language* — *Follow System*, Русский or English. On first launch (and until you choose) the interface follows the system language: Russian on a Russian system, English otherwise. macOS offers a restart after a change; Windows switches instantly, including the menu.

### Changed
- macOS: the app now has a single window (`LSMultipleInstancesProhibited`, no automatic window tabbing); a file opened while Grizzly is running always becomes a tab in that window. Windows already behaved this way (single-instance lock).
- macOS: the fallback language is now English for any system language other than Russian (development region `en`).

## [0.3.3] - 2026-10-29

### Fixed
- **History is kept**: files you opened stay in *Recent* after they are removed from the sidebar. The history is now stored separately from the library; opening an entry shows the file in a tab without adding it back to the sidebar. Entries can be removed one by one from the context menu, and *Clear* empties the list. Existing recents are migrated.
- **Save As…**: the name field no longer comes pre-filled with the extension. It holds just the name and the format chosen in the list is added on save, so saving as another format no longer means erasing the old extension first (an extension typed by hand still wins).
- macOS (Intel / x64): a file opened from Finder (double click, *Open With*) now opens in the app on launch. Files are accepted through every route the system may use (app delegate, scene `onOpenURL`) and queued until the app has started.

### Changed
- **Windows portable build is updated to 0.3.3** (was 0.2.1) and now has everything from 0.3.x: Save As…, the hardened file IPC, and the history fix above.

## [0.3.2] - 2026-10-29

### Added
- **Save As…** (toolbar button, `⇧⌘S` / `Ctrl+Shift+S`): saves a copy of the current file, including unsaved edits, in any supported format (Markdown, Text, JSON, YAML, CSV/TSV, Log, XML, HTML, INI/TOML, TeX, RTF) and in a place you choose. The open document is not changed.
- macOS: files opened from Finder (double click, Open With) or the Dock open as tabs in the existing window, and launch the app with the file when it is not running. The built-in extensions are now declared with the default handler rank.
- Unit tests and CI (`scripts/test.sh`, `.github/workflows/ci.yml`); `VERSION` is the single source of the version number.

### Security
- Quick Look: quotes are escaped in rendered Markdown and only `http`, `https` and `mailto` links are clickable.
- Windows: the main process now accepts file IPC only from the app's own page and only for absolute paths with supported extensions.

## [0.3.1] - 2026-10-28

### Fixed
- macOS: the Quick Look preview no longer spins forever; the extension is now declared as a data-based preview.
- Docs: troubleshooting for the Quick Look extension (listed twice in System Settings, preview not showing).

## [0.3.0] - 2026-10-28

### Added
- macOS: **Quick Look extension** — press Space on Markdown, YAML, CSV/TSV and log files in Finder to see them formatted, without opening Grizzly. Enable it in System Settings → Login Items & Extensions → Quick Look.
- macOS: **Settings → File types** — make Grizzly the default app for any supported extension with one click (or for all of them), and add your own extensions.
- macOS: Grizzly declares generic text and source-code types, so it can be chosen as the default app for extensions beyond the built-in list.

### Notes
- Use 0.3.1 or later: the Quick Look preview in 0.3.0 never finished loading.
- This release is macOS-only. The Windows portable build is unchanged and stays at 0.2.1.

## [0.2.1] - 2026-10-27

### Fixed
- A new sidebar folder is now created when the name field loses focus (not only on Return); previously an unconfirmed name vanished when switching sections, and the folder could not be opened, renamed, deleted or receive files.
- Clicking a folder row anywhere expands or collapses it.

## [0.2.0] - 2026-10-27

### Added
- Toolbar **Open** button (menu: open file, add folder from disk).
- Folders from disk: files of a directory and its subdirectories are added to the sidebar; "Refresh from folder" and "Show in Finder" in the folder menu; folders can be dropped into the window.
- Quick Look: Space or the context menu previews a sidebar file without opening it (system Quick Look on macOS, a text preview on Windows).

### Fixed
- Sidebar rows now react to clicks on the file name, not only at the row edges.
- Folder context menu (rename, delete) works on the whole folder row.

## [0.1.0] - 2026-10-27

First public release.

### Added
- Reading, source and edit modes for Markdown and text; CSV/TSV tables; syntax colors for JSON, YAML, INI/TOML, XML/HTML, TeX and logs.
- Line bookmarks, find with live highlighting, tabs, two files side by side.
- Virtual library with folders, recents and favorites.
- Live reload when files change on disk.
- Seven themes, light / dark / system appearance, font and size settings.
- Russian and English interface.
- Builds: macOS Apple Silicon (`.dmg`), macOS Intel (`.dmg`), Windows x64 portable (`.exe`).

[0.3.2]: https://github.com/Slipcast-dev/Grizzly/releases/tag/v0.3.2
[0.3.1]: https://github.com/Slipcast-dev/Grizzly/releases/tag/v0.3.1
[0.3.0]: https://github.com/Slipcast-dev/Grizzly/releases/tag/v0.3.0
[0.2.1]: https://github.com/Slipcast-dev/Grizzly/releases/tag/v0.2.1
[0.2.0]: https://github.com/Slipcast-dev/Grizzly/releases/tag/v0.2.0
[0.1.0]: https://github.com/Slipcast-dev/Grizzly/releases/tag/v0.1.0
