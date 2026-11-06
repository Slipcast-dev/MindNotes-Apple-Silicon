import Foundation

/// Имя и данные приложения. Совпадает с `scripts/build-app.sh`; это проверяет `tests/edition.test.cjs`.
enum AppEdition {
    static let bundleID = "local.personal.GrizzlyNotes"
    static let displayName = "Grizzly Notes"
    /// Каталог в Application Support. Данные исходного Grizzly не читаются и не меняются.
    static let supportDirectoryName = "GrizzlyNotes"
}
