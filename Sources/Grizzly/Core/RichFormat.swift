import Foundation

/// The formatting commands of the editor. They work on the Markdown source: each one turns the text and the selection into
/// one replacement (`TextEdit`), so the same code serves the toolbar, the menu and the tests, and undo is a single step.
struct TextEdit: Equatable {
    /// The part of the old text that is replaced.
    var range: NSRange
    var text: String
    /// The selection afterwards, in the coordinates of the new text.
    var selection: NSRange
}

enum ParagraphKind: Equatable { case title, heading, subheading, body, monospaced }
enum InlineKind: Equatable { case bold, italic, underline, strike }
enum ListKind: Equatable { case bullet, dash, numbered, checklist }

enum TableCommand: Equatable {
    case insert
    case addRow, addColumn, deleteRow, deleteColumn
    case moveRowUp, moveRowDown, moveColumnLeft, moveColumnRight
    case toText
}

enum FormatCommand: Equatable {
    case paragraph(ParagraphKind)
    case inline(InlineKind)
    /// A highlight color name (`InlineMarkup.highlightNames`); nil removes the highlight.
    case highlight(String?)
    case align(MDAlign)
    case list(ListKind)
    case quote
    case rule
    case table(TableCommand)
}

enum RichFormat {
    static func apply(_ command: FormatCommand, text: String, selection: NSRange) -> TextEdit? {
        switch command {
        case .paragraph(let kind): return paragraph(kind, text: text, selection: selection)
        case .inline(let kind): return inline(kind, text: text, selection: selection)
        case .highlight(let color): return highlight(color, text: text, selection: selection)
        case .align(let align): return alignment(align, text: text, selection: selection)
        case .list(let kind): return list(kind, text: text, selection: selection)
        case .quote: return quote(text: text, selection: selection)
        case .rule: return rule(text: text, selection: selection)
        case .table(let command): return table(command, text: text, selection: selection)
        }
    }

    // MARK: Lines

    /// The lines touched by the selection: where they are (without the last line break) and their text.
    private struct Block {
        let range: NSRange
        let lines: [String]
    }

    private static func block(_ ns: NSString, _ selection: NSRange) -> Block {
        let location = min(selection.location, ns.length)
        let sel = NSRange(location: location, length: min(selection.length, ns.length - location))
        var range = ns.lineRange(for: sel)
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return Block(range: range, lines: ns.substring(with: range).components(separatedBy: "\n"))
    }

    /// Rewrites the lines of the selection with `change`; the selection then covers the new lines.
    private static func edit(_ ns: NSString, _ b: Block, _ lines: [String], caretAtEnd: Bool = false) -> TextEdit? {
        let joined = lines.joined(separator: "\n")
        guard joined != ns.substring(with: b.range) else { return nil }
        let length = (joined as NSString).length
        return TextEdit(range: b.range, text: joined,
                        selection: caretAtEnd ? NSRange(location: b.range.location + length, length: 0)
                                              : NSRange(location: b.range.location, length: length))
    }

    /// A line split into the pieces the commands care about.
    private struct Parts {
        var indent = ""
        /// "# ", "- ", "* ", "1. ", "- [ ] ", "> " or "".
        var marker = ""
        var content = ""

        enum Kind { case none, heading, bullet, dash, numbered, check, quote }
        var kind: Kind {
            if marker.hasPrefix("#") { return .heading }
            if marker.hasPrefix(">") { return .quote }
            if marker.contains("[") { return .check }
            if marker.first?.isNumber == true { return .numbered }
            if marker.hasPrefix("-") { return .dash }
            if marker.hasPrefix("*") || marker.hasPrefix("+") { return .bullet }
            return .none
        }
    }

    private static let partsPattern = try! NSRegularExpression(
        pattern: "^([ \\t]*)(#{1,6}[ \\t]+|[-*+][ \\t]+\\[[ xX]\\][ \\t]+|[-*+][ \\t]+|\\d+\\.[ \\t]+|>[ \\t]?)?(.*)$")

    private static func parts(_ line: String) -> Parts {
        let ns = line as NSString
        guard let m = partsPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return Parts(content: line) }
        func group(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        return Parts(indent: group(1), marker: group(2), content: group(3))
    }

