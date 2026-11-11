#!/bin/zsh
# Демо-пространство с вымышленными данными и его проверенный архив: build/demo/.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/target.sh
S=Sources/MindNotes
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
FILES=("${(@f)$(for d in $S/Workspace $S/Persistence $S/BlockEditor/Commands $S/BlockEditor/UI/Native $S/Backup $S/ImportExport tests/swift-notes; do find $d -name '*.swift'; done)}")
swiftc -Onone -target "$TARGET" -o "$OUT/seed" "${FILES[@]}" 2>&1 | grep -E 'error' || true
[[ -x "$OUT/seed" ]] || { echo "Генератор не скомпилировался"; exit 1; }
mkdir -p build/demo
DEMO="build/demo/Демо-пространство"
ARCHIVE="build/demo/Демо-пространство.mindnotesbackup"
[[ -e "$DEMO" || -e "$ARCHIVE" ]] && { echo "Уже есть $DEMO или архив: удалите их сами, если нужно пересоздать"; exit 1; }
"$OUT/seed" --demo-archive "$DEMO" "$ARCHIVE"
shasum -a 256 "$ARCHIVE"
