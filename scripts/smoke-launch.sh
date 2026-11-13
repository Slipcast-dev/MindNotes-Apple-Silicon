#!/bin/zsh
# Проверка запуска: изолированная копия собранного приложения должна прожить несколько секунд без падения.
# Ловит то, чего не видит компилятор на старой системе: недостающие символы при загрузке, падение при старте.
#   OUT=build ./scripts/smoke-launch.sh [секунды]
set -euo pipefail
cd "$(dirname "$0")/.."

WAIT=${1:-15}
BIN_PATTERN="MindNotes Test.app/Contents/MacOS/MindNotes"
trap './scripts/run-isolated.sh clean >/dev/null' EXIT

echo "Система: $(sw_vers -productVersion)"
./scripts/run-isolated.sh
sleep "$WAIT"
if pgrep -f "$BIN_PATTERN" >/dev/null; then
    echo "ok: приложение работает через $WAIT с"
else
    echo "НАРУШЕНИЕ: приложение завершилось в первые $WAIT с"
    REPORTS=("$HOME/Library/Logs/DiagnosticReports"/MindNotes*(N.om))
    (( ${#REPORTS} )) && head -60 "${REPORTS[1]}"
    exit 1
fi
