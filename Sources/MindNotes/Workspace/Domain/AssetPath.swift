import Foundation

/// Единая проверка путей вложений. Строка `assets.rel_path` приходит из SQLite, то есть из чужого
/// пространства или резервной копии, поэтому ей нельзя доверять при чтении, экспорте и удалении файлов.
enum AssetPath {
    /// Форма `assets/<2hex>/<uuid>[.ext]`: без абсолютных путей, `..`, лишних разделителей и пустых частей.
    static func isWellFormed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "assets", parts[1].count == 2,
              parts[1].allSatisfy({ $0.isHexDigit }) else { return false }
        let file = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(file.count), UUID(uuidString: String(file[0])) != nil else { return false }
        if file.count == 2 { return !file[1].isEmpty && file[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        return true
    }

    /// Путь допустим для записи `id`: правильная форма и имя файла совпадает с идентификатором вложения.
    static func isValid(_ path: String, for id: UUID) -> Bool {
        guard isWellFormed(path) else { return false }
        let name = path.split(separator: "/")[2].split(separator: ".", omittingEmptySubsequences: false)[0]
        return UUID(uuidString: String(name)) == id
    }

    /// Файл вложения внутри пространства `root`. Бросает ошибку до любой файловой операции, если путь недопустим
    /// или папка `assets`, подкаталог либо сам файл оказались символической ссылкой или особым файлом.
    /// Отсутствующий файл допустим: проверяется имя, а не существование.
    static func resolve(_ path: String, id: UUID, in root: URL) throws -> URL {
        guard isValid(path, for: id) else { throw WorkspaceError.corrupted("недопустимый путь вложения: \(path)") }
        let parts = path.split(separator: "/").map(String.init)
        let assets = root.appendingPathComponent(parts[0], isDirectory: true)
        let dir = assets.appendingPathComponent(parts[1], isDirectory: true)
        let file = dir.appendingPathComponent(parts[2], isDirectory: false)
        let fm = FileManager.default
        // attributesOfItem не следует за последней ссылкой (lstat), поэтому ссылка видна как ссылка.
        for (url, expected) in [(assets, FileAttributeType.typeDirectory), (dir, .typeDirectory), (file, .typeRegular)] {
            guard let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { break }
            guard type == expected else { throw WorkspaceError.corrupted("недопустимый путь вложения: \(path)") }
        }
        return file
    }
}
