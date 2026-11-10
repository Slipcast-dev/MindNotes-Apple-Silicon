import Foundation

/// CSV в новую базу (FR-14.2): первый столбец — заголовок записи, тип остальных угадывается и меняется в предпросмотре.
enum CSVImport {
    struct Plan: Equatable {
        var headers: [String]
        var rows: [[String]]
        /// Тип каждого столбца; у первого всегда заголовок.
        var types: [PropertyType]
    }

    struct Built {
        var properties: [PropertyDefinition]
        var records: [ImportedRecord]
        /// Значения, которые не подошли к типу столбца: они сохранены как есть и видны в записи.
        var unconverted: Int
    }

    static let maxColumns = 200

    static func plan(_ table: [[String]], hasHeader: Bool, zone: String) -> Plan {
        let width = min(maxColumns, max(1, table.map(\.count).max() ?? 1))
        let body = (hasHeader ? Array(table.dropFirst()) : table).map { row in (0..<width).map { $0 < row.count ? row[$0] : "" } }
        var used: Set<String> = []
        let headers = (0..<width).map { i -> String in
            let raw = hasHeader && i < (table.first?.count ?? 0) ? table[0][i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var name = raw.isEmpty ? String(format: NSLocalizedString("Столбец %d", comment: ""), i + 1) : raw
            var n = 1
            let base = name
            while used.contains(SearchText.normalize(name)) { n += 1; name = "\(base) \(n)" }
            used.insert(SearchText.normalize(name))
            return name
        }
        let types = (0..<width).map { i in i == 0 ? PropertyType.title : guessType(body.map { $0[i] }, zone: zone) }
        return Plan(headers: headers, rows: body, types: types)
    }

    /// Тип по непустым значениям: все должны подойти. Выбор — если вариантов мало и они повторяются.
    static func guessType(_ values: [String], zone: String) -> PropertyType {
        let filled = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return .text }
        let numeric = filled.allSatisfy { PropertyParse.number($0) != nil }
        if !numeric, filled.allSatisfy({ PropertyParse.checkbox($0) != nil }) { return .checkbox }
        if numeric { return .number }
        if filled.allSatisfy({ PropertyParse.date($0, zone: zone) != nil }) { return .date }
        if filled.allSatisfy({ $0.contains("://") && PropertyParse.url($0) != nil }) { return .url }
        let distinct = Set(filled.map(SearchText.normalize))
        if filled.contains(where: { $0.contains(", ") }) {
            let items = Set(filled.flatMap { $0.components(separatedBy: ",") }.map { SearchText.normalize($0.trimmingCharacters(in: .whitespaces)) })
            if items.count <= 30, filled.allSatisfy({ $0.count <= 200 }) { return .multiSelect }
            return .text
        }
        if distinct.count <= 12, distinct.count * 2 <= filled.count, filled.allSatisfy({ $0.count <= 60 }) { return .select }
        return .text
    }

    static func build(_ plan: Plan, zone: String, ids: IDGenerator) -> Built {
        var properties = plan.headers.enumerated().map { i, name in
            PropertyDefinition(id: ids.next(), databaseID: UUID(), name: name, type: plan.types[i], sortKey: "")
        }
        var unconverted = 0
        var records: [ImportedRecord] = []
        for row in plan.rows {
            var values: [UUID: PropertyValue] = [:]
            for i in 1..<max(1, properties.count) {
                let raw = row[i]
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var options = properties[i].options
                let value = PropertyConversion.convert(raw, to: properties[i].type, options: &options, zone: zone) { name in
                    PropertyOption(id: ids.next(), name: name, color: nil, sortKey: "")
                }
                properties[i].options = options
                if case .unconverted = value { unconverted += 1 }
                values[properties[i].id] = value
            }
            records.append(ImportedRecord(id: ids.next(), title: row[0].trimmingCharacters(in: .whitespacesAndNewlines), values: values))
        }
        return Built(properties: properties, records: records, unconverted: unconverted)
    }
}
