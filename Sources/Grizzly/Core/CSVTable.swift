import Foundation

/// A CSV/TSV file split into cells. Row `i` is line `i` of the document, so search and scrolling
/// keep using line numbers as units (a quoted field with a line break is not supported).
struct CSVTable {
    struct Row {
        let line: String
        let cells: [String]
        /// Character offset of each cell inside the original line.
        let starts: [Int]
    }

    let rows: [Row]
    let widths: [Int]

    init(lines: [String], delimiter: Character) {
        var parsed: [Row] = []
        parsed.reserveCapacity(lines.count)
        var end = lines.count
        while end > 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        for line in lines[..<end] { parsed.append(CSVTable.parse(line, delimiter: delimiter)) }
        rows = parsed

        let columns = parsed.map(\.cells.count).max() ?? 0
        var w = [Int](repeating: 3, count: columns)
        for row in parsed.prefix(500) {
            for (i, cell) in row.cells.enumerated() { w[i] = min(40, max(w[i], cell.count)) }
        }
        widths = w
    }

    static func detectDelimiter(url: URL, lines: [String]) -> Character {
        if url.pathExtension.lowercased() == "tsv" { return "\t" }
        let sample = lines.prefix(5).joined(separator: "\n")
        let candidates: [Character] = [",", ";", "\t", "|"]
        func count(_ d: Character) -> Int { sample.filter { $0 == d }.count }
        return candidates.max { count($0) < count($1) } ?? ","
    }

    private static func parse(_ line: String, delimiter: Character) -> Row {
        var cells: [String] = []
        var starts: [Int] = []
        var current = ""
        var inQuotes = false
        var cellStart = 0
        let chars = Array(line)
        let n = chars.count
        var i = 0

        while i < n {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < n && chars[i + 1] == "\"" { current.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    current.append(c)
                }
            } else if c == "\"" && current.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                cells.append(current); starts.append(cellStart)
                current = ""; cellStart = i + 1
            } else {
                current.append(c)
            }
            i += 1
        }
        cells.append(current); starts.append(cellStart)
        return Row(line: line, cells: cells, starts: starts)
    }
}
