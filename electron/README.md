# Grizzly — Windows (Electron)

Port of the macOS SwiftUI app. Same features: Markdown reading mode, source view with line numbers and
bookmarks, CSV tables, syntax coloring (Python, Swift, C/C++, C#, JavaScript, TypeScript, CSS, PHP, JSON, YAML, INI, XML/HTML, TeX, logs), New File, find, two panes side by side,
tabs, Save As (copy in any supported format), virtual library with folders / favorites and an open history, themes, reload on change, drag and drop,
Russian and English UI.

## Run from source

    npm install
    npm start

## Build the portable .exe

    npm run dist

The result is `dist/Grizzly-<version>-portable.exe`. It needs no installation: settings and the library
are stored in a `GrizzlyData` folder next to the .exe (or in `%APPDATA%` if that folder is read-only).

Command line: `Grizzly-<version>-portable.exe file1.md file2.csv` opens the files; a second launch hands its
files to the running window.

`npm run strings` regenerates the English table from `../resources/en.lproj/Localizable.strings`.
`npx electron scripts/smoke.js <files>` launches the real app and prints the renderer state (dev check).
