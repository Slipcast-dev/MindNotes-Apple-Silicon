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
