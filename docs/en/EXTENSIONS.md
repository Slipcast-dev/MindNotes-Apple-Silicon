# MindNotes extensions

**English** · [Русский](../personal-ru/EXTENSIONS.md)

Extensions are folders in `~/Library/Application Support/MindNotes/Extensions/` (Settings → “Extensions” → “Open Extensions Folder”). Extensions never run code: only descriptions and images (ADR-0015). After editing, press “Refresh”.

## Custom theme

```
Extensions/ocean/
  manifest.json
  theme.json
```

`manifest.json`:

```json
{ "id": "my.ocean", "name": "Ocean", "version": "1.0", "kind": "theme", "minApp": "1.3.0" }
```

`theme.json` — every field for both light and dark mode, colours as `#RRGGBB`:

```json
{
  "light": { "paper": "#FFFFFF", "side": "#F1F6FA", "ink": "#1C2B36", "muted": "#5F7383", "line": "#DDE6EE",
             "accent": "#1F6FB2", "soft": "#E6EFF7", "card": "#FFFFFF", "primary": "#1F6FB2", "logo": "#1F6FB2", "danger": "#C0392B" },
  "dark":  { "paper": "#13202B", "side": "#0F1A23", "ink": "#E3EDF5", "muted": "#9AB0C0", "line": "#26394A",
             "accent": "#6FB3EA", "soft": "#1D3142", "card": "#182836", "primary": "#2B6EA3", "logo": "#2B6EA3", "danger": "#E8988F" }
}
```

Choose it in Settings → “Custom theme”.

## App icon

A `manifest.json` with `"kind": "appIcon"` and an `icon.png` of 1024×1024 (up to 5 MB). Choose it in Settings → “App icon”.

## Next

New kinds (page templates, icon sets, ready-made snippets for the `/` menu) plug into the same `ExtensionRegistry`. An unknown kind is listed as “not supported by this version” and breaks nothing.

## Plugins

A plugin is a `Name.mnplugin` package with a `"kind": "plugin"` `manifest.json` (ADR-0019). Its code runs **outside** MindNotes (in a browser or its own app) and talks to the app through the local API at `http://127.0.0.1:27183`, limited to the permissions in its manifest.

Install: double-click the package or Settings → Extensions → “Install Plugin…”. MindNotes shows the permissions and asks for consent; the same section turns a plugin off, removes it (to the Trash) and disconnects browsers.

```json
{ "id": "my.plugin", "name": "My plugin", "version": "1.0.0", "kind": "plugin", "api": 1,
  "permissions": ["pages.list", "pages.create"], "components": { "chrome": "browser/chrome" } }
```

| Permission | Grants |
|---|---|
| `pages.list` | names of pages and folders you can save to (no password-locked pages, databases or records) |
| `pages.create` | create pages (`POST /v1/clips`) |
| `pages.open` | show a page in MindNotes |
| `assets.create` | add images as attachments |
| `tags.write` | tag the pages it creates |

A client connects with `POST /v1/pair {"plugin": "<id>"}`: MindNotes asks “Connect?” and returns a token on consent. Every later request carries `Authorization: Bearer <token>`. From a browser only extension pages are accepted; ordinary websites cannot reach the API.

The first plugin is **Web Clipper** (`Plugins/WebClipper/`): articles, selections, bookmarks, screenshots and images from Chrome and Safari. It is installed by the `MindNotes Web Clipper.app` installer (built by `./scripts/build-webclipper.sh`), which adds the plugin to MindNotes and the extension to every browser it finds; the connection to MindNotes sets itself up without questions for 10 minutes after installing (“Connect Browsers” in the plugin settings reopens that window).
