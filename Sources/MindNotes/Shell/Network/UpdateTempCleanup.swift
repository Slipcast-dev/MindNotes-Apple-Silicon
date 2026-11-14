import Foundation

/// Уборка временных файлов обновлений (правило — `UpdateTempFiles`). Удаляются только наши файлы во временной
/// папке приложения и только пустые папки монтирования: смонтированный образ или чужой файл не трогаются.
enum UpdateTempCleanup {
    /// Пустую папку — удалить; непустую (образ всё ещё смонтирован) — оставить.
    static func removeMountPoint(_ url: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: url.path), items.isEmpty else { return }
        try? fm.removeItem(at: url)
    }

    /// Остатки обновлений из прежних версий, в которых уборки не было. Вызывается при запуске.
    static func sweep(folder: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: []) else { return }
        for url in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            let age = now.timeIntervalSince(values.contentModificationDate ?? now)
            guard UpdateTempFiles.isLeftover(name: url.lastPathComponent, isDirectory: isDirectory, age: age) else { continue }
            if isDirectory { removeMountPoint(url) } else { try? fm.removeItem(at: url) }
        }
    }
}
