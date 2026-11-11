import CryptoKit
import Foundation

/// Импорт папки с Markdown и CSV, в том числе распакованного экспорта Notion (FR-14).
/// Оригиналы только читаются. Всё попадает под новую страницу импорта, поэтому отменить импорт можно,
/// отправив её в корзину. Два прохода: сначала страницы и базы, затем текст со ссылками друг на друга.
enum FolderImport {
    struct Limits {
        var maxFiles = 20_000
        var maxTotalBytes: Int64 = 4 << 30
        /// Больше этого текст не читается: он обходится как неподдерживаемый.
        var maxTextBytes: Int64 = Int64(TextFileReader.maxSize)
    }

    struct Plan: Equatable {
        let root: URL
        /// Пути относительно корня, через `/`, в порядке сортировки.
        var markdown: [String] = []
        var csv: [String] = []
        var directories: [String] = []
        /// Прочие обычные файлы: становятся вложениями, если на них ссылается страница.
        var files: Set<String> = []
        /// Путь и причина пропуска.
        var skipped: [Skipped] = []
        var totalBytes: Int64 = 0
        /// Отпечаток набора файлов: повторный импорт того же содержимого распознаётся.
        var fingerprint = ""
    }

    struct Skipped: Equatable {
        var path: String
        var reason: String
    }

    struct Report: Equatable {
        var pages = 0
        var folders = 0
        var databases = 0
        var records = 0
        var assets = 0
        var unresolvedLinks = 0
        /// Связи Notion: восстановленные свойства, столбцы, оставленные текстом, и ссылки на записи не из архива.
        var relations = 0
        var textRelations = 0
        var unresolvedRelationLinks = 0
        var missingImages = 0
        var unconvertedValues = 0
        var unusedFiles = 0
        var skipped: [Skipped] = []
    }

    static let textExtensions: Set<String> = ["md", "markdown", "txt"]

    // MARK: Обход

    static func scan(_ root: URL, limits: Limits = Limits()) throws -> Plan {
        let fm = FileManager.default
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var plan = Plan(root: base)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var lines: [String] = []
        var count = 0
        for case let url as URL in walker {
            // Без разрешения ссылок: иначе символическая ссылка подменилась бы своей целью.
            let rel = relativePath(url, base: base, resolvingLinks: false)
            guard let rel, !rel.isEmpty else { continue }
            if rel.split(separator: "/").first == "__MACOSX" { walker.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                plan.skipped.append(Skipped(path: rel, reason: "Символическая ссылка"))
                continue
            }
            if values.isDirectory == true { plan.directories.append(rel); continue }
            guard values.isRegularFile == true else {
                plan.skipped.append(Skipped(path: rel, reason: "Не обычный файл"))
                continue
            }
            count += 1
            guard count <= limits.maxFiles else { throw ImportError.tooManyFiles(limits.maxFiles) }
            let size = Int64(values.fileSize ?? 0)
            plan.totalBytes += size
            guard plan.totalBytes <= limits.maxTotalBytes else { throw ImportError.tooLarge(limits.maxTotalBytes) }
            lines.append("\(rel)\t\(size)")
            let ext = url.pathExtension.lowercased()
            if textExtensions.contains(ext) {
                if size > limits.maxTextBytes { plan.skipped.append(Skipped(path: rel, reason: "Слишком большой текст")) } else { plan.markdown.append(rel) }
            } else if ext == "csv" {
                if size > limits.maxTextBytes { plan.skipped.append(Skipped(path: rel, reason: "Слишком большая таблица")) } else { plan.csv.append(rel) }
            } else {
                plan.files.insert(rel)
            }
        }
        let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        plan.markdown.sort(by: order)
        plan.csv.sort(by: order)
        plan.directories.sort(by: order)
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        plan.fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return plan
    }

    /// Путь внутри корня или nil. Сравнение по компонентам: `/a/bc` не считается внутри `/a/b`.
    static func relativePath(_ url: URL, base: URL, resolvingLinks: Bool = true) -> String? {
        let standard = url.standardizedFileURL
        let parts = (resolvingLinks ? standard.resolvingSymlinksInPath() : standard).pathComponents
        let root = base.pathComponents
        guard parts.count >= root.count, Array(parts.prefix(root.count)) == root else { return nil }
        return parts.dropFirst(root.count).joined(separator: "/")
    }