    /// Text of a line without its alignment wrapper.
    private static func unwrapped(_ content: String) -> (MDAlign?, String) { MarkdownParser.splitAlignment(content) }

    // MARK: Paragraph styles

    private static func paragraph(_ kind: ParagraphKind, text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let b = block(ns, selection)
        if kind == .monospaced { return monospaced(ns, b) }
        let prefix: String
        switch kind {
        case .title: prefix = "# "
        case .heading: prefix = "## "
        case .subheading: prefix = "### "
        default: prefix = ""
        }
        // The style applies to every non-empty line; a lone empty line (the caret on a blank line) takes it too.
        let single = b.lines.count == 1
        let lines = b.lines.map { line -> String in
            let p = parts(line)
            if p.content.isEmpty && !(single && !prefix.isEmpty) { return line }
            return p.indent + prefix + p.content
        }
        return edit(ns, b, lines, caretAtEnd: single)
    }

    /// Monospaced text is a fenced block around the lines; on lines that already sit in one, the fence goes away.
    private static func monospaced(_ ns: NSString, _ b: Block) -> TextEdit? {
        func isFence(_ r: NSRange) -> Bool { ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }
        var before: NSRange?
        var after: NSRange?
        if b.range.location > 0 {
            let r = ns.lineRange(for: NSRange(location: b.range.location - 1, length: 0))
            if isFence(r) { before = r }
        }
        let nextStart = NSMaxRange(b.range) + 1
        if nextStart < ns.length {
            let r = ns.lineRange(for: NSRange(location: nextStart, length: 0))
            if isFence(r) { after = r }
        }
        if let before, let after {
            var end = NSMaxRange(after)
            if end > after.location, ns.character(at: end - 1) == 10 { end -= 1 }
            let whole = NSRange(location: before.location, length: end - before.location)
            let inner = ns.substring(with: b.range)
            return TextEdit(range: whole, text: inner, selection: NSRange(location: whole.location, length: (inner as NSString).length))
        }
        var lines = b.lines.map { parts($0).content }
        if lines.allSatisfy(\.isEmpty) { lines = [""] }
        let body = lines.joined(separator: "\n")
        return TextEdit(range: b.range, text: "```\n" + body + "\n```",
                        selection: NSRange(location: b.range.location + 4, length: (body as NSString).length))
    }

    // MARK: Alignment

