#!/bin/zsh
# Запускает копию собранного приложения с тестовым идентификатором: свои настройки и свой каталог данных,
# настоящие данные не затрагиваются (AppDataScope). Пространство выбирайте только во временной папке.
#   OUT=build ./scripts/run-isolated.sh        запустить копию из $OUT
#   ./scripts/run-isolated.sh clean            завершить копию и удалить всё, что она создала
set -euo pipefail
cd "$(dirname "$0")/.."

ID=local.personal.MinervaNoema.test
ROOT="${${TMPDIR:-/tmp}%/}/minerva-isolated"
COPY="$ROOT/Minerva Noema Test.app"
BIN="$COPY/Contents/MacOS/MinervaNoema"

stop_copy() { pkill -f "$BIN" 2>/dev/null || true; }

if [[ "${1:-}" == clean ]]; then
    stop_copy
    sleep 1
    defaults delete "$ID" 2>/dev/null || true
    # defaults delete оставляет пустой файл настроек.
    rm -rf "$ROOT" \
        "$HOME/Library/Preferences/$ID.plist" \
        "$HOME/Library/Application Support/MinervaNoema-Test-$ID" \
        "$HOME/Library/Saved Application State/$ID.savedState" \
        "$HOME/Library/Caches/$ID"
    echo "Удалено: копия, её настройки и каталог данных"
    exit 0
fi

SOURCE="${OUT:-build}/Minerva Noema.app"
[[ -d "$SOURCE" ]] || { echo "Нет сборки $SOURCE: сначала ./scripts/build-app.sh"; exit 1; }

stop_copy
mkdir -p "$ROOT"
rm -rf "$COPY"
cp -R "$SOURCE" "$COPY"
PLIST="$COPY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Minerva Noema Test" "$PLIST"
# Копия не должна предлагаться системой для открытия файлов.
/usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes" "$PLIST"
codesign --force --sign - "$COPY" >/dev/null

open "$COPY"
echo "Запущена копия: $COPY"
echo "Идентификатор: $ID"
echo "Убрать всё: ./scripts/run-isolated.sh clean"