    /// Заголовок из имени файла: без расширения, без идентификатора Notion и суффикса `_all`.
    static func cleanTitle(_ name: String) -> String {
        var stem = name
        let ext = (stem as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) || ext == "csv" { stem = (stem as NSString).deletingPathExtension }
        if stem.hasSuffix("_all") { stem = String(stem.dropLast(4)) }
        if let range = stem.range(of: #" [0-9a-f]{32}$"#, options: .regularExpression) { stem.removeSubrange(range) }
        return stem.trimmingCharacters(in: .whitespaces)
    }

    /// Ключ для сопоставления папки с одноимённой страницей или таблицей.
    static func stemKey(_ name: String) -> String { SearchText.normalize(cleanTitle(name)) }

    // MARK: Импорт

    /// `title` — название страницы импорта; `untitled` — подпись для пустых заголовков.
    static func run(_ plan: Plan, into target: ImportTarget, title: String, untitled: String, viewName: String,
                    zone: String, ids: IDGenerator = RandomIDs(), now: Int64,
                    progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> (root: UUID, report: Report) {
        var report = Report(skipped: plan.skipped)
        let rootID = ids.next()
        _ = try await target.createPage(parent: nil, title: title, id: rootID, now: now)

        var pageOf: [String: UUID] = [:]           // Markdown-файл → страница
        var titleIndex: [String: [UUID]] = [:]      // заголовок → страницы, для ссылок [[…]]
        var recordsOfDirectory: [String: [String: UUID]] = [:]  // папка строк Notion → заголовок записи → запись
        var titlesOfDirectory: [String: [String: UUID]] = [:]   // то же, но не расходуется: для связей
        var databaseOfRecord: [UUID: UUID] = [:]
        var propertyNames: [UUID: Set<String>] = [:]            // запись → имена свойств её базы
        var notionPage: [String: UUID] = [:]                    // ID Notion из имени файла → страница
        var pendingRelations: [PendingRelation] = []
        let total = plan.markdown.count + plan.csv.count
        var done = 0

        func remember(_ id: UUID, _ title: String) { titleIndex[SearchText.normalize(title), default: []].append(id) }
        func parent(of rel: String) -> String { (rel as NSString).deletingLastPathComponent }
        func name(of rel: String) -> String { (rel as NSString).lastPathComponent }
        func display(_ raw: String) -> String { let t = cleanTitle(raw); return t.isEmpty ? untitled : t }

        // Таблицы Notion выгружаются дважды: «X.csv» (текущий вид) и «X_all.csv» (все строки). Берётся полная.
        let csvFiles = plan.csv.filter { rel in
            let stem = ((rel as NSString).deletingPathExtension)
            if !stem.hasSuffix("_all"), plan.csv.contains(stem + "_all.csv") {
                report.skipped.append(Skipped(path: rel, reason: "Неполная копия таблицы Notion: импортирована версия _all"))
                return false
            }
            return true
        }

        func importDirectory(_ dir: String, parentPage: UUID) async throws {
            let inDir: (String) -> Bool = { parent(of: $0) == dir }
            var stemPage: [String: UUID] = [:]
            var stemDatabase: [String: [String: UUID]] = [:]
            for rel in csvFiles where inDir(rel) {
                try Task.checkCancellation()
                done += 1
                progress?(done, total)
                // Нечитаемый файл пропускается с записью в отчёт, а не обрывает весь импорт.
                guard let text = try? TextFileReader.read(plan.root.appendingPathComponent(rel)).text else {
                    report.skipped.append(Skipped(path: rel, reason: "Не удалось прочитать как текст"))
                    continue
                }
                let table = CSV.parse(text, delimiter: CSV.detectDelimiter(text))
                guard !table.isEmpty else { report.skipped.append(Skipped(path: rel, reason: "Пустая таблица")); continue }
                var csvPlan = CSVImport.plan(table, hasHeader: true, zone: zone)
                // Столбец связей Notion пока текст: цели появятся, когда будут созданы все базы.
                let relationColumns = (1..<max(1, csvPlan.headers.count)).filter { i in NotionRelations.isRelationColumn(csvPlan.rows.map { $0[i] }) }
                for i in relationColumns { csvPlan.types[i] = .text }
                let built = CSVImport.build(csvPlan, zone: zone, ids: ids)
                let database = try await target.importDatabase(parent: parentPage, title: display(name(of: rel)), viewName: viewName,
                                                               properties: built.properties, records: built.records, now: now)
                report.databases += 1
                report.records += built.records.count
                report.unconvertedValues += built.unconverted
                remember(database.pageID, display(name(of: rel)))
                var byTitle: [String: UUID] = [:]
                for record in built.records {
                    remember(record.id, record.title)
                    byTitle[SearchText.normalize(record.title)] = byTitle[SearchText.normalize(record.title)] ?? record.id
                }
                stemDatabase[stemKey(name(of: rel))] = byTitle
                let names = Set(built.properties.map { SearchText.normalize($0.name) })
                for record in built.records { databaseOfRecord[record.id] = database.id; propertyNames[record.id] = names }
                for i in relationColumns where i < database.properties.count {
                    let cells = zip(built.records, csvPlan.rows).map { (record: $0.id, text: $1[i]) }
                    pendingRelations.append(PendingRelation(database: database.id, property: database.properties[i].id, directory: dir, cells: cells))
                }
                stemPage[stemKey(name(of: rel))] = database.pageID
            }
            for rel in plan.markdown where inDir(rel) {
                try Task.checkCancellation()
                let key = SearchText.normalize(cleanTitle(name(of: rel)))
                // Страница строки Notion: её текст достаётся записи с тем же заголовком.
                if let records = recordsOfDirectory[dir], let record = records[key] {
                    pageOf[rel] = record
                    if let notion = NotionRelations.id(in: name(of: rel)) { notionPage[notion] = record }
                    recordsOfDirectory[dir]?[key] = nil
                    stemPage[stemKey(name(of: rel))] = record
                    continue
                }
                let id = ids.next()
                _ = try await target.createPage(parent: parentPage, title: display(name(of: rel)), id: id, now: now)
                pageOf[rel] = id
                if let notion = NotionRelations.id(in: name(of: rel)) { notionPage[notion] = id }
                remember(id, display(name(of: rel)))
                stemPage[stemKey(name(of: rel))] = stemPage[stemKey(name(of: rel))] ?? id
                report.pages += 1
            }
            for sub in plan.directories where inDir(sub) {
                try Task.checkCancellation()
                let key = stemKey(name(of: sub))
                if let records = stemDatabase[key] { recordsOfDirectory[sub] = records; titlesOfDirectory[sub] = records }
                let pageForSub: UUID
                if let existing = stemPage[key] {
                    pageForSub = existing
                } else {
                    let id = ids.next()
                    var folder = try await target.createPage(parent: parentPage, title: display(name(of: sub)), id: id, now: now)
                    folder.icon = Page.folderIcon
                    try await target.updatePage(folder)
                    report.folders += 1
                    pageForSub = id
                }
                try await importDirectory(sub, parentPage: pageForSub)
            }
        }
        try await importDirectory("", parentPage: rootID)

        // Связи Notion: каждая ссылка ищется по пути к файлу записи, по ID Notion, затем по заголовку в папке строк.
        func record(for reference: NotionRelations.Reference, from dir: String) -> UUID? {
            let decoded = reference.target.removingPercentEncoding ?? reference.target
            if !decoded.contains("://") {
                let path = dir.isEmpty ? decoded : dir + "/" + decoded
                if let rel = relativePath(plan.root.appendingPathComponent(path), base: plan.root) {
                    if let page = pageOf[rel], databaseOfRecord[page] != nil { return page }
                    if let page = titlesOfDirectory[parent(of: rel)]?[SearchText.normalize(reference.title)] { return page }
                }
            }
            if let notion = NotionRelations.id(in: decoded), let page = notionPage[notion], databaseOfRecord[page] != nil { return page }
            return nil
        }
        var resolved: [(pending: PendingRelation, target: UUID, links: [(from: UUID, to: UUID)], missing: Int)] = []
        for pending in pendingRelations {
            var links: [(from: UUID, to: UUID)] = []
            var missing = 0
            for cell in pending.cells {
                var seen: Set<UUID> = []
                for reference in NotionRelations.references(cell.text) ?? [] {
                    guard let page = record(for: reference, from: pending.directory) else { missing += 1; continue }
                    if seen.insert(page).inserted { links.append((cell.record, page)) }
                }
            }
            let targets = Set(links.compactMap { databaseOfRecord[$0.to] })
            // Ссылки в разные базы или ни одной найденной: столбец остаётся текстом, данные не теряются.
            guard targets.count == 1, let target = targets.first else { report.textRelations += 1; continue }
            resolved.append((pending, target, links, missing))
        }
        // Двусторонняя связь Notion выгружается двумя столбцами; они становятся одной парой, если строки совпадают.
        var paired: Set<Int> = []
        for (i, a) in resolved.enumerated() where !paired.contains(i) {
            let forward = Set(a.links.map { "\($0.from)>\($0.to)" })
            let match = resolved.indices.first { j in
                j != i && !paired.contains(j) && resolved[j].pending.database == a.target && resolved[j].target == a.pending.database
                    && Set(resolved[j].links.map { "\($0.to)>\($0.from)" }) == forward
            }
            paired.insert(i)
            if let match { paired.insert(match) }
            try await target.importRelation(property: a.pending.property, target: a.target, pair: match.map { resolved[$0].pending.property },
                                            links: a.links, now: now)
            report.relations += 1
            report.unresolvedRelationLinks += a.missing + (match.map { resolved[$0].missing } ?? 0)
        }

        // Второй проход: текст, картинки и ссылки. Все страницы уже существуют, поэтому ссылки разрешаются.
        var assetOf: [String: AssetRecord] = [:]
        var usedFiles: Set<String> = []
        for rel in plan.markdown {
            guard let page = pageOf[rel] else { continue }
            try Task.checkCancellation()
            done += 1
            progress?(done, total)
            guard let source = try? TextFileReader.read(plan.root.appendingPathComponent(rel)).text else {
                report.skipped.append(Skipped(path: rel, reason: "Не удалось прочитать как текст"))
                continue
            }
            let dir = parent(of: rel)
            func resolve(_ href: String) -> String? {
                let decoded = href.removingPercentEncoding ?? href
                guard !decoded.contains("://"), !decoded.hasPrefix("mailto:"), !decoded.hasPrefix("/") else { return nil }
                let path = (dir.isEmpty ? decoded : dir + "/" + decoded).split(separator: "#").first.map(String.init) ?? ""
                guard let rel = relativePath(plan.root.appendingPathComponent(path), base: plan.root) else { return nil }
                return rel
            }
            for reference in MarkdownImport.imageReferences(source) {
                guard let rel = resolve(reference), plan.files.contains(rel), assetOf[rel] == nil else { continue }
                assetOf[rel] = try await target.addAsset(copying: plan.root.appendingPathComponent(rel), id: ids.next(), now: now)
                report.assets += 1
                usedFiles.insert(rel)
            }
            var missing = 0, unresolved = 0
            var fragments = MarkdownImport.fragments(from: source, image: { _, path in
                guard let rel = resolve(path), let asset = assetOf[rel] else { missing += 1; return nil }
                return AtomData.attachment(type: .image, asset: asset)
            }, link: { href in
                if href.hasPrefix("wiki:") {
                    let found = titleIndex[SearchText.normalize(String(href.dropFirst(5)))] ?? []
                    if found.count == 1 { return PageLink.mark(found[0]) }
                    unresolved += 1
                    return nil
                }
                if let safe = MarkdownImport.safeLink(href), href.contains("://") || href.hasPrefix("mailto:") { return safe }
                if let rel = resolve(href) {
                    if let target = pageOf[rel] { return PageLink.mark(target) }
                    if plan.files.contains(rel) { usedFiles.insert(rel) }
                }
                unresolved += 1
                return nil
            })
            report.missingImages += missing
            report.unresolvedLinks += unresolved
            // Notion повторяет заголовок страницы первой строкой.
            if let first = fragments.first, first.type == BlockType.heading1.rawValue,
               SearchText.normalize(first.plain) == SearchText.normalize(cleanTitle(name(of: rel))) {
                fragments.removeFirst()
            }
            if let names = propertyNames[page] { fragments = NotionRelations.dropPropertyCard(fragments, names: names) }
            try await commit(fragments, to: page, target: target, ids: ids, now: now)
        }
        report.unusedFiles = plan.files.subtracting(usedFiles).count
        return (rootID, report)
    }

    struct PendingRelation {
        var database: UUID
        var property: UUID
        /// Папка CSV: пути в ячейках отсчитываются от неё.
        var directory: String
        var cells: [(record: UUID, text: String)]
    }

    /// Блоки страницы одним пакетом: страница появляется с текстом целиком.
    static func commit(_ fragments: [BlockFragment], to page: UUID, target: ImportTarget, ids: IDGenerator, now: Int64) async throws {
        guard !fragments.isEmpty else { return }
        var batch = SaveBatch()
        for (fragment, key) in zip(fragments, SortKey.keys(after: nil, before: nil, count: fragments.count)) {
            let block = Block(id: ids.next(), pageID: page, parentID: nil, sortKey: key, type: BlockType(rawValue: fragment.type),
                              contentVersion: fragment.contentVersion, contentJSON: fragment.json, plainText: fragment.plain,
                              createdAt: now, updatedAt: now)
            batch.upserts[block.id] = block
        }
        batch.touchedPages = [page]
        try await target.commit(batch)
    }
}

enum ImportError: Error, Equatable, LocalizedError {
    case tooManyFiles(Int)
    case tooLarge(Int64)
    case unsafeArchive(String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles(let n): return String(format: NSLocalizedString("Слишком много файлов: больше %d.", comment: ""), n)
        case .tooLarge(let bytes): return String(format: NSLocalizedString("Слишком большой объём: больше %@.", comment: ""),
                                                 ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        case .unsafeArchive(let detail): return String(format: NSLocalizedString("Архив отклонён: %@.", comment: ""), detail)
        }
    }
}
