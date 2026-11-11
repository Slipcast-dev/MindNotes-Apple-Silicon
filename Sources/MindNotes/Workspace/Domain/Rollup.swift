import Foundation

/// Агрегат свёртки. Строка: агрегат из более новой версии сохраняется, свёртка просто не считается.
struct RollupAggregate: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let count = RollupAggregate(rawValue: "count")
    static let countValues = RollupAggregate(rawValue: "count_values")
    static let countUnique = RollupAggregate(rawValue: "count_unique")
    static let countEmpty = RollupAggregate(rawValue: "count_empty")
    static let percentEmpty = RollupAggregate(rawValue: "percent_empty")
    static let sum = RollupAggregate(rawValue: "sum")
    static let average = RollupAggregate(rawValue: "average")
    static let median = RollupAggregate(rawValue: "median")
    static let min = RollupAggregate(rawValue: "min")
    static let max = RollupAggregate(rawValue: "max")
    static let range = RollupAggregate(rawValue: "range")
    static let earliest = RollupAggregate(rawValue: "earliest")
    static let latest = RollupAggregate(rawValue: "latest")
    static let dateRange = RollupAggregate(rawValue: "date_range")
    static let percentChecked = RollupAggregate(rawValue: "percent_checked")
    static let showOriginal = RollupAggregate(rawValue: "show_original")

    private static let general: [RollupAggregate] = [.count, .countValues, .countUnique, .countEmpty, .percentEmpty, .showOriginal]
    private static let numeric: [RollupAggregate] = [.sum, .average, .median, .min, .max, .range]
    private static let dates: [RollupAggregate] = [.earliest, .latest, .dateRange]

    /// Агрегаты, допустимые для значения целевого свойства: единственное место, задающее сочетания.
    static func available(for valueType: PropertyType) -> [RollupAggregate] {
        switch valueType {
        case .number: return general + numeric
        case .date, .createdTime: return general + dates
        case .checkbox: return general + [.percentChecked]
        default: return general
        }
    }

    /// Тип результата: от него зависят хранение, фильтры и сортировка.
    var resultType: PropertyType? {
        switch self {
        case .earliest, .latest: return .date
        case .showOriginal: return .text
        case .count, .countValues, .countUnique, .countEmpty, .percentEmpty, .sum, .average, .median, .min, .max, .range, .dateRange, .percentChecked:
            return .number
        default: return nil
        }
    }

    /// Пустой набор даёт 0 только для счётчиков и суммы: у среднего или минимума ничего нет.
    var zeroWhenEmpty: Bool { [.count, .countValues, .countUnique, .countEmpty, .sum].contains(self) }
}

enum RollupLimits {
    /// Свёртка свёртки: длина цепочки ограничена, чтобы пересчёт не уходил вглубь без конца.
    static let maxChain = 16
    /// Текст «показать значения» не растёт без предела.
    static let maxText = 64 * 1024
}

/// Вычисление свёртки над значениями связанных записей. Без хранилища: проверяется отдельно.
enum RollupMath {
    /// Снятый флажок — пусто, как и отсутствие значения: иначе «пустых» у флажка всегда 0.
    static func isEmpty(_ value: PropertyValue?) -> Bool {
        switch value {
        case nil, .checkbox(false)?: return true
        case .text(let s)?, .url(let s)?: return s.isEmpty
        case .options(let ids)?: return ids.isEmpty
        case .relation(let links)?: return links.isEmpty
        case .people(let people)?: return people.isEmpty
        case .files(let files)?: return files.isEmpty
        default: return false
        }
    }

    static func number(_ value: PropertyValue?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    /// Начало и конец значения даты в мс для сравнения. День считается полуднем UTC: сравниваются дни, а не пояса.
    private static func bounds(_ value: PropertyValue?) -> (start: DatePoint, end: DatePoint)? {
        switch value {
        case .date(let d)?: return (d.start, d.end ?? d.start)
        case .time(let ms)?: let p = DatePoint.moment(ms: ms, zone: TimeZone.current.identifier); return (p, p)
        default: return nil
        }
    }

    /// Ключ сравнения: момент сравнивается по времени, день — по своему полудню в поясе пользователя.
    private static func key(_ point: DatePoint) -> Int64 {
        switch point {
        case .moment(let ms, _): return ms
        case .day(let d): return Int64(d.date(in: .current).timeIntervalSince1970 * 1000)
        }
    }

    private static func rounded(_ n: Double) -> Double { (n * 100).rounded() / 100 }

    /// `values` — значения целевого свойства у каждой связанной записи, nil у пустых.
    static func compute(_ aggregate: RollupAggregate, values: [PropertyValue?], options: [PropertyOption] = []) -> PropertyValue? {
        let filled = values.filter { !isEmpty($0) }
        let numbers = values.compactMap(number)
        switch aggregate {
        case .count: return .number(Double(values.count))
        case .countValues: return .number(Double(filled.count))
        case .countEmpty: return .number(Double(values.count - filled.count))
        case .countUnique:
            return .number(Double(Set(filled.compactMap { $0.map { PropertyConversion.text(of: $0, options: options) } }).count))
        case .percentEmpty:
            guard !values.isEmpty else { return nil }
            return .number(rounded(Double(values.count - filled.count) * 100 / Double(values.count)))
        case .percentChecked:
            guard !values.isEmpty else { return nil }
            let checked = values.filter { if case .checkbox(true)? = $0 { return true } else { return false } }.count
            return .number(rounded(Double(checked) * 100 / Double(values.count)))
        case .sum: return .number(numbers.reduce(0, +))
        case .average: return numbers.isEmpty ? nil : .number(rounded(numbers.reduce(0, +) / Double(numbers.count)))
        case .median:
            guard !numbers.isEmpty else { return nil }
            let sorted = numbers.sorted(), mid = sorted.count / 2
            return .number(sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2)
        case .min: return numbers.min().map { .number($0) }
        case .max: return numbers.max().map { .number($0) }
        case .range:
            guard let lo = numbers.min(), let hi = numbers.max() else { return nil }
            return .number(hi - lo)
        case .earliest:
            return values.compactMap(bounds).map(\.start).min { key($0) < key($1) }.map { .date(DateValue(start: $0)) }
        case .latest:
            return values.compactMap(bounds).map(\.end).max { key($0) < key($1) }.map { .date(DateValue(start: $0)) }
        case .dateRange:
            let all = values.compactMap(bounds)
            guard let first = all.map(\.start).min(by: { key($0) < key($1) }), let last = all.map(\.end).max(by: { key($0) < key($1) }) else { return nil }
            return .number(Double(first.localDay.days(to: last.localDay)))
        case .showOriginal:
            let text = filled.compactMap { $0.map { PropertyConversion.text(of: $0, options: options) } }.joined(separator: ", ")
            guard !text.isEmpty else { return nil }
            return .text(text.count > RollupLimits.maxText ? String(text.prefix(RollupLimits.maxText)) + "…" : text)
        default: return nil
        }
    }
}
