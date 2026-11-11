import Foundation

/// Чтение и запись CSV (RFC 4180) с выбором разделителя.
enum CSV {
    static let delimiters: [Character] = [",", ";", "\t"]

    /// Поля в кавычках могут содержать разделитель, перенос строки и удвоенную кавычку. Пустые строки пропускаются.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        let delimiterScalar = delimiter.unicodeScalars.first ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var wasQuoted = false
        // По скалярам: «\r\n» — один Character и иначе не распознаётся как конец строки.
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var i = 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            wasQuoted = false
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while i < scalars.count {
            let c = scalars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"", field.isEmpty, !wasQuoted {
                quoted = true
                wasQuoted = true
            } else if c == delimiterScalar {
                endField()
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty || wasQuoted { endRow() }
        return rows
    }

    static func write(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { row in
            row.map { field -> String in
                let needsQuotes = field.contains(delimiter) || field.contains("\"") || field.contains(where: \.isNewline)
                    || field.first?.isWhitespace == true || field.last?.isWhitespace == true
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: String(delimiter))
        }.joined(separator: "\r\n") + "\r\n"
    }

    /// Разделитель, который даёт больше всего столбцов при одинаковой ширине первых строк.
    static func detectDelimiter(_ text: String) -> Character {
        let sample = String(text.prefix(20_000))
        var best: (Character, Int) = (",", 0)
        for candidate in delimiters {
            let rows = parse(sample, delimiter: candidate).prefix(10)
            guard let width = rows.first?.count, width > 1 else { continue }
            let consistent = rows.dropLast().allSatisfy { $0.count == width }
            if consistent, width > best.1 { best = (candidate, width) }
        }
        return best.0
    }
}
