import Foundation

/// Text alignment of a paragraph, written in the file as `<div align="center">text</div>` around the line.
enum MDAlign: String {
    case left, center, right, justify
}

/// One item of a check list; `line` is its 0-based line in the file, so a click on the circle can rewrite that line.
struct MDTask: Equatable {
    let done: Bool
    let text: String
    let line: Int
}

indirect enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    /// `* item` or `+ item`: dots.
    case bullets([String])
    /// `- item`: dashes.
    case dashes([String])
    case numbered([String])
    /// `- [ ] item` and `- [x] item`.
    case tasks([MDTask])
    case code(String, String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])
    /// The block with an explicit alignment.
    case aligned(MDAlign, MDBlock)
}

enum MarkdownParser {
    static func parse(_ lines: [String]) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                i += 1
                blocks.append(.code(lang, body.joined(separator: "\n")))
                continue
            }

            if let (level, text) = heading(trimmed) {
                let (align, content) = splitAlignment(text)
                blocks.append(wrap(.heading(level, content), align)); i += 1; continue
            }

            if isRule(trimmed) { blocks.append(.rule); i += 1; continue }

            if trimmed.hasPrefix(">") {
                var q: [String] = []
                var align: MDAlign?
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var t = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if t.hasPrefix(" ") { t = t.dropFirst() }
                    let (a, content) = splitAlignment(String(t))
                    if q.isEmpty { align = a }
                    q.append(content); i += 1
                }
                blocks.append(wrap(.quote(q.joined(separator: "\n")), align))
                continue
            }

            if let first = listItem(trimmed) {
                // A run of items of the same kind is one list; a different marker starts the next one.
                var texts: [String] = []
                var tasks: [MDTask] = []
                while i < lines.count, let item = listItem(lines[i].trimmingCharacters(in: .whitespaces)), item.kind == first.kind {
                    if let done = item.done { tasks.append(MDTask(done: done, text: item.text, line: i)) } else { texts.append(item.text) }
                    i += 1
                }
                switch first.kind {
                case .task: blocks.append(.tasks(tasks))
                case .dash: blocks.append(.dashes(texts))
                case .dot: blocks.append(.bullets(texts))
                }
                continue
            }

            if numberedItem(trimmed) != nil {
                var items: [String] = []
                while i < lines.count, let b = numberedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(b); i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            var para: [String] = []
            var align: MDAlign?
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix(">") || heading(t) != nil
                    || listItem(t) != nil || numberedItem(t) != nil || isRule(t) { break }
                let (a, content) = splitAlignment(t)
                if para.isEmpty { align = a } else if a != align { break }
                para.append(content); i += 1
            }
            if para.isEmpty { i += 1 } else { blocks.append(wrap(.paragraph(para.joined(separator: " ")), align)) }
        }
        return blocks
    }

    private static func heading(_ s: String) -> (Int, String)? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), s.dropFirst(level).first == " " else { return nil }
        return (level, s.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }

    private enum ListKind { case dot, dash, task }

    /// `- a`, `* a`, `+ a`, `- [ ] a`, `- [x] a`. `done` is set for check list items only.
    private static func listItem(_ s: String) -> (kind: ListKind, text: String, done: Bool?)? {
        guard s.count > 2, let marker = s.first, "-*+".contains(marker), s.dropFirst().first == " " else { return nil }
        let rest = String(s.dropFirst(2))
        if rest.hasPrefix("[ ] ") || rest == "[ ]" { return (.task, String(rest.dropFirst(min(4, rest.count))), false) }
        let lower = rest.lowercased()
        if lower.hasPrefix("[x] ") || lower == "[x]" { return (.task, String(rest.dropFirst(min(4, rest.count))), true) }
        return (marker == "-" ? .dash : .dot, rest, nil)
    }

    private static func wrap(_ block: MDBlock, _ align: MDAlign?) -> MDBlock {
        guard let align, align != .left else { return block }
        return .aligned(align, block)
    }

    /// `<div align="center">text</div>` -> (center, "text"); any other line comes back unchanged.
    static func splitAlignment(_ s: String) -> (MDAlign?, String) {
        let open = "<div align=\""
        guard s.hasPrefix(open), s.hasSuffix("</div>"), let quote = s.dropFirst(open.count).firstIndex(of: "\""),
              let align = MDAlign(rawValue: String(s[s.index(s.startIndex, offsetBy: open.count)..<quote])) else { return (nil, s) }
        let afterQuote = s.index(after: quote)
        guard s[afterQuote...].hasPrefix(">") else { return (nil, s) }
        let start = s.index(after: afterQuote)
        let end = s.index(s.endIndex, offsetBy: -"</div>".count)
        guard start <= end else { return (nil, s) }
        return (align, String(s[start..<end]))
    }

    /// Stable keys for the headings that can be folded (Title and Heading: `#` and `##`), by block index.
    /// The key is made of the level, the text and the position among equal headings, so it survives edits elsewhere.
    static func sectionKeys(_ blocks: [MDBlock]) -> [Int: String] {
        var seen: [String: Int] = [:]
        var keys: [Int: String] = [:]
        for (i, block) in blocks.enumerated() {
            var inner = block
            if case .aligned(_, let b) = block { inner = b }
            guard case .heading(let level, let text) = inner, level <= 2 else { continue }
            let base = "\(level)|\(text)"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            keys[i] = "\(base)|\(n)"
        }
        return keys
    }

    private static func numberedItem(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: "."), dot != s.startIndex,
              s[s.startIndex..<dot].allSatisfy(\.isNumber),
              s[s.index(after: dot)...].first == " " else { return nil }
        return String(s[s.index(dot, offsetBy: 2)...])
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
