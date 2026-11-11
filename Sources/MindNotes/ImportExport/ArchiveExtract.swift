import Foundation

/// Распаковка .zip (экспорт Notion) во временную папку системными `zipinfo` и `ditto`.
/// Объём проверяется до распаковки, содержимое — после: символьные ссылки и пути наружу отклоняются.
enum ArchiveExtract {
    static let maxUncompressed: Int64 = 4 << 30

    /// Распаковывает в новую папку внутри `parent`. Вложенные архивы верхнего уровня (Notion делит экспорт на части)
    /// распаковываются туда же. При ошибке папка удаляется.
    static func extract(_ archive: URL, into parent: URL) throws -> URL {
        let fm = FileManager.default
        let target = parent.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            try unpack(archive, to: target)
            let nested = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "zip" }
            for inner in nested {
                try unpack(inner, to: target)
                try fm.removeItem(at: inner)
            }
            try verify(target)
            return target
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    private static func unpack(_ archive: URL, to target: URL) throws {
        let info = try run("/usr/bin/zipinfo", ["-t", archive.path])
        // Итоговая строка: «N files, X bytes uncompressed, Y bytes compressed: …».
        guard let range = info.range(of: #"([0-9]+) bytes uncompressed"#, options: .regularExpression),
              let bytes = Int64(info[range].split(separator: " ").first ?? "") else {
            throw ImportError.unsafeArchive(NSLocalizedString("не удалось прочитать оглавление", comment: ""))
        }
        guard bytes <= maxUncompressed else { throw ImportError.tooLarge(maxUncompressed) }
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, target.path])
    }

    /// Всё содержимое — обычные файлы и папки внутри `root`.
    static func verify(_ root: URL) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys)) else { return }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { throw ImportError.unsafeArchive(NSLocalizedString("в архиве есть символическая ссылка", comment: "")) }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw ImportError.unsafeArchive(NSLocalizedString("в архиве есть особый файл", comment: ""))
            }
            guard FolderImport.relativePath(url, base: base) != nil else {
                throw ImportError.unsafeArchive(NSLocalizedString("путь выходит за пределы папки", comment: ""))
            }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportError.unsafeArchive(String(format: NSLocalizedString("архив повреждён или не поддерживается (%d)", comment: ""), process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
