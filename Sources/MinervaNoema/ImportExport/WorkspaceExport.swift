import Foundation

/// Переносимый экспорт (FR-15): Markdown, CSV и вложения. Это не резервная копия: история, представления
/// и часть оформления в него не входят, а потери перечисляются в итоге.
enum WorkspaceExport {
    struct Summary: Equatable {
        var pages = 0
        var databases = 0
        var records = 0
        var assets = 0
        var missingAssets = 0
        /// Причина потери и число случаев по всему экспорту.
        var losses: [String: Int] = [:]
    }

    static let pageSize = 500

    /// Таблица базы: первая строка — названия свойств. Значения в том же виде, в каком их принимает импорт.
    /// `each` получает каждую запись: экспорт папки берёт из неё карточки, не читая записи второй раз.
    static func databaseRows(source: ExportSource, database: Database, titles: [UUID: String] = [:], each: (RecordRow) -> Void = { _ in }) async throws -> [[String]] {
        var rows = [database.properties.map(\.name)]
        var offset = 0
        while true {
            let page = try await source.queryRecords(database: database, state: DatabaseViewState(), limit: pageSize, offset: offset)
            for record in page.rows {
                each(record)
                rows.append(database.properties.map { property in
                    if property.type == .title { return titles[record.id] ?? record.title }
                    return record.values[property.id].map { PropertyConversion.text(of: $0, options: property.options) } ?? ""
                })
            }
            offset += page.rows.count
            if page.rows.isEmpty || offset >= page.total { break }
        }
        return rows
    }

    /// Пишет всё пространство в новую папку `root`. Существующая папка не принимается: чужие файлы не перезаписываются.
    static func exportAll(source: ExportSource, to root: URL, untitled: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Summary {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let pages = try await source.allPages()
        let index = try await source.databaseIndex()
        let live = Set(pages.map(\.id))
        let liveDatabases = Set(index.filter { live.contains($0.key) }.values)
        let tree = PageTree(pages: pages) { $0.databaseID.map(liveDatabases.contains) ?? false }
        let recordsByDatabase = Dictionary(grouping: pages.filter { $0.databaseID.map(liveDatabases.contains) ?? false }) { $0.databaseID! }
        var summary = Summary()
        var done = 0

        func writeMarkdown(_ page: Page, name: String, in dir: URL, used: inout Set<String>, card: [String] = []) async throws -> Bool {
            let blocks = BlockDocument(pageID: page.id, blocks: try await source.blocks(ofPage: page.id)).blocks
            let hasContent = blocks.contains { !$0.plainText.isEmpty || $0.type.isAtom }
            guard hasContent || !page.isFolder else { return false }
            let folder = unique(name + "_files", in: &used)
            let result = MarkdownExport.export(title: page.title.isEmpty ? untitled : page.title, card: card, blocks: blocks, assetFolder: folder) { tree.page($0)?.title }
            for asset in result.assets {
                guard let from = try await source.assetURL(asset.id), fm.fileExists(atPath: from.path) else { summary.missingAssets += 1; continue }
                try fm.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
                try fm.copyItem(at: from, to: dir.appendingPathComponent(asset.path))
                summary.assets += 1
            }
            for loss in result.report { summary.losses[loss.reason, default: 0] += loss.count }
            try Data(result.markdown.utf8).write(to: dir.appendingPathComponent(name + ".md"), options: .atomic)
            return true
        }

        func write(_ page: Page, in dir: URL, used: inout Set<String>) async throws {
            try Task.checkCancellation()
            let name = unique(fileName(page.title, untitled: untitled), in: &used)
            done += 1
            progress?(done, pages.count)
            var childUsed: Set<String> = []
            let childDir = dir.appendingPathComponent(name)
            if let databaseID = index[page.id], let database = try await source.database(databaseID) {
                var values: [UUID: [UUID: PropertyValue]] = [:]
                let rows = try await databaseRows(source: source, database: database) { values[$0.id] = $0.values }
                // С меткой порядка байтов: без неё Excel читает кириллицу неверно.
                try Data(("\u{FEFF}" + CSV.write(rows)).utf8).write(to: dir.appendingPathComponent(name + ".csv"), options: .atomic)
                summary.databases += 1
                for record in recordsByDatabase[databaseID] ?? [] {
                    done += 1
                    summary.records += 1
                    let blocks = try await source.blocks(ofPage: record.id)
                    guard blocks.contains(where: { !$0.plainText.isEmpty || $0.type.isAtom }) else { continue }
                    try fm.createDirectory(at: childDir, withIntermediateDirectories: true)
                    let recordName = unique(fileName(record.title, untitled: untitled), in: &childUsed)
                    let card = MarkdownExport.propertyCard(database, values: values[record.id] ?? [:], untitled: untitled)
                    _ = try await writeMarkdown(record, name: recordName, in: childDir, used: &childUsed, card: card)
                }
                return
            }
            if try await writeMarkdown(page, name: name, in: dir, used: &used) { summary.pages += 1 }
            let children = tree.children(of: page.id)
            guard !children.isEmpty || page.isFolder else { return }
            try fm.createDirectory(at: childDir, withIntermediateDirectories: true)
            for child in children { try await write(child, in: childDir, used: &childUsed) }
        }

        var used: Set<String> = []
        for page in tree.children(of: nil) { try await write(page, in: root, used: &used) }
        return summary
    }

    /// Имя без разделителей пути, не длиннее 80 символов: кириллица занимает по два байта из 255 допустимых.
    static func fileName(_ title: String, untitled: String) -> String {
        let base = MarkdownExport.safeFileName(title.isEmpty ? untitled : title)
        return String(base.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// Имена сравниваются без учёта регистра: так их различает файловая система macOS по умолчанию.
    static func unique(_ name: String, in used: inout Set<String>) -> String {
        var candidate = name
        var n = 1
        while used.contains(candidate.lowercased()) {
            n += 1
            candidate = "\(name) \(n)"
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
