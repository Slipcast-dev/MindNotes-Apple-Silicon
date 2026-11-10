import Foundation

/// Имя и данные приложения. Совпадает с `scripts/build-app.sh`; это проверяет `tests/edition.test.cjs`.
enum AppEdition {
    static let bundleID = "local.personal.MinervaNoema"
    static let displayName = "Minerva Noema"
    /// Версия Grizzly, на которой основан проект: для уведомления об авторстве, не версия этой сборки.
    static let baseGrizzlyVersion = "1.4.2"
    /// Каталог настоящей сборки в Application Support. Данные исходного Grizzly не читаются и не меняются.
    static let officialSupportDirectoryName = "MinervaNoema"
    /// Каталог запущенной сборки: у копии с другим идентификатором он свой (`AppDataScope`).
    static var supportDirectoryName: String {
        AppDataScope.supportDirectoryName(bundleID: Bundle.main.bundleIdentifier, officialID: bundleID, officialName: officialSupportDirectoryName)
    }

    /// Копирует настройки и каталог с прежнего имени Grizzly Notes. Вызывать до первого чтения настроек.
    /// Проверочная копия пропускает перенос: он пишет в настоящий домен настроек и каталог.
    static func migrateFromPreviousName() {
        guard AppDataScope.isOfficial(bundleID: Bundle.main.bundleIdentifier, officialID: bundleID) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        LegacyDataMigration.run(defaults: .standard, oldDomain: "local.personal.GrizzlyNotes", newDomain: bundleID,
                                oldSupport: support.appendingPathComponent("GrizzlyNotes", isDirectory: true),
                                newSupport: support.appendingPathComponent(supportDirectoryName, isDirectory: true))
    }
}
