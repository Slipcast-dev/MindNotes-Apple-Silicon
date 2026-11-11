# Расширения MindNotes

Расширения — папки в `~/Library/Application Support/MindNotes/Extensions/` («Настройки» → «Расширения» → «Открыть папку расширений»). Код из расширений не исполняется: только описание и картинки (ADR-0015). После правки нажмите «Обновить список».

## Своя тема

```
Extensions/ocean/
  manifest.json
  theme.json
```

`manifest.json`:

```json
{ "id": "my.ocean", "name": "Океан", "version": "1.0", "kind": "theme", "minApp": "1.3.0" }
```

`theme.json` — все поля для светлого и тёмного режима, цвета `#RRGGBB`:

```json
{
  "light": { "paper": "#FFFFFF", "side": "#F1F6FA", "ink": "#1C2B36", "muted": "#5F7383", "line": "#DDE6EE",
             "accent": "#1F6FB2", "soft": "#E6EFF7", "card": "#FFFFFF", "primary": "#1F6FB2", "logo": "#1F6FB2", "danger": "#C0392B" },
  "dark":  { "paper": "#13202B", "side": "#0F1A23", "ink": "#E3EDF5", "muted": "#9AB0C0", "line": "#26394A",
             "accent": "#6FB3EA", "soft": "#1D3142", "card": "#182836", "primary": "#2B6EA3", "logo": "#2B6EA3", "danger": "#E8988F" }
}
```

Выбор: «Настройки» → «Своя тема».

## Иконка приложения

`manifest.json` с `"kind": "appIcon"` и `icon.png` 1024×1024 (до 5 МБ). Выбор: «Настройки» → «Иконка приложения».

## Дальше

Новые виды (шаблоны страниц, наборы значков, готовые фрагменты для меню «/») подключаются тем же реестром `ExtensionRegistry`. Незнакомый вид показывается как «не поддерживается этой версией» и ничего не ломает.
