#!/bin/zsh
# Тесты слоёв рабочего пространства без UI. Сборка -Onone, чтобы прогон занимал секунды, а не минуты.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/target.sh
S=Sources/MindNotes
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
FILES=("${(@f)$(for d in $S/Workspace $S/Persistence $S/BlockEditor/Commands $S/BlockEditor/UI/Native $S/Backup $S/ImportExport tests/swift-notes; do [[ -d $d ]] && find $d -name '*.swift'; done)}")
swiftc "${NOTES_OPT:--Onone}" -target "$TARGET" -o "$OUT/notes-tests" "${FILES[@]}" 2>&1 | grep -E 'error|warning: unre' || true
[[ -x "$OUT/notes-tests" ]] || { echo "Тесты не скомпилировались"; exit 1; }
"$OUT/notes-tests" "$@"
