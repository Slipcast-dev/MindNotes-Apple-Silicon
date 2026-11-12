#!/bin/zsh
# Выпуск плагина Web Clipper отдельно от приложения (ADR-0019): тег webclipper-v<версия>, образ установщика и суммы.
#   ./scripts/release-webclipper.sh            проверить, собрать, создать тег и выпуск на GitHub
#   DRY_RUN=1 ./scripts/release-webclipper.sh  всё, кроме тега и публикации
# Выпуск плагина не становится «последним» на GitHub: по releases/latest MindNotes ищет свои обновления (ADR-0014).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Plugins/WebClipper
REPO=Slipcast-dev/MindNotes-Apple-Silicon
version=$(/usr/bin/plutil -extract version raw -o - "$SRC/manifest.json")
prefix=$(/usr/bin/plutil -extract updates raw -o - "$SRC/manifest.json")
TAG="$prefix$version"
OUT_DIR="${OUT:-build}/webclipper-$version"
DMG="MindNotes-Web-Clipper-$version.dmg"
fail() { echo "Выпуск остановлен: $1"; exit 1; }

# 1. Готовность: чистое дерево, новая версия, запись в журнале.
[[ -z "$(git status --porcelain)" || -n "${DRY_RUN:-}" ]] || fail "есть незакоммиченные изменения"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "тег $TAG уже есть — поднимите version в $SRC/manifest.json"
[[ -z "${DRY_RUN:-}" ]] && git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fail "тег $TAG уже есть на GitHub"
grep -q "^## \[$version\]" "$SRC/CHANGELOG.md" || fail "в $SRC/CHANGELOG.md нет раздела ## [$version]"

# 2. Совместимость. Плагин подстраивается под возможности MindNotes (`features`), а не под её версию (ADR-0019, п. 9),
#    поэтому minApp необязателен: он нужен только при несовместимом изменении API. Если задан — такая MindNotes
#    уже должна быть выпущена, иначе плагин некуда поставить.
latestApp=$(gh api "repos/$REPO/releases/latest" --jq .tag_name | sed 's/^v//')
minApp=$(/usr/bin/plutil -extract minApp raw -o - "$SRC/manifest.json" 2>/dev/null) || minApp=""
if [[ -n "$minApp" && "$(printf '%s\n%s\n' "$minApp" "$latestApp" | sort -V | head -1)" != "$minApp" ]]; then
    message="плагину нужна MindNotes $minApp, а последняя выпущенная — $latestApp. Сначала выпустите приложение."
    [[ -n "${DRY_RUN:-}" ]] && echo "Предупреждение: $message" || fail "$message"
fi

# 3. Тесты и сборка.
./scripts/test.sh >/dev/null || fail "тесты не прошли (./scripts/test.sh)"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
OUT="$OUT_DIR" ./scripts/build-webclipper.sh >/dev/null
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$OUT_DIR/MindNotes Web Clipper.app" "$STAGE/MindNotes Web Clipper.app"
cat > "$STAGE/Как установить.txt" <<'TXT'
Откройте «MindNotes Web Clipper» — он сам перенесётся в «Программы», добавит плагин в MindNotes
и расширение в ваши браузеры. Нужна MindNotes с поддержкой плагинов.

Open “MindNotes Web Clipper”: it moves itself to Applications and adds the plugin to MindNotes
and the extension to your browsers. Requires a MindNotes version with plugin support.
TXT
hdiutil create -volname "MindNotes Web Clipper" -srcfolder "$STAGE" -ov -format UDZO "$OUT_DIR/$DMG" >/dev/null
# Описание плагина отдельным файлом: по нему MindNotes сравнивает разрешения до скачивания образа и решает,
# можно ли обновить без вопроса.
cp "$SRC/manifest.json" "$OUT_DIR/plugin-manifest.json"
(cd "$OUT_DIR" && shasum -a 256 "$DMG" plugin-manifest.json > SHA256SUMS.txt)
# Сборка не должна оставлять в системе второе расширение Safari.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$OUT_DIR/MindNotes Web Clipper.app" 2>/dev/null || true

notes="$OUT_DIR/notes.md"
awk -v v="$version" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^## \[/ {exit} on {print}' "$SRC/CHANGELOG.md" > "$notes"
if [[ -n "$minApp" ]]; then
    printf '\nТребуется MindNotes %s или новее.\n\n<!-- minApp: %s -->\n' "$minApp" "$minApp" >> "$notes"
fi

if [[ -n "${DRY_RUN:-}" ]]; then
    echo "Проверка пройдена, публикация пропущена (DRY_RUN): $OUT_DIR/$DMG"
    exit 0
fi

# 4. Тег и выпуск — не «последний», чтобы обновления приложения по-прежнему находили выпуск MindNotes.
git tag -a "$TAG" -m "Web Clipper $version"
git push origin "$TAG"
gh release create "$TAG" "$OUT_DIR/$DMG" "$OUT_DIR/plugin-manifest.json" "$OUT_DIR/SHA256SUMS.txt" --repo "$REPO" \
    --title "Web Clipper $version" --notes-file "$notes" --latest=false
[[ "$(gh api "repos/$REPO/releases/latest" --jq .tag_name)" == "v$latestApp" ]] \
    || echo "ВНИМАНИЕ: последним выпуском на GitHub стал не MindNotes — проверьте выпуски, иначе приложение не найдёт свои обновления."
echo "Выпущен $TAG"
