import Foundation

/// Какие данные приложения относятся к запущенной сборке.
/// Настройки macOS и так разделяет по идентификатору, а имена каталогов и доменов заданы в коде:
/// без этого проверочная копия с другим идентификатором писала бы в данные настоящего приложения.
enum AppDataScope {
    /// Настоящие данные принадлежат только сборке с официальным идентификатором.
    /// Отсутствие идентификатора (бинарник вне пакета) тоже считается проверочным запуском.
    static func isOfficial(bundleID: String?, officialID: String) -> Bool {
        bundleID == officialID
    }

    /// Имя каталога в Application Support: у каждой проверочной копии свой.
    static func supportDirectoryName(bundleID: String?, officialID: String, officialName: String) -> String {
        if isOfficial(bundleID: bundleID, officialID: officialID) { return officialName }
        // Идентификатор становится именем каталога: разделители пути в нём недопустимы.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let safe = String(String.UnicodeScalarView((bundleID ?? "no-bundle").unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return "\(officialName)-Test-\(safe)"
    }
}
