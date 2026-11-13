#!/bin/zsh
# Выпуск плагина Web Clipper отдельно от приложения (ADR-0019): тег webclipper-v<версия>, образ установщика и суммы.
#   ./scripts/release-webclipper.sh            проверить, собрать, создать тег и выпуск на GitHub
#   DRY_RUN=1 ./scripts/release-webclipper.sh  всё, кроме тега и публикации
#   MIRROR_TO_APP_REPO=1 …                      переходный период переезда: ещё и копия выпуска в репозитории приложения
# Куда публиковать — поле `repository` в manifest.json плагина (ADR-0019, п. 10); без него — репозиторий приложения.
# В репозитории приложения выпуск плагина не становится «последним»: по releases/latest MindNotes ищет свои обновления.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Plugins/WebClipper
APP_REPO=Slipcast-dev/MindNotes-Apple-Silicon
PLUGIN_REPO=$(/usr/bin/plutil -extract repository raw -o - "$SRC/manifest.json" 2>/dev/null) || PLUGIN_REPO=$APP_REPO
version=$(/usr/bin/plutil -extract version raw -o - "$SRC/manifest.json")
prefix=$(/usr/bin/plutil -extract updates raw -o - "$SRC/manifest.json")
TAG="$prefix$version"
OUT_DIR="${OUT:-build}/webclipper-$version"
DMG="MindNotes-Web-Clipper-$version.dmg"
fail() { echo "Выпуск остановлен: $1"; exit 1; }

# Те же правила имени, что в MindNotes (PluginManifest.isValidRepository).
[[ "$PLUGIN_REPO" =~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$' && "${PLUGIN_REPO#*/}" != "." && "${PLUGIN_REPO#*/}" != ".." ]] \
    || fail "repository в $SRC/manifest.json — нужно «владелец/имя» на GitHub"
TARGETS=("$PLUGIN_REPO")
if [[ "$PLUGIN_REPO" != "$APP_REPO" && -n "${MIRROR_TO_APP_REPO:-}" ]]; then
    TARGETS+=("$APP_REPO") # пока не все MindNotes умеют поле repository, выпуск дублируется в репозиторий приложения
fi

# 1. Готовность: чистое дерево, новая версия, запись в журнале.
[[ -z "$(git status --porcelain)" || -n "${DRY_RUN:-}" ]] || fail "есть незакоммиченные изменения"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "тег $TAG уже есть — поднимите version в $SRC/manifest.json"
for repo in "${TARGETS[@]}"; do
    gh release view "$TAG" --repo "$repo" >/dev/null 2>&1 && fail "выпуск $TAG уже есть в $repo"
done
grep -q "^## \[$version\]" "$SRC/CHANGELOG.md" || fail "в $SRC/CHANGELOG.md нет раздела ## [$version]"

# 2. Совместимость. Плагин подстраивается под возможности MindNotes (`features`), а не под её версию (ADR-0019, п. 9),
#    поэтому minApp необязателен: он нужен только при несовместимом изменении API. Если задан — такая MindNotes
#    уже должна быть выпущена, иначе плагин некуда поставить.
latestApp=$(gh api "repos/$APP_REPO/releases/latest" --jq .tag_name | sed 's/^v//')
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
# Сборка не должна оставлять в системе второе расширение Safari: регистрация снимается, а сама программа
# удаляется — в выпуске нужен только образ, иначе macOS со временем снова находит её в папке сборки.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$OUT_DIR/MindNotes Web Clipper.app" 2>/dev/null || true
rm -rf "$OUT_DIR/MindNotes Web Clipper.app"

notes="$OUT_DIR/notes.md"
awk -v v="$version" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^## \[/ {exit} on {print}' "$SRC/CHANGELOG.md" > "$notes"
if [[ -n "$minApp" ]]; then
    printf '\nТребуется MindNotes %s или новее.\n\n<!-- minApp: %s -->\n' "$minApp" "$minApp" >> "$notes"
fi

if [[ -n "${DRY_RUN:-}" ]]; then
    echo "Проверка пройдена, публикация пропущена (DRY_RUN): $OUT_DIR/$DMG → ${TARGETS[*]}"
    exit 0
fi

# 4. Тег и выпуск. В репозитории приложения тег ставится отсюда и выпуск не «последний»; в своём репозитории
#    плагина GitHub ставит тег на основную ветку, и выпуск может быть «последним» — там это ничему не мешает.
for repo in "${TARGETS[@]}"; do
    if [[ "$repo" == "$APP_REPO" ]]; then
        git tag -a "$TAG" -m "Web Clipper $version"
        git push origin "$TAG"
        latest=(--latest=false)
    else
        latest=()
    fi
    gh release create "$TAG" "$OUT_DIR/$DMG" "$OUT_DIR/plugin-manifest.json" "$OUT_DIR/SHA256SUMS.txt" --repo "$repo" \
        --title "Web Clipper $version" --notes-file "$notes" "${latest[@]}"
    echo "Выпущен $TAG в $repo"
done
if (( ${TARGETS[(Ie)$APP_REPO]} )); then
    [[ "$(gh api "repos/$APP_REPO/releases/latest" --jq .tag_name)" == "v$latestApp" ]] \
        || echo "ВНИМАНИЕ: последним выпуском на GitHub стал не MindNotes — проверьте выпуски, иначе приложение не найдёт свои обновления."
fi
