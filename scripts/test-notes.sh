#!/bin/zsh
# Тесты слоёв рабочего пространства без UI. Сборка -Onone, чтобы прогон занимал секунды, а не минуты.
# CI собирает на новой системе, а запускает на старой (ADR-0020):
#   NOTES_BUILD_ONLY=<каталог> ./scripts/test-notes.sh   только собрать <каталог>/notes-tests
#   NOTES_BIN=<файл> ./scripts/test-notes.sh             только запустить готовый бинарник
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/target.sh
if [[ -n "${NOTES_BIN:-}" ]]; then
    [[ -x "$NOTES_BIN" ]] || { echo "Нет бинарника тестов $NOTES_BIN"; exit 1; }
    "$NOTES_BIN" "$@"
    exit
fi
S=Sources/MindNotes
OUT=${NOTES_BUILD_ONLY:-$(mktemp -d)}
[[ -n "${NOTES_BUILD_ONLY:-}" ]] && mkdir -p "$OUT" || trap 'rm -rf "$OUT"' EXIT
FILES=("${(@f)$(for d in $S/Workspace $S/Persistence $S/BlockEditor/Commands $S/BlockEditor/UI/Native $S/Backup $S/ImportExport tests/swift-notes; do [[ -d $d ]] && find $d -name '*.swift'; done)}")
# Каталог шаблонов описан в оболочке (подписи через L), но устанавливается хранилищем: тесты проверяют каждый шаблон.
FILES+=($S/Core/Localization.swift $S/Shell/Screens/TemplateCatalog.swift)
swiftc "${NOTES_OPT:--Onone}" -target "$TARGET" -o "$OUT/notes-tests" "${FILES[@]}" 2>&1 | grep -E 'error|warning: unre' || true
[[ -x "$OUT/notes-tests" ]] || { echo "Тесты не скомпилировались"; exit 1; }
[[ -n "${NOTES_BUILD_ONLY:-}" ]] && { echo "Собрано: $OUT/notes-tests"; exit 0; }
"$OUT/notes-tests" "$@"
