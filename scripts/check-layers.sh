#!/bin/zsh
# Проверяет границы слоёв рабочего пространства. Модуль один, поэтому границы контролируются здесь:
# запрещённые импорты и символы ищутся grep, а ссылка на верхний слой даёт ошибку typecheck подмножества.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/target.sh
S=Sources/MindNotes
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

PURE=($S/Workspace/Domain $S/Workspace/Services $S/BlockEditor/Commands $S/Persistence $S/Backup $S/ImportExport)
# Редактор пользуется AppKit, но не SwiftUI и не оболочкой.
forbid '^\s*import\s+SwiftUI' 'SwiftUI в нативном редакторе' $S/BlockEditor/UI/Native
forbid '^\s*import\s+(SwiftUI|AppKit|Combine)' 'UI-фреймворк в слое без UI' "${PURE[@]}"
forbid 'sqlite3_|import\s+SQLite3' 'SQLite вне Persistence' $S/Workspace $S/BlockEditor $S/Backup $S/Shell
forbid '^\s*import\s+CryptoKit' 'CryptoKit вне Backup' $S/Workspace $S/BlockEditor
# Формулы: только собственный интерпретатор, никакого исполнения кода по строке (FR-13).
forbid 'NSExpression|JSContext|JavaScriptCore|NSSelectorFromString|perform\(|dlopen|dlsym|Process\(|FileManager|URLSession|Data\(contentsOf' 'исполнение кода или доступ к файлам и сети в формулах' $S/Workspace/Domain/Formula

# subset <имя> <каталоги...>: подмножество обязано компилироваться само по себе.
subset() {
    local name=$1; shift
    local files=("${(@f)$(swiftfiles "$@")}")
    [[ -z "${files[1]:-}" ]] && return 0
    # Успех определяет код возврата swiftc, а не поиск строки в выводе: при pipefail «! swiftc | grep»
    # печатал ok и при ошибке компиляции.
    local out
    if out=$(swiftc -typecheck -parse-as-library -target "$TARGET" "${files[@]}" 2>&1); then
        echo "ok: $name"
    else
        print -r -- "$out" | grep -E 'error:' || print -r -- "$out"
        echo "НАРУШЕНИЕ: подмножество $name не компилируется"; fail=1
    fi
}
subset Domain $S/Workspace/Domain
subset Domain+Commands $S/Workspace/Domain $S/BlockEditor/Commands
subset Domain+Persistence $S/Workspace/Domain $S/Persistence
subset Domain+Commands+Services $S/Workspace/Domain $S/BlockEditor/Commands $S/Workspace/Services
subset Domain+Backup $S/Workspace/Domain $S/Backup
subset Domain+Commands+Import $S/Workspace/Domain $S/BlockEditor/Commands $S/ImportExport
subset Domain+Commands+Services+Editor $S/Workspace/Domain $S/BlockEditor/Commands $S/Workspace/Services $S/BlockEditor/UI/Native

exit $fail
