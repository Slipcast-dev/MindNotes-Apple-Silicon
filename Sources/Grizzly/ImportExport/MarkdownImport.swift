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

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("### ") { add(.heading3, String(line.dropFirst(4))) }
            else if line.hasPrefix("## ") { add(.heading2, String(line.dropFirst(3))) }
            else if line.hasPrefix("# ") { add(.heading1, String(line.dropFirst(2))) }
            else if line.lowercased().hasPrefix("- [x] ") { add(.task, String(line.dropFirst(6)), checked: true) }
            else if line.hasPrefix("- [ ] ") { add(.task, String(line.dropFirst(6))) }
            else { paragraph.append(rawLine) }
        }
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
