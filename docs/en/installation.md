# Installation

Grizzly ships as three downloads (1.4.2) on the [Releases page](https://github.com/Slipcast-dev/Grizzly/releases).

| Platform | Asset | Requires |
|---|---|---|
| macOS, Apple Silicon (M1 and later) | `Grizzly-1.4.2-arm64.dmg` | macOS 13 Ventura or newer |
| macOS, Intel | `Grizzly-1.4.2-x64.dmg` | macOS 13 Ventura or newer |
| Windows x64 | `Grizzly-1.4.2-portable.exe` | Windows 10 or 11, 64-bit |

Not sure which Mac you have? Apple menu → *About This Mac*: "Chip: Apple M…" means Apple Silicon, "Processor: Intel…" means Intel.

## 1. Verify the download

The release notes list a SHA-256 checksum for every file. Compare it with your download.

```bash
# macOS
shasum -a 256 ~/Downloads/Grizzly-1.4.2-arm64.dmg
```

```powershell
# Windows (PowerShell)
Get-FileHash $HOME\Downloads\Grizzly-1.4.2-portable.exe -Algorithm SHA256
```

If the values differ, delete the file and download it again. Do not run it.

## 2. macOS

1. Open the `.dmg` and drag **Grizzly** onto **Applications**.
2. The app is ad-hoc signed but **not notarized by Apple**, so the first launch is blocked by Gatekeeper.
   Do one of the following:
   - Right-click **Grizzly** in Applications → **Open** → **Open**; or
   - System Settings → Privacy & Security → *"Grizzly" was blocked* → **Open Anyway**; or
   - in Terminal, clear the quarantine flag:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Grizzly.app
     ```
3. Later launches work normally.

To make Grizzly the default app for a file type: Finder → select a file → *Get Info* (`⌘I`) → *Open with* → Grizzly → *Change All…*.

Or do it in Grizzly: *Settings → File types* — click an extension (or *Make Grizzly the default app for all*). You can add your own extensions there.

### Quick Look (preview with Space)

Grizzly ships a Quick Look extension that previews Markdown, YAML, CSV/TSV and log files in Finder without opening the app. Put `Grizzly.app` in `/Applications`, launch it once, then enable *Grizzly Quick Look* in *System Settings → General → Login Items & Extensions → Quick Look* (older macOS: *Privacy & Security → Extensions*). If the preview does not appear, run `qlmanage -r`.

Troubleshooting:
- *Grizzly* appears twice in the Quick Look list: macOS found more than one copy of the app. Keep only `/Applications/Grizzly.app` (delete other copies, e.g. from the Downloads folder or the mounted disk image), then run `qlmanage -r`.
- The preview does not appear or never loads: make sure the extension is switched on, then run `qlmanage -r` and press Space again.

## 3. Windows

1. Put `Grizzly-1.4.2-portable.exe` anywhere you like (a folder, a USB drive). There is no installer.
2. Double-click it. SmartScreen may show *"Windows protected your PC"* because the file is not signed:
   **More info → Run anyway**.
3. Settings and the library are stored in a `GrizzlyData` folder **next to the .exe**
   (or in `%APPDATA%\Grizzly` if that folder is read-only). Move the folder with the .exe to take your data along.

Command line: `Grizzly-1.4.2-portable.exe notes.md data.csv` opens the files. A second launch hands its files to the
window that is already running.

## Updating and uninstalling

Grizzly checks GitHub for a newer release at every launch and in *Settings → Updates*, and can download and install it for you (the app must be in a folder you can write to, normally *Applications*; on Windows the portable .exe is replaced). You can still update by hand: download the new release and replace the old file. The checksum from the release notes is verified before installing.

- **macOS:** drag Grizzly to the Trash. Optional data: `~/Library/Application Support/Grizzly` (library) and the
  `app.grizzly.Grizzly` preferences.
- **Windows:** delete the .exe and the `GrizzlyData` folder next to it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| macOS says the app is damaged | Run the `xattr` command above; if it persists, re-download and verify the checksum |
| macOS says the developer cannot be verified | Use *Open Anyway* in Privacy & Security |
| Windows shows SmartScreen | *More info → Run anyway* |
| Antivirus quarantines the .exe | The portable build is a self-extracting archive; verify the checksum and add an exception if it matches |
| Text shows as garbage | The file may use an unusual encoding; Grizzly tries UTF-8, UTF-16, Windows-1251, ISO-8859-1 |
