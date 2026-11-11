import Foundation

/// Имя и данные приложения. Совпадает с `scripts/build-app.sh`; это проверяет `tests/edition.test.cjs`.
enum AppEdition {
    static let bundleID = "local.personal.MindNotes"
    static let displayName = "MindNotes"
    /// Версия Grizzly, на которой основан проект: для уведомления об авторстве, не версия этой сборки.
    static let baseGrizzlyVersion = "1.4.2"
    /// Каталог настоящей сборки в Application Support. Данные исходного Grizzly не читаются и не меняются.
    static let officialSupportDirectoryName = "MindNotes"
    /// Каталог запущенной сборки: у копии с другим идентификатором он свой (`AppDataScope`).
    static var supportDirectoryName: String {
        AppDataScope.supportDirectoryName(bundleID: Bundle.main.bundleIdentifier, officialID: bundleID, officialName: officialSupportDirectoryName)
    }

    /// Прежние имена по порядку: сначала Minerva Noema (ADR-0007), затем Grizzly Notes — для того, кто обновляется прямо с него.
    static let previousNames: [(domain: String, directory: String, marker: String)] = [
        ("local.personal.MinervaNoema", "MinervaNoema", "migratedFromMinervaNoema"),
        ("local.personal.GrizzlyNotes", "GrizzlyNotes", LegacyDataMigration.marker),
    ]

    /// Копирует настройки и каталог с прежних имён. Вызывать до первого чтения настроек.
    /// Проверочная копия пропускает перенос: он пишет в настоящий домен настроек и каталог.
    static func migrateFromPreviousName() {
        guard AppDataScope.isOfficial(bundleID: Bundle.main.bundleIdentifier, officialID: bundleID) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Только с самого нового прежнего имени, от которого что-то осталось: иначе более старые настройки
        // вернули бы ключи, которые пользователь уже удалил.
        let fm = FileManager.default
        guard let old = previousNames.first(where: { old in
            !(UserDefaults.standard.persistentDomain(forName: old.domain) ?? [:]).isEmpty
                || fm.fileExists(atPath: support.appendingPathComponent(old.directory, isDirectory: true).path)
        }) else { return }
        LegacyDataMigration.run(defaults: .standard, oldDomain: old.domain, newDomain: bundleID,
                                oldSupport: support.appendingPathComponent(old.directory, isDirectory: true),
                                newSupport: support.appendingPathComponent(supportDirectoryName, isDirectory: true),
                                marker: old.marker)
    }
}
