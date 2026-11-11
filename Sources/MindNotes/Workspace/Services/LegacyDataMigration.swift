import Foundation

/// Однократный перенос настроек и каталога приложения при смене имени. Оригиналы остаются: это копия, а не перемещение.
enum LegacyDataMigration {
    static let marker = "migratedFromGrizzlyNotes"

    /// Настройки нового имени важнее старых, существующий новый каталог не перезаписывается.
    /// После сбоя отметка не ставится, и следующий запуск повторит копирование.
    @discardableResult
    /// `marker` — своя отметка у каждого прежнего имени: переносы с разных имён не мешают друг другу.
    static func run(defaults: UserDefaults, oldDomain: String, newDomain: String, oldSupport: URL, newSupport: URL,
                    marker: String = LegacyDataMigration.marker, fileManager fm: FileManager = .default) -> Bool {
        guard !defaults.bool(forKey: marker) else { return true }
        if let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty {
            let current = defaults.persistentDomain(forName: newDomain) ?? [:]
            // Отметки прежних переносов не копируются: у нового имени свои.
            let carried = old.filter { !$0.key.hasPrefix("migratedFrom") }
            defaults.setPersistentDomain(carried.merging(current) { _, new in new }, forName: newDomain)
        }
        if fm.fileExists(atPath: oldSupport.path), !fm.fileExists(atPath: newSupport.path) {
            // Сначала рядом и затем переименование: обрывок копии не примется за готовый каталог.
            let partial = newSupport.deletingLastPathComponent().appendingPathComponent(newSupport.lastPathComponent + ".partial", isDirectory: true)
            do {
                try? fm.removeItem(at: partial)
                try fm.createDirectory(at: newSupport.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: oldSupport, to: partial)
                try fm.moveItem(at: partial, to: newSupport)
            } catch {
                try? fm.removeItem(at: partial)
                return false
            }
        }
        defaults.set(true, forKey: marker)
        return true
    }
}