    private static func alignment(_ align: MDAlign, text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let b = block(ns, selection)
        var inFence = false
        let lines = b.lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); return line }
            if inFence { return line }
            let p = parts(line)
            // List items stay as they are: an aligned list item would not be a list item any more.
            guard !p.content.isEmpty, [.none, .heading, .quote].contains(p.kind) else { return line }
            let (_, plain) = unwrapped(p.content)
            let content = align == .left ? plain : "<div align=\"\(align.rawValue)\">\(plain)</div>"
            return p.indent + p.marker + content
        }
        return edit(ns, b, lines)
    }

    // MARK: Lists and quotes

    private static func list(_ kind: ListKind, text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let b = block(ns, selection)
        let target: Parts.Kind
        switch kind {
        case .bullet: target = .bullet
        case .dash: target = .dash
        case .numbered: target = .numbered
        case .checklist: target = .check
        }
        let single = b.lines.count == 1
        let items = b.lines.map(parts)
        let filled = items.filter { !$0.content.isEmpty }
        // Every line already is this kind of list: the command turns the list off.
        let off = !filled.isEmpty && filled.allSatisfy { $0.kind == target }
        var number = 0
        let lines = items.map { p -> String in
            if p.content.isEmpty && !single { return p.indent }
            if off { return p.indent + p.content }
            number += 1
            let marker: String
            switch kind {
            case .bullet: marker = "* "
            case .dash: marker = "- "
            case .numbered: marker = "\(number). "
            case .checklist: marker = "- [ ] "
            }
            // Keep the box of an item that was ticked already when switching between check lists.
            let done = p.kind == .check && p.marker.lowercased().contains("[x]")
            return p.indent + (kind == .checklist && done ? "- [x] " : marker) + p.content
        }
        return edit(ns, b, lines, caretAtEnd: single)
    }

    private static func quote(text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let b = block(ns, selection)
        let items = b.lines.map(parts)
        let filled = items.filter { !$0.content.isEmpty }
        let off = !filled.isEmpty && filled.allSatisfy { $0.kind == .quote }
        let single = b.lines.count == 1
        let lines = items.map { p -> String in
            if p.content.isEmpty && !single { return p.indent }
            return off ? p.indent + p.content : p.indent + "> " + p.content
        }
        return edit(ns, b, lines, caretAtEnd: single)
    }

    /// The continuation of a list or quote when Return is pressed at the end of one of its lines: the next marker,
    /// or, on an empty item, the end of the list (the marker is removed). Nil when the line is not a list line.
    static func returnEdit(text: String, caret: Int) -> TextEdit? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 10 { contentEnd -= 1 }
        guard caret == contentEnd else { return nil }
        let line = ns.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        let p = parts(line)
        guard [.bullet, .dash, .numbered, .check, .quote].contains(p.kind) else { return nil }
        if p.content.trimmingCharacters(in: .whitespaces).isEmpty {
            let range = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            return TextEdit(range: range, text: "", selection: NSRange(location: range.location, length: 0))
        }
        var next = p.marker
        if p.kind == .numbered, let n = Int(p.marker.prefix { $0.isNumber }) { next = "\(n + 1). " }
        if p.kind == .check { next = p.marker.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]") }
        let insert = "\n" + p.indent + next
        return TextEdit(range: NSRange(location: caret, length: 0), text: insert,
                        selection: NSRange(location: caret + (insert as NSString).length, length: 0))
    }

    // MARK: Check lists

    /// `- [ ] a` <-> `- [x] a`; nil if the line is not a check list item.
    static func toggledTask(_ line: String) -> (text: String, done: Bool)? {
        guard let regex = try? NSRegularExpression(pattern: "^(\\s*[-*+]\\s+)\\[( |x|X)\\](.*)$") else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let wasDone = ns.substring(with: m.range(at: 2)) != " "
        let text = ns.substring(with: m.range(at: 1)) + (wasDone ? "[ ]" : "[x]") + ns.substring(with: m.range(at: 3))
        return (text, !wasDone)
    }

    /// Moves the check list item at `index` behind the last item of the run of check list lines it belongs to.
    static func movingTaskToEnd(of lines: [String], at index: Int) -> [String] {
        func isTask(_ s: String) -> Bool { toggledTask(s) != nil }
        var end = index
        while end + 1 < lines.count, isTask(lines[end + 1]) { end += 1 }
        guard end > index else { return lines }
        var result = lines
        let item = result.remove(at: index)
        result.insert(item, at: end)
        return result
    }

    // MARK: Rule

    private static func rule(text: String, selection: NSRange) -> TextEdit? {
        // A line of text followed directly by --- would be a heading, so a blank line goes in between.
        insertBlock("---", text: text, selection: selection)
    }

    // MARK: Inline styles

    private static func isWordChar(_ c: unichar) -> Bool {
        guard let u = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(u) || c == 95
    }

    /// The selection, or the word around the caret when nothing is selected.
    private static func target(_ ns: NSString, _ selection: NSRange) -> NSRange {
        var sel = NSRange(location: min(selection.location, ns.length), length: selection.length)
        sel.length = min(sel.length, ns.length - sel.location)
        guard sel.length == 0 else { return sel }
        var a = sel.location, z = sel.location
        while a > 0, isWordChar(ns.character(at: a - 1)) { a -= 1 }
        while z < ns.length, isWordChar(ns.character(at: z)) { z += 1 }
        return NSRange(location: a, length: z - a)
    }

    private static func run(of ch: unichar, in ns: NSString, from: Int, step: Int) -> Int {
        var n = 0
        var i = from
        while i >= 0, i < ns.length, ns.character(at: i) == ch { n += 1; i += step }
        return n
    }

    private static func inline(_ kind: InlineKind, text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        var inner = target(ns, selection)
        switch kind {
        case .bold, .italic:
            // Asterisks inside the selection belong to the formatting too: step inside them first.
            let star: unichar = 42
            let lead = run(of: star, in: ns, from: inner.location, step: 1)
            let trail = run(of: star, in: ns, from: NSMaxRange(inner) - 1, step: -1)
            let k = min(lead, trail, max(0, (inner.length - 1) / 2))
            if k > 0 { inner = NSRange(location: inner.location + k, length: inner.length - 2 * k) }
            let left = run(of: star, in: ns, from: inner.location - 1, step: -1)
            let right = run(of: star, in: ns, from: NSMaxRange(inner), step: 1)
            let n = min(left, right)
            let width = kind == .bold ? 2 : 1
            let on = kind == .bold ? n >= 2 : n % 2 == 1
            let marker = String(repeating: "*", count: width)
            let body = ns.substring(with: inner)
            if on {
                let outer = NSRange(location: inner.location - width, length: inner.length + 2 * width)
                return TextEdit(range: outer, text: body, selection: NSRange(location: outer.location, length: inner.length))
            }
            return wrap(ns, inner, open: marker, close: marker)
        case .underline:
            return toggleTag(ns, inner, open: "<u>", close: "</u>")
        case .strike:
            return toggleTag(ns, inner, open: "~~", close: "~~")
        }
    }

    /// Adds `open`/`close` around the text, or takes them away when they are already there (outside or inside the selection).
    private static func toggleTag(_ ns: NSString, _ range: NSRange, open: String, close: String) -> TextEdit? {
        var inner = range
        let o = (open as NSString).length, c = (close as NSString).length
        let selected = ns.substring(with: inner)
        if selected.hasPrefix(open), selected.hasSuffix(close), inner.length >= o + c {
            inner = NSRange(location: inner.location + o, length: inner.length - o - c)
        }
        if inner.location >= o, NSMaxRange(inner) + c <= ns.length,
           ns.substring(with: NSRange(location: inner.location - o, length: o)) == open,
           ns.substring(with: NSRange(location: NSMaxRange(inner), length: c)) == close {
            let outer = NSRange(location: inner.location - o, length: inner.length + o + c)
            return TextEdit(range: outer, text: ns.substring(with: inner), selection: NSRange(location: outer.location, length: inner.length))
        }
        return wrap(ns, inner, open: open, close: close)
    }

    private static func wrap(_ ns: NSString, _ range: NSRange, open: String, close: String) -> TextEdit {
        let body = ns.substring(with: range)
        let o = (open as NSString).length
        return TextEdit(range: range, text: open + body + close,
                        selection: NSRange(location: range.location + o, length: range.length))
    }

    // MARK: Highlight

    private static let markPattern = try! NSRegularExpression(pattern: "<mark class=\"(violet|pink|orange|mint|blue)\">$")

    private static func highlight(_ color: String?, text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        var inner = target(ns, selection)
        let close = "</mark>"
        // The selection itself may include the tags.
        let selected = ns.substring(with: inner)
        if selected.hasSuffix(close), let m = openTag(in: selected, anchoredAtStart: true) {
            inner = NSRange(location: inner.location + m.length, length: inner.length - m.length - (close as NSString).length)
        }
        // Tags just outside the selection.
        let head = ns.substring(to: inner.location)
        if let m = markPattern.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)),
           ns.substring(from: NSMaxRange(inner)).hasPrefix(close) {
            let current = (head as NSString).substring(with: m.range(at: 1))
            let outer = NSRange(location: m.range.location, length: m.range.length + inner.length + (close as NSString).length)
            let body = ns.substring(with: inner)
            if color == nil || color == current {
                return TextEdit(range: outer, text: body, selection: NSRange(location: outer.location, length: inner.length))
            }
            let open = "<mark class=\"\(color!)\">"
            return TextEdit(range: outer, text: open + body + close,
                            selection: NSRange(location: outer.location + (open as NSString).length, length: inner.length))
        }
        guard let color, inner.length > 0 else { return nil }
        return wrap(ns, inner, open: "<mark class=\"\(color)\">", close: close)
    }

    private static func openTag(in s: String, anchoredAtStart: Bool) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: "^<mark class=\"(violet|pink|orange|mint|blue)\">") else { return nil }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range
    }

    // MARK: Tables

    private struct TableSpan {
        var range: NSRange          // the whole table, without the last line break
        var rows: [[String]]        // header first, the separator row left out
        var row: Int                // the caret's row in `rows` (the separator counts as the header)
        var column: Int
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|") && t.allSatisfy { "|-: ".contains($0) }
    }

    /// The table the caret is in: a run of lines with `|` whose second line is the `---` separator.
    private static func tableAt(_ ns: NSString, caret: Int) -> TableSpan? {
        var lineRanges: [NSRange] = []
        var pos = 0
        while pos <= ns.length {
            let r = ns.lineRange(for: NSRange(location: pos, length: 0))
            lineRanges.append(r)
            if NSMaxRange(r) >= ns.length { break }
            pos = NSMaxRange(r)
        }
        func content(_ r: NSRange) -> String {
            var end = NSMaxRange(r)
            if end > r.location, ns.character(at: end - 1) == 10 { end -= 1 }
            return ns.substring(with: NSRange(location: r.location, length: end - r.location))
        }
        func contentEnd(_ r: NSRange) -> Int {
            var end = NSMaxRange(r)
            if end > r.location, ns.character(at: end - 1) == 10 { end -= 1 }
            return end
        }
        guard let current = lineRanges.firstIndex(where: { caret >= $0.location && caret <= contentEnd($0) }) else { return nil }
        func isRow(_ i: Int) -> Bool { content(lineRanges[i]).contains("|") }
        guard isRow(current) else { return nil }
        var first = current, last = current
        while first > 0, isRow(first - 1) { first -= 1 }
        while last + 1 < lineRanges.count, isRow(last + 1) { last += 1 }
        guard first + 1 <= last, isSeparator(content(lineRanges[first + 1])) else { return nil }
        let rows = (first...last).filter { $0 != first + 1 }.map { cells(content(lineRanges[$0])) }
        var endLoc = NSMaxRange(lineRanges[last])
        if endLoc > 0, endLoc <= ns.length, ns.character(at: endLoc - 1) == 10 { endLoc -= 1 }
        let range = NSRange(location: lineRanges[first].location, length: endLoc - lineRanges[first].location)
        let rowIndex = current == first + 1 ? 0 : (current < first + 1 ? 0 : current - first - 1)
        let lineText = content(lineRanges[current]) as NSString
        let before = lineText.substring(to: min(max(caret - lineRanges[current].location, 0), lineText.length))
        var column = before.filter { $0 == "|" }.count
        if content(lineRanges[current]).trimmingCharacters(in: .whitespaces).hasPrefix("|") { column -= 1 }
        return TableSpan(range: range, rows: rows, row: rowIndex, column: max(0, column))
    }

    private static func render(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 1
        let grid = rows.map { r in (0..<columns).map { $0 < r.count ? r[$0] : "" } }
        var widths = [Int](repeating: 3, count: columns)
        for r in grid { for (c, cell) in r.enumerated() { widths[c] = max(widths[c], cell.count) } }
        func line(_ r: [String]) -> String {
            "| " + r.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }.joined(separator: " | ") + " |"
        }
        var out = [line(grid[0]), "| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |"]
        out += grid.dropFirst().map(line)
        return out.joined(separator: "\n")
    }

    private static func table(_ command: TableCommand, text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        if command == .insert { return insertTable(ns, selection) }
        guard var span = tableAt(ns, caret: selection.location) else { return nil }
        let columns = span.rows.map(\.count).max() ?? 1
        func pad(_ r: [String]) -> [String] { r + [String](repeating: "", count: max(0, columns - r.count)) }
        span.rows = span.rows.map(pad)
        let col = min(span.column, columns - 1)
        switch command {
        case .insert: return nil
        case .addRow:
            span.rows.insert([String](repeating: "", count: columns), at: min(span.row, span.rows.count - 1) + 1)
        case .addColumn:
            span.rows = span.rows.enumerated().map { r in
                var row = r.element
                row.insert(r.offset == 0 ? "Колонка" : "", at: col + 1)
                return row
            }
        case .deleteRow:
            guard span.row > 0, span.rows.count > 2 else { return nil }
            span.rows.remove(at: span.row)
        case .deleteColumn:
            guard columns > 1 else { return nil }
            span.rows = span.rows.map { var r = $0; r.remove(at: col); return r }
        case .moveRowUp:
            guard span.row > 1 else { return nil }
            span.rows.swapAt(span.row, span.row - 1)
        case .moveRowDown:
            guard span.row > 0, span.row + 1 < span.rows.count else { return nil }
            span.rows.swapAt(span.row, span.row + 1)
        case .moveColumnLeft:
            guard col > 0 else { return nil }
            span.rows = span.rows.map { var r = $0; r.swapAt(col, col - 1); return r }
        case .moveColumnRight:
            guard col + 1 < columns else { return nil }
            span.rows = span.rows.map { var r = $0; r.swapAt(col, col + 1); return r }
        case .toText:
            let plain = span.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            return TextEdit(range: span.range, text: plain, selection: NSRange(location: span.range.location, length: (plain as NSString).length))
        }
        let rendered = render(span.rows)
        return TextEdit(range: span.range, text: rendered,
                        selection: NSRange(location: span.range.location, length: (rendered as NSString).length))
    }

    private static func insertTable(_ ns: NSString, _ selection: NSRange) -> TextEdit? {
        let rows = [["Колонка 1", "Колонка 2", "Колонка 3"], ["", "", ""], ["", "", ""]]
        let table = render(rows)
        let caret = min(selection.location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 10 { contentEnd -= 1 }
        let line = ns.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            let r = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            return TextEdit(range: r, text: table + "\n", selection: NSRange(location: r.location + 2, length: 9))
        }
        let insert = "\n\n" + table + "\n"
        return TextEdit(range: NSRange(location: contentEnd, length: 0), text: insert,
                        selection: NSRange(location: contentEnd + 4, length: 9))
    }

    /// Whether the caret is inside a Markdown table (the table commands need that).
    static func isInTable(text: String, caret: Int) -> Bool { tableAt(text as NSString, caret: caret) != nil }
}

