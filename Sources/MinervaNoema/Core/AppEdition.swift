import Foundation

/// Имя и данные приложения. Совпадает с `scripts/build-app.sh`; это проверяет `tests/edition.test.cjs`.
enum AppEdition {
    static let bundleID = "local.personal.MinervaNoema"
    static let displayName = "Minerva Noema"
    /// Каталог в Application Support. Данные исходного Grizzly не читаются и не меняются.
    static let supportDirectoryName = "MinervaNoema"

    /// Копирует настройки и каталог с прежнего имени Grizzly Notes. Вызывать до первого чтения настроек.
    static func migrateFromPreviousName() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        LegacyDataMigration.run(defaults: .standard, oldDomain: "local.personal.GrizzlyNotes", newDomain: bundleID,
                                oldSupport: support.appendingPathComponent("GrizzlyNotes", isDirectory: true),
                                newSupport: support.appendingPathComponent(supportDirectoryName, isDirectory: true))
    }
}
