#!/bin/zsh
# Все автотесты: границы слоёв, приложение без UI и настоящий NSTextView, порт Electron (node --test).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check-layers.sh
./scripts/test-notes.sh
node --test tests/*.test.cjs
