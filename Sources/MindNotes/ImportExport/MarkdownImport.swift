import Foundation

/// Markdown в блоки. Импорт, а не второй источник истины: после него страница живёт в базе.
enum MarkdownImport {
    /// `image` превращает строку-картинку `![подпись](путь)` в блок, nil оставляет подпись текстом.
    /// `link` даёт цель ссылки для метки `a:` по адресу из текста; nil убирает ссылку и оставляет текст.
    static func fragments(from text: String, image: (_ alt: String, _ path: String) -> BlockFragment? = { _, _ in nil },
                          link: (String) -> String? = safeLink) -> [BlockFragment] {
        var out: [BlockFragment] = []
        var paragraph: [String] = []
        var tableRows: [[String]] = []

        func runs(_ body: String) -> [TextRun] { resolve(inline(body), link: link) }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            out.append(AtomData.table(tableRows))
            tableRows = []
        }
        func flush() {
            flushTable()
            guard !paragraph.isEmpty else { return }
            out.append(BlockFragment(type: .paragraph, content: BlockContent(runs: runs(paragraph.joined(separator: "\n")))))
            paragraph = []
        }
        func add(_ type: BlockType, _ body: String, checked: Bool = false) {
            flush()
            out.append(BlockFragment(type: type, content: BlockContent(runs: runs(body), checked: checked)))
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
            if line.hasPrefix("|"), line.hasSuffix("|"), line.count > 1 {
                if !paragraph.isEmpty { let saved = tableRows; tableRows = []; flush(); tableRows = saved }
                let cells = tableCells(line)
                // Строка-разделитель `| --- | :-: |` — разметка, а не данные.
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && $0.contains("-") }) { tableRows.append(cells) }
                continue
            }
            flushTable()
            if let picture = imageLine(line) {
                flush()
                if let block = image(picture.alt, picture.path) { out.append(block) } else if !picture.alt.isEmpty { paragraph.append(picture.alt) }
                continue
            }
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

    /// Картинка на отдельной строке: `![подпись](путь)` или `![подпись](<путь с пробелами>)`.
    static func imageLine(_ line: String) -> (alt: String, path: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        var path = String(line[close.upperBound..<line.index(before: line.endIndex)])
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        guard !path.isEmpty, !alt.contains("]") else { return nil }
        return (alt.replacingOccurrences(of: "\\", with: ""), path)
    }

    /// Все картинки текста: пути нужны заранее, чтобы скопировать файлы до разбора.
    static func imageReferences(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { imageLine($0.trimmingCharacters(in: .whitespaces))?.path }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line.dropFirst().dropLast() {
            if escaped { current.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(ch) }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Закрывающая скобка адреса с учётом вложенных: `(a(1))`.
    private static func closingParen(_ text: Substring) -> Substring.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "(": depth += 1
            case ")": if depth == 0 { return index } else { depth -= 1 }
            case "\n": return nil
            default: break
            }
        }
        return nil
    }

    /// Ссылка разрешена, только если её можно безопасно открыть: http, https, mailto.
    static func safeLink(_ href: String) -> String? {
        PropertyParse.openable(href) != nil ? href : nil
    }

    /// Метки ссылок `a:адрес` из разбора заменяются целью, которую вернул `link`, или убираются.
    static func resolve(_ runs: [TextRun], link: (String) -> String?) -> [TextRun] {
        RichText.normalized(runs.map { run in
            var run = run
            run.marks = run.marks.compactMap { mark in
                guard mark.hasPrefix("a:") else { return mark }
                return link(String(mark.dropFirst(2))).map { $0.hasPrefix("a:") ? $0 : "a:" + $0 }
            }
            return run
        })
    }

    /// Встроенная разметка: **жирный**, *курсив*, ~~зачёркнутый~~, `код`. Незакрытая разметка остаётся текстом.
    static func inline(_ text: String) -> [TextRun] {
        let tokens: [(String, String)] = [("**", "b"), ("~~", "s"), ("`", "code"), ("*", "i"), ("_", "i")]
        var runs: [TextRun] = []
        var rest = Substring(text)
        var plain = ""
        scan: while !rest.isEmpty {
            // Экранированный символ разметки — обычный текст: так читается наш собственный экспорт.
            if rest.hasPrefix("\\"), rest.count > 1, "\\*_`[]<>#|~".contains(rest[rest.index(after: rest.startIndex)]) {
                rest.removeFirst()
                plain.append(rest.removeFirst())
                continue scan
            }
            // Ссылки: [[Заголовок]] из нашего экспорта и [текст](адрес). Цель уточняет `resolve`.
            if rest.hasPrefix("[[") , let end = rest.range(of: "]]"), !rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound].contains("\n") {
                let label = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])
                if !label.isEmpty {
                    if !plain.isEmpty { runs.append(TextRun(plain)); plain = "" }
                    runs.append(TextRun(label, marks: ["a:wiki:" + label]))
                    rest = rest[end.upperBound...]
                    continue scan
                }
            }
            if rest.hasPrefix("["), let close = rest.range(of: "]("), let end = closingParen(rest[close.upperBound...]) {
                let label = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
                var href = String(rest[close.upperBound..<end])
                if href.hasPrefix("<"), href.hasSuffix(">") { href = String(href.dropFirst().dropLast()) }
                if !label.isEmpty, !label.contains("["), !label.contains("\n"), !href.isEmpty, !href.contains("\n") {
                    if !plain.isEmpty { runs.append(TextRun(plain)); plain = "" }
                    runs.append(TextRun(label.replacingOccurrences(of: "\\", with: ""), marks: ["a:" + href]))
                    rest = rest[rest.index(after: end)...]
                    continue scan
                }
            }
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
