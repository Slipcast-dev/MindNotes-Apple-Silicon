import Foundation

/// Markdown в блоки. Импорт, а не второй источник истины: после него страница живёт в базе.
enum MarkdownImport {
    static func fragments(from text: String) -> [BlockFragment] {
        var out: [BlockFragment] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append(BlockFragment(type: .paragraph, content: BlockContent(runs: inline(paragraph.joined(separator: "\n")))))
            paragraph = []
        }
        func add(_ type: BlockType, _ body: String, checked: Bool = false) {
            flush()
            out.append(BlockFragment(type: type, content: BlockContent(runs: inline(body), checked: checked)))
        }

        var codeLines: [String]?
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let body = codeLines {
                    out.append(BlockFragment(type: .code, content: BlockContent(text: body.joined(separator: "\n"))))
                    codeLines = nil
                } else {
                    flush()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil { codeLines?.append(rawLine); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("### ") { add(.heading3, String(line.dropFirst(4))) }
            else if line.hasPrefix("## ") { add(.heading2, String(line.dropFirst(3))) }
            else if line.hasPrefix("# ") { add(.heading1, String(line.dropFirst(2))) }
            else if line.lowercased().hasPrefix("- [x] ") { add(.task, String(line.dropFirst(6)), checked: true) }
            else if line.hasPrefix("- [ ] ") { add(.task, String(line.dropFirst(6))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { add(.bullet, String(line.dropFirst(2))) }
            else if let dot = line.range(of: ". "), !line[..<dot.lowerBound].isEmpty, line[..<dot.lowerBound].allSatisfy(\.isNumber) { add(.numbered, String(line[dot.upperBound...])) }
            else if line.hasPrefix("> ") { add(.quote, String(line.dropFirst(2))) }
            else if line == "---" || line == "***" || line == "___" {
                flush()
                out.append(BlockFragment(type: BlockType.divider.rawValue, contentVersion: 1, json: "{}", plain: ""))
            }
            else { paragraph.append(rawLine) }
        }
        if let body = codeLines { out.append(BlockFragment(type: .code, content: BlockContent(text: body.joined(separator: "\n")))) }
        flush()
        return out
    }

    /// Встроенная разметка: **жирный**, *курсив*, ~~зачёркнутый~~, `код`. Незакрытая разметка остаётся текстом.
    static func inline(_ text: String) -> [TextRun] {
        let tokens: [(String, String)] = [("**", "b"), ("~~", "s"), ("`", "code"), ("*", "i"), ("_", "i")]
        var runs: [TextRun] = []
        var rest = Substring(text)
        var plain = ""
        scan: while !rest.isEmpty {
            for (token, mark) in tokens where rest.hasPrefix(token) {
                let body = rest.dropFirst(token.count)
                if let end = body.range(of: token), end.lowerBound != body.startIndex {
                    // Маркер должен прилегать к тексту: «2 * 3 * 4» и «*.txt и *.md» — обычный текст.
                    let opensOnText = body.first?.isWhitespace == false
                    let closesOnText = body[body.index(before: end.lowerBound)].isWhitespace == false
                    // Подчёркивание внутри слова не разметка: snake_case_name.
                    let wordBefore = plain.last.map { $0.isLetter || $0.isNumber } ?? runs.last?.text.last.map { $0.isLetter || $0.isNumber } ?? false
                    let afterClose = body[end.upperBound...].first
                    let wordAfter = afterClose.map { $0.isLetter || $0.isNumber } ?? false
                    if token != "`" {
                        guard opensOnText, closesOnText else { continue }
                        if token == "_", wordBefore || wordAfter { continue }
                    }
                    if !plain.isEmpty { runs.append(TextRun(plain)); plain = "" }
                    runs.append(TextRun(String(body[..<end.lowerBound]), marks: [mark]))
                    rest = body[end.upperBound...]
                    continue scan
                }
            }
            plain.append(rest.removeFirst())
        }
        if !plain.isEmpty { runs.append(TextRun(plain)) }
        return runs
    }
}