extension RichFormat {
    /// Ticking the check box at `boxIndex` (the character between the brackets). With `moveDone`, a ticked item moves to the end
    /// of its list; the edit then covers the lines that change.
    static func toggleTaskEdit(text: String, boxIndex: Int, moveDone: Bool) -> TextEdit? {
        let ns = text as NSString
        guard boxIndex >= 0, boxIndex < ns.length else { return nil }
        let lines = text.components(separatedBy: "\n")
        let lineIndex = ns.substring(to: boxIndex).filter { $0 == "\n" }.count
        guard lines.indices.contains(lineIndex), let toggled = toggledTask(lines[lineIndex]) else { return nil }
        var new = lines
        new[lineIndex] = toggled.text
        if toggled.done && moveDone { new = movingTaskToEnd(of: new, at: lineIndex) }
        guard let first = lines.indices.first(where: { lines[$0] != new[$0] }),
              let last = lines.indices.last(where: { lines[$0] != new[$0] }) else { return nil }
        let start = lines[..<first].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let length = lines[first...last].reduce(0) { $0 + ($1 as NSString).length } + (last - first)
        let replacement = new[first...last].joined(separator: "\n")
        return TextEdit(range: NSRange(location: start, length: length), text: replacement,
                        selection: NSRange(location: start, length: (replacement as NSString).length))
    }

    /// Formatting marks with nothing between them (left behind when the last character of a bold word is deleted).
    static func emptyMarks(in text: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: "\\*\\*\\*\\*|~~~~|<u></u>|<mark class=\"(?:violet|pink|orange|mint|blue)\"></mark>") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { r in
            // A line made of only `****` is a divider, not an empty bold.
            let line = ns.substring(with: ns.lineRange(for: r)).trimmingCharacters(in: .whitespacesAndNewlines)
            return line != "****"
        }
    }
}
