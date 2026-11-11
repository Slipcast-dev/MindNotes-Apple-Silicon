import Foundation

/// Экспорт страницы в Markdown (FR-15). Переносимый формат, а не резервная копия:
/// то, что Markdown не выражает, попадает в отчёт, а не теряется молча.
enum MarkdownExport {
    struct Result: Equatable {
        var markdown: String
        /// Вложения страницы: идентификатор и путь в тексте.
        var assets: [(id: UUID, path: String)]
        /// Что Markdown не выразил: причина (ключ перевода) и сколько раз.
        var report: [(reason: String, count: Int)]

        static func == (a: Result, b: Result) -> Bool {
            a.markdown == b.markdown && a.report.map(\.reason) == b.report.map(\.reason) && a.report.map(\.count) == b.report.map(\.count) && a.assets.map(\.id) == b.assets.map(\.id) && a.assets.map(\.path) == b.assets.map(\.path)
        }
    }

    /// `pageTitle` — заголовок страницы по ссылке; `assetFolder` — папка вложений рядом с файлом.
    /// `card` — строки свойств записи (`propertyCard`), они идут сразу под заголовком.
    static func export(title: String, card: [String] = [], blocks: [Block], assetFolder: String, pageTitle: (UUID) -> String?) -> Result {
        var depth: [UUID: Int] = [:]
        var out: [String] = ["# " + escape(title)] + card.map { "\n" + $0 }
        var assets: [(UUID, String)] = []
        var usedNames: Set<String> = []
        var lost: [String: Int] = [:]
        var number: [String: Int] = [:]
        var previousWasList = false

        for block in blocks {
            let level = block.parentID.flatMap { depth[$0].map { $0 + 1 } } ?? 0
            depth[block.id] = level
            let indent = String(repeating: "    ", count: level)
            let text = inline(block, pageTitle: pageTitle, lost: &lost)
            let siblingKey = "\(block.parentID?.uuidString ?? "")"
            if block.type != .numbered { number[siblingKey] = nil }
            var line: String
            var isList = false
            switch block.type {
            case .paragraph: line = text
            case .heading1: line = "## " + text
            case .heading2: line = "### " + text
            case .heading3: line = "#### " + text
            case .bullet: line = "- " + text; isList = true
            case .toggle: line = "- " + text; isList = true; lost["Сворачиваемые блоки стали пунктами списка", default: 0] += 1
            case .numbered:
                let n = (number[siblingKey] ?? 0) + 1
                number[siblingKey] = n
                line = "\(n). " + text; isList = true
            case .task: line = "- [\(block.content?.checked == true ? "x" : " ")] " + text; isList = true
            case .quote: line = "> " + text
            case .callout: line = "> 💡 " + text
            case .code: line = "```\n" + block.plainText + "\n```"
            case .divider: line = "---"
            case .image, .video, .file:
                let name = AtomData.name(of: block)
                if case .string(let raw)? = block.atomJSON["asset"], let id = UUID(uuidString: raw) {
                    let path = assetFolder + "/" + unique(safeFileName(name), in: &usedNames)
                    assets.append((id, path))
                    line = (block.type == .image ? "!" : "") + "[\(escape(name))](<\(path)>)"
                } else {
                    line = escape(name)
                    lost["Вложения без файла", default: 0] += 1
                }
            case .table: line = table(AtomData.rows(of: block))
            case .databaseView:
                line = "*\\[Представление базы\\]*"
                lost["Встроенные представления баз (экспортируйте базу в CSV)", default: 0] += 1
            default:
                line = escape(block.plainText)
                if !BlockType.known.contains(block.type) { lost["Неизвестные блоки: сохранён только текст", default: 0] += 1 }
            }
            if !line.isEmpty || block.type == .paragraph {
                let indented = line.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : indent + $0 }.joined(separator: "\n")
                out.append((isList && previousWasList ? "" : "\n") + indented)
            }
            previousWasList = isList
        }
        let report = lost.sorted { $0.key < $1.key }.map { (reason: $0.key, count: $0.value) }
        return Result(markdown: out.joined(separator: "\n") + "\n", assets: assets, report: report)
    }

    /// Карточка записи: `Имя: значение` на каждое непустое свойство, связи — ссылками `[[Заголовок]]`, как в тексте.
    /// Так же записывает свойства Notion; при импорте такие строки снимаются, если свойство есть в базе.
    /// `fileLink` даёт путь к выгруженному файлу «Файлов и медиа»; nil — только имя.
    static func propertyCard(_ database: Database, values: [UUID: PropertyValue], untitled: String, fileLink: (AttachedFile) -> String? = { _ in nil }) -> [String] {
        database.properties.compactMap { property in
            guard property.type != .title, let value = values[property.id] else { return nil }
            let text: String
            if case .relation(let pages) = value {
                text = pages.map { "[[" + ($0.title.isEmpty ? untitled : $0.title) + "]]" }.joined(separator: ", ")
            } else if case .files(let files) = value {
                text = files.map { file in fileLink(file).map { "[" + escape(file.name) + "](<" + $0 + ">)" } ?? escape(file.name) }.joined(separator: ", ")
            } else {
                text = escape(PropertyConversion.text(of: value, options: property.options)).replacingOccurrences(of: "\n", with: " ")
            }
            return text.isEmpty ? nil : escape(property.name) + ": " + text
        }
    }

    private static func inline(_ block: Block, pageTitle: (UUID) -> String?, lost: inout [String: Int]) -> String {
        guard let runs = block.content?.runs else { return escape(block.plainText) }
        return runs.map { run in
            var text = run.marks.contains("code") ? "`" + run.text + "`" : escape(run.text)
            if run.marks.contains("b") { text = "**" + text + "**" }
            if run.marks.contains("i") { text = "*" + text + "*" }
            if run.marks.contains("s") { text = "~~" + text + "~~" }
            if run.marks.contains("u") { lost["Подчёркивание", default: 0] += 1 }
            if run.marks.contains(where: { $0.hasPrefix("c:") || $0.hasPrefix("bg:") }) { lost["Цвет текста и выделение", default: 0] += 1 }
            if let mark = run.marks.first(where: { $0.hasPrefix("a:") }) {
                if let page = PageLink.page(fromMark: mark) {
                    text = "[[" + (pageTitle(page) ?? run.text) + "]]"
                } else {
                    text = "[" + text + "](<" + String(mark.dropFirst(2)) + ">)"
                }
            }
            return text
        }.joined()
    }

    private static func table(_ rows: [[String]]) -> String {
        guard let header = rows.first, !header.isEmpty else { return "" }
        let width = rows.map(\.count).max() ?? 0
        func row(_ cells: [String]) -> String {
            "| " + (0..<width).map { i in i < cells.count ? escape(cells[i]).replacingOccurrences(of: "|", with: "\\|") : "" }.joined(separator: " | ") + " |"
        }
        return ([row(header), "|" + String(repeating: " --- |", count: width)] + rows.dropFirst().map(row)).joined(separator: "\n")
    }

    /// Экранирует символы разметки, чтобы текст не превратился в форматирование.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\*_`[]<>#".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Имя файла без разделителей пути и управляющих символов.
    static func safeFileName(_ name: String) -> String {
        let cleaned = name.map { "/\\:".contains($0) || $0.isNewline ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        return result.isEmpty || result.hasPrefix(".") ? "file" + result : result
    }

    private static func unique(_ name: String, in used: inout Set<String>) -> String {
        var candidate = name
        var n = 1
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while used.contains(candidate.lowercased()) {
            n += 1
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
