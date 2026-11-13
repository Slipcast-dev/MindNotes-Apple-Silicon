import Foundation

/// Распаковка .zip (экспорт Notion) во временную папку системным `ditto`.
/// До распаковки собственным разбором центрального каталога ZIP проверяются объём, число и типы записей:
/// символьные ссылки и особые файлы отклоняются. Каждая часть распаковывается в отдельную новую папку,
/// проверяется сразу и только потом переносится в общую: следующая часть не может пройти через ссылку,
/// созданную предыдущей.
enum ArchiveExtract {
    static let maxUncompressed: Int64 = 4 << 30
    /// Общий предел числа записей во всех частях.
    static let maxEntries = 100_000

    /// Распаковывает в новую папку внутри `parent`. Вложенные архивы верхнего уровня (Notion делит экспорт на части)
    /// распаковываются туда же. При ошибке папка удаляется. `maxBytes` — общий предел объёма всех частей.
    static func extract(_ archive: URL, into parent: URL, maxBytes: Int64 = maxUncompressed) throws -> URL {
        let fm = FileManager.default
        let target = parent.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            var budget = Budget(limit: maxBytes)
            try unpack(archive, into: target, budget: &budget)
            let nested = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "zip" }
                // Части по номеру (Part-2 раньше Part-10): при совпадающих путях итог не зависит от порядка каталога.
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for inner in nested {
                // Сама часть уже учтена в объёме внешнего архива; считается её содержимое, а не она дважды.
                budget.bytes -= min(budget.bytes, ((try? fm.attributesOfItem(atPath: inner.path))?[.size] as? NSNumber)?.int64Value ?? 0)
                try unpack(inner, into: target, budget: &budget)
                try fm.removeItem(at: inner)
            }
            try verify(target)
            return target
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// Остаток общего предела на все части архива.
    private struct Budget {
        let limit: Int64
        var bytes: Int64 = 0
        var entries = 0

        mutating func charge(bytes more: Int64, entries count: Int) throws {
            let (sum, overflow) = bytes.addingReportingOverflow(more)
            guard !overflow, sum <= limit else { throw ImportError.tooLarge(limit) }
            guard entries + count <= ArchiveExtract.maxEntries else { throw ImportError.tooManyFiles(ArchiveExtract.maxEntries) }
            bytes = sum
            entries += count
        }
    }

    /// Одна часть: оглавление → распаковка в новую пустую папку → проверка → перенос обычных файлов в `target`.
    private static func unpack(_ archive: URL, into target: URL, budget: inout Budget) throws {
        let fm = FileManager.default
        // Сама часть должна быть обычным файлом, а не ссылкой (проверяется без перехода по ссылке).
        let type = (try? fm.attributesOfItem(atPath: archive.path))?[.type] as? FileAttributeType
        guard type == .typeRegular else { throw ImportError.unsafeArchive(NSLocalizedString("в архиве есть символическая ссылка", comment: "")) }
        let toc = try ZipDirectory.read(archive, maxBytes: budget.limit)
        try budget.charge(bytes: toc.uncompressed, entries: toc.entries)

        let staging = target.deletingLastPathComponent().appendingPathComponent(".part-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        try verify(staging)
        try merge(staging, into: target)
    }

    /// Переносит проверенное содержимое `from` в `into`. Папки сливаются, одинаковый файл заменяется
    /// (как при прежней распаковке частей в одну папку); файл на месте папки и наоборот — ошибка.
    private static func merge(_ from: URL, into: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey]) {
            let destination = into.appendingPathComponent(item.lastPathComponent)
            let isDir = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let existing = (try? fm.attributesOfItem(atPath: destination.path))?[.type] as? FileAttributeType
            switch (isDir, existing) {
            case (_, nil):
                try fm.moveItem(at: item, to: destination)
            case (true, .typeDirectory?):
                try merge(item, into: destination)
            case (false, .typeRegular?):
                try fm.removeItem(at: destination)
                try fm.moveItem(at: item, to: destination)
            default:
                throw ImportError.unsafeArchive(NSLocalizedString("в частях архива файл и папка с одним именем", comment: ""))
            }
        }
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

/// Центральный каталог ZIP, прочитанный без внешних утилит: имена с переводами строк не разбираются построчно.
enum ZipDirectory {
    struct Summary: Equatable {
        var entries: Int
        var uncompressed: Int64
    }

