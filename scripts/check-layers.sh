#!/bin/zsh
# Проверяет границы слоёв рабочего пространства. Модуль один, поэтому границы контролируются здесь:
# запрещённые импорты и символы ищутся grep, а ссылка на верхний слой даёт ошибку typecheck подмножества.
set -euo pipefail
cd "$(dirname "$0")/.."
S=Sources/Grizzly
fail=0

swiftfiles() { for d in "$@"; do [[ -d "$d" ]] && find "$d" -name '*.swift'; done; return 0; }

# forbid <шаблон> <описание> <каталоги...>: шаблон не должен встречаться в каталогах.
forbid() {
    local pattern=$1 what=$2; shift 2
    local files=("${(@f)$(swiftfiles "$@")}")
    [[ -z "${files[1]:-}" ]] && return 0
    if grep -nE "$pattern" "${files[@]}"; then
        echo "НАРУШЕНИЕ: $what"; fail=1
    fi
}

PURE=($S/Workspace/Domain $S/Workspace/Services $S/BlockEditor/Commands $S/Persistence $S/Backup)
forbid '^\s*import\s+(SwiftUI|AppKit|Combine)' 'UI-фреймворк в слое без UI' "${PURE[@]}"
forbid 'AppState\.shared|Preferences\.shared' 'обращение к файловому режиму' "${PURE[@]}" $S/BlockEditor/UI
forbid 'sqlite3_|import\s+SQLite3' 'SQLite вне Persistence' $S/Workspace $S/BlockEditor $S/Backup $S/Shell
forbid '^\s*import\s+CryptoKit' 'CryptoKit вне Backup' $S/Workspace $S/BlockEditor $S/Persistence

# subset <имя> <каталоги...>: подмножество обязано компилироваться само по себе.
subset() {
    local name=$1; shift
    local files=("${(@f)$(swiftfiles "$@")}")
    [[ -z "${files[1]:-}" ]] && return 0
    if ! swiftc -typecheck -parse-as-library -target "$(uname -m)-apple-macos13.0" "${files[@]}" 2>&1 | grep -E 'error:'; then
        echo "ok: $name"
    else
        echo "НАРУШЕНИЕ: подмножество $name не компилируется"; fail=1
    fi
}
subset Domain $S/Workspace/Domain
subset Domain+Commands $S/Workspace/Domain $S/BlockEditor/Commands
subset Domain+Persistence $S/Workspace/Domain $S/Persistence
subset Domain+Commands+Services $S/Workspace/Domain $S/BlockEditor/Commands $S/Workspace/Services
subset Domain+Backup $S/Workspace/Domain $S/Backup

exit $fail
