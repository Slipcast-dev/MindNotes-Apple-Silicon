import Foundation

/// Отличия личной сборки Grizzly Notes от официального Grizzly.
///
/// Единая точка, чтобы приложения могли стоять рядом: разные идентификатор, данные и настройки.
/// Идентификатор должен совпадать с `scripts/build-app.sh`; это проверяет `tests/edition.test.cjs`.
enum AppEdition {
    static let bundleID = "local.personal.GrizzlyNotes"
    static let displayName = "Grizzly Notes"
    /// Каталог в Application Support. Каталог официального Grizzly («Grizzly») не читается и не меняется.
    static let supportDirectoryName = "GrizzlyNotes"
    /// Личная сборка не должна заменяться официальным релизом (FR-17): проверка и установка выключены.
    static let updatesEnabled = false
    /// Перенос каталога старого MD Reader забрал бы данные оригинальной установки.
    static let migratesLegacyLibrary = false
}