    private static func damaged() -> ImportError { ImportError.unsafeArchive(NSLocalizedString("не удалось прочитать оглавление", comment: "")) }

    /// Читает оглавление и отклоняет записи-ссылки и особые файлы. Тип берётся из режима Unix (старшие 16 бит
    /// внешних атрибутов), если архив создан в Unix/macOS; в остальных системах ссылок в ZIP нет.
    static func read(_ url: URL, maxBytes: Int64 = ArchiveExtract.maxUncompressed) throws -> Summary {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw damaged() }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw damaged() }
        let tailLength = min(size, 22 + 65_535)
        try handle.seek(toOffset: size - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count == Int(tailLength) else { throw damaged() }
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { u32(tail, $0) == 0x0605_4b50 }) else { throw damaged() }

        var count = UInt64(u16(tail, eocd + 10))
        var cdSize = UInt64(u32(tail, eocd + 12))
        var cdOffset = UInt64(u32(tail, eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: локатор стоит прямо перед обычной концевой записью.
            let locator = eocd - 20
            guard locator >= 0, u32(tail, locator) == 0x0706_4b50 else { throw damaged() }
            let offset = u64(tail, locator + 8)
            guard offset < size else { throw damaged() }
            try handle.seek(toOffset: offset)
            let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard record.count == 56, u32(record, 0) == 0x0606_4b50 else { throw damaged() }
            count = u64(record, 32)
            cdSize = u64(record, 40)
            cdOffset = u64(record, 48)
        }
        guard count <= UInt64(ArchiveExtract.maxEntries) else { throw ImportError.tooManyFiles(ArchiveExtract.maxEntries) }
        guard cdOffset <= size, cdSize <= size - cdOffset, cdSize <= 256 << 20 else { throw damaged() }
        try handle.seek(toOffset: cdOffset)
        let cd = [UInt8](try handle.read(upToCount: Int(cdSize)) ?? Data())
        guard cd.count == Int(cdSize) else { throw damaged() }

        var position = 0
        var total: Int64 = 0
        for _ in 0..<count {
            guard position + 46 <= cd.count, u32(cd, position) == 0x0201_4b50 else { throw damaged() }
            let host = cd[position + 5]
            var uncompressed = UInt64(u32(cd, position + 24))
            let nameLength = Int(u16(cd, position + 28)), extraLength = Int(u16(cd, position + 30)), commentLength = Int(u16(cd, position + 32))
            let external = u32(cd, position + 38)
            let next = position + 46 + nameLength + extraLength + commentLength
            guard next <= cd.count else { throw damaged() }
            if uncompressed == 0xFFFF_FFFF {
                // Поле расширения ZIP64 (0x0001): первым идёт настоящий размер без сжатия.
                var e = position + 46 + nameLength
                let end = e + extraLength
                var found = false
                while e + 4 <= end {
                    let id = u16(cd, e), length = Int(u16(cd, e + 2))
                    guard e + 4 + length <= end else { break }
                    if id == 0x0001, length >= 8 { uncompressed = u64(cd, e + 4); found = true; break }
                    e += 4 + length
                }
                guard found else { throw damaged() }
            }
            if host == 3 || host == 19 {
                let kind = (external >> 16) & 0o170000
                if kind == 0o120000 { throw ImportError.unsafeArchive(NSLocalizedString("в архиве есть символическая ссылка", comment: "")) }
                guard kind == 0 || kind == 0o100000 || kind == 0o040000 else {
                    throw ImportError.unsafeArchive(NSLocalizedString("в архиве есть особый файл", comment: ""))
                }
            }
            guard uncompressed <= UInt64(Int64.max) else { throw ImportError.tooLarge(maxBytes) }
            let (sum, overflow) = total.addingReportingOverflow(Int64(uncompressed))
            guard !overflow, sum <= maxBytes else { throw ImportError.tooLarge(maxBytes) }
            total = sum
            position = next
        }
        return Summary(entries: Int(count), uncompressed: total)
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * UInt32($1)) } }
    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) } }
}
