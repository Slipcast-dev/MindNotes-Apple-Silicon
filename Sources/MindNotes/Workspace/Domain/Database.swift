import Foundation

/// Тип свойства. Строка, а не закрытый enum: тип из более новой версии сохраняется и показывается только для чтения.
struct PropertyType: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let title = PropertyType(rawValue: "title")
    static let text = PropertyType(rawValue: "text")
    static let number = PropertyType(rawValue: "number")
    static let date = PropertyType(rawValue: "date")
    static let checkbox = PropertyType(rawValue: "checkbox")
    static let status = PropertyType(rawValue: "status")
    static let select = PropertyType(rawValue: "select")
    static let multiSelect = PropertyType(rawValue: "multi_select")
    static let url = PropertyType(rawValue: "url")
    /// Связь с записями другой или той же базы.
    static let relation = PropertyType(rawValue: "relation")
    /// Время создания и последнего изменения записи: берутся из страницы, вручную не меняются.
    static let createdTime = PropertyType(rawValue: "created_time")
    static let editedTime = PropertyType(rawValue: "edited_time")
    /// Свёртка: агрегат значений связанных записей. Хранится готовым значением и пересчитывается по зависимостям.
    static let rollup = PropertyType(rawValue: "rollup")
    /// Формула: вычисляется из свойств своей записи, хранится готовым значением.
    static let formula = PropertyType(rawValue: "formula")
    /// Человек: один или несколько людей из справочника пространства.
    static let person = PropertyType(rawValue: "person")
    /// Файлы и медиа: список вложений пространства в порядке ячейки.
    static let files = PropertyType(rawValue: "files")

    /// Типы, которые можно выбрать; заголовок у базы один и создаётся вместе с ней.
    static let creatable: [PropertyType] = [.text, .number, .date, .checkbox, .status, .select, .multiSelect, .url, .person, .files, .relation, .rollup, .formula, .createdTime, .editedTime]
    /// Типы с собственными значениями, между которыми возможна смена типа с предпросмотром.
    static let convertible: [PropertyType] = [.text, .number, .date, .checkbox, .status, .select, .multiSelect, .url]
    var isKnown: Bool { self == .title || Self.creatable.contains(self) }
    var usesOptions: Bool { self == .status || self == .select || self == .multiSelect }
    /// Значение вычисляется из страницы: правка вручную невозможна.
    var isComputed: Bool { self == .createdTime || self == .editedTime || self == .rollup || self == .formula }
    var isTimestamp: Bool { self == .createdTime || self == .editedTime }
}

/// Настройки свойства, которые не умещаются в тип. Неизвестные поля более новой версии сохраняются.
struct PropertyConfig: Equatable {
    /// Связь: база, на записи которой она указывает.
    var target: UUID?
    /// Связь: парное свойство в целевой базе. nil — связь односторонняя.
    var pair: UUID?
    /// Обратная сторона двусторонней связи: строки хранятся под парным (прямым) свойством.
    var isBackSide = false
    /// Свёртка: связь этой базы, свойство связанных записей и агрегат.
    var rollupRelation: UUID?
    var rollupProperty: UUID?
    var aggregate: RollupAggregate?
    /// Формула: текст со ссылками по ID и тип результата, проверенный при сохранении.
    var formula: String?
    var formulaType: FormulaType?
    var extra: [String: JSONValue] = [:]

    private struct Known: Codable {
        var target: UUID?
        var pair: UUID?
        var back: Bool?
        var relation: UUID?
        var property: UUID?
        var aggregate: RollupAggregate?
        var formula: String?
        var result: FormulaType?
    }

    static func rollup(relation: UUID, property: UUID, aggregate: RollupAggregate) -> PropertyConfig {
        var config = PropertyConfig()
        config.rollupRelation = relation
        config.rollupProperty = property
        config.aggregate = aggregate
        return config
    }

    init(target: UUID? = nil, pair: UUID? = nil, isBackSide: Bool = false) {
        self.target = target
        self.pair = pair
        self.isBackSide = isBackSide
    }

    /// Испорченные настройки дают пустые: свойство показывается, но связь не читается.
    init(json: String?) {
        guard let json, let data = json.data(using: .utf8), case .object(var object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if let known = try? JSONDecoder().decode(Known.self, from: data) {
            target = known.target
            pair = known.pair
            isBackSide = known.back ?? false
            rollupRelation = known.relation
            rollupProperty = known.property
            aggregate = known.aggregate
            formula = known.formula
            formulaType = known.result
            for key in ["target", "pair", "back", "relation", "property", "aggregate", "formula", "result"] { object[key] = nil }
        }
        extra = object
    }

    var isEmpty: Bool { target == nil && pair == nil && !isBackSide && rollupRelation == nil && rollupProperty == nil && aggregate == nil && formula == nil && formulaType == nil && extra.isEmpty }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let known = try encoder.encode(Known(target: target, pair: pair, back: isBackSide ? true : nil, relation: rollupRelation, property: rollupProperty, aggregate: aggregate,
                                                    formula: formula, result: formulaType))
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: known) else { return "{}" }
        return String(decoding: try encoder.encode(JSONValue.object(extra.merging(fields) { _, new in new })), as: UTF8.self)
    }
}

/// Связанная запись: ID и то, что нужно для показа без отдельного чтения.
struct LinkedPage: Hashable, Identifiable {
    var id: UUID
    var title: String
    var icon: String? = nil
}

enum RelationLimits {
    /// Предел связей в одной ячейке: защита от случайной массовой вставки.
    static let maxLinks = 1000
}

/// Человек из справочника пространства (M10). Справочник общий для всех баз: свойство «Человек» хранит только ID.
struct Person: Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Имя цвета из палитры вариантов (`PropertyColor`); nil — серый.
    var color: String? = nil
    var emoji: String? = nil
    var sortKey: String = ""

    /// Подпись в ячейке и экспорте: эмодзи перед именем, если есть.
    var label: String { (emoji.map { $0 + " " } ?? "") + name }
}

/// Файл свойства «Файлы и медиа»: вложение из общего хранилища и его исходное имя.
struct AttachedFile: Hashable, Identifiable {
    /// ID вложения (`assets.id`).
    var id: UUID
    var name: String

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
    var isImage: Bool { Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) }
}

enum FileLimits {
    /// Предел файлов в одной ячейке.
    static let maxPerValue = 100
}

enum PeopleLimits {
    /// Предел людей в одной ячейке и длины имени.
    static let maxPerValue = 200
    static let maxName = 200
}

/// Вариант выбора. Постоянный ID: переименование не меняет значения записей.
struct PropertyOption: Equatable, Identifiable {
    var id: UUID
    var name: String
    var color: String?
    var sortKey: String
}

struct PropertyDefinition: Equatable, Identifiable {
    var id: UUID
    var databaseID: UUID
    var name: String
    var type: PropertyType
    var sortKey: String
    var options: [PropertyOption] = []
    var config = PropertyConfig()

    /// Свойство, под которым хранятся строки связи: у обратной стороны — парное.
    var linkOwner: UUID { config.isBackSide ? (config.pair ?? id) : id }

    /// Тип хранимого значения: у свёртки — тип её результата, у остальных — сам тип.
    /// По нему работают фильтры, сортировка и показ.
    var valueType: PropertyType {
        if type == .formula {
            switch config.formulaType {
            case .number?: return .number
            case .text?: return .text
            case .bool?: return .checkbox
            case .date?: return .date
            case nil: return type
            }
        }
        guard type == .rollup else { return type }
        return config.aggregate?.resultType ?? type
    }
}

/// Дата без времени. Хранится строкой, поэтому смена часового пояса не сдвигает день.
struct LocalDate: Hashable, Comparable {
    let year: Int, month: Int, day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= lengths[month - 1] else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Только полная форма `ГГГГ-ММ-ДД` с существующим днём.
    init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// День, который показывают часы в этом поясе.
    init(date: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 1
        month = c.month ?? 1
        day = c.day ?? 1
    }

    /// Полдень этого дня: для календарей и форматтеров, смена летнего времени его не сдвигает.
    func date(in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private var utcDate: Date { Self.utc.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0) }

    /// Счёт идёт в UTC, где нет перехода на летнее время: день не теряется.
    func adding(days: Int) -> LocalDate {
        LocalDate(date: Self.utc.date(byAdding: .day, value: days, to: utcDate) ?? utcDate, in: TimeZone(secondsFromGMT: 0) ?? .current)
    }

    func days(to other: LocalDate) -> Int {
        Self.utc.dateComponents([.day], from: utcDate, to: other.utcDate).day ?? 0
    }

    /// Понедельник = 0 … воскресенье = 6.
    var weekdayFromMonday: Int { (Self.utc.component(.weekday, from: utcDate) + 5) % 7 }
    var firstOfMonth: LocalDate { LocalDate(year: year, month: month, day: 1) ?? self }

    func addingMonths(_ count: Int) -> LocalDate {
        LocalDate(date: Self.utc.date(byAdding: .month, value: count, to: utcDate) ?? utcDate, in: TimeZone(secondsFromGMT: 0) ?? .current)
    }

    static func < (a: LocalDate, b: LocalDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// Точка времени: день без пояса либо однозначный момент с поясом, в котором он был задан.
enum DatePoint: Hashable {
    case day(LocalDate)
    case moment(ms: Int64, zone: String)

    /// День, который показывают часы в собственном поясе значения.
    var localDay: LocalDate {
        switch self {
        case .day(let d): return d
        case .moment: return LocalDate(iso: String(localText.prefix(10))) ?? LocalDate(date: Date(timeIntervalSince1970: 0), in: .current)
        }
    }

    /// Настенное время в собственном поясе: `ГГГГ-ММ-ДД` или `ГГГГ-ММ-ДДTЧЧ:ММ`. Подходит для сравнения строк.
    var localText: String {
        switch self {
        case .day(let d): return d.iso
        case .moment(let ms, let zone):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0) ?? .current
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
            return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 1, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
        }
    }
}

struct DateValue: Hashable {
    var start: DatePoint
    var end: DatePoint?

    init(start: DatePoint, end: DatePoint? = nil) {
        self.start = start
        self.end = end
    }

    /// Перенос в календаре: длина диапазона и время суток сохраняются, день меняется точно на выбранный.
    func moved(toDay target: LocalDate) -> DateValue {
        switch start {
        case .day(let old):
            guard case .day(let oldEnd)? = end else { return DateValue(start: .day(target)) }
            return DateValue(start: .day(target), end: .day(target.adding(days: old.days(to: oldEnd))))
        case .moment(let ms, let zone):
            let tz = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0) ?? .current
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz
            let clock = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: Double(ms) / 1000))
            let moved = calendar.date(from: DateComponents(year: target.year, month: target.month, day: target.day, hour: clock.hour, minute: clock.minute, second: clock.second))
            let newMs = moved.map { Int64($0.timeIntervalSince1970 * 1000) } ?? ms
            guard case .moment(let endMs, _)? = end else { return DateValue(start: .moment(ms: newMs, zone: zone)) }
            return DateValue(start: .moment(ms: newMs, zone: zone), end: .moment(ms: newMs + (endMs - ms), zone: zone))
        }
    }

    /// Сдвиг на число дней: карточку диапазона можно взять за любой его день.
    func moved(byDays days: Int) -> DateValue { moved(toDay: start.localDay.adding(days: days)) }

    /// Диапазон: одного вида, в одном поясе, конец не раньше начала.
    var isValid: Bool {
        guard let end else { return true }
        switch (start, end) {
        case (.day(let a), .day(let b)): return a <= b
        case (.moment(let a, let z1), .moment(let b, let z2)): return z1 == z2 && a <= b
        default: return false
        }
    }
}

enum PropertyValue: Hashable {
    case text(String)
    case number(Double)
    case date(DateValue)
    case checkbox(Bool)
    /// Статус и одиночный выбор — один ID, множественный выбор — несколько.
    case options([UUID])
    case url(String)
    /// Прежнее значение, которое не удалось преобразовать при смене типа: не теряется и видно пользователю.
    case unconverted(String)
    /// Связанные записи в порядке связи. Записи из корзины не показываются.
    case relation([LinkedPage])
    /// Время создания или изменения записи, мс UTC.
    case time(Int64)
    /// Ошибка вычисления формулы в этой записи: видна в ячейке, значения нет.
    case error(String)
    /// Люди в порядке ячейки; имя и цвет — из справочника на момент чтения.
    case people([Person])
    /// Файлы в порядке ячейки.
    case files([AttachedFile])
}

/// Разбор пользовательского ввода и текста при смене типа.
enum PropertyParse {
    static func number(_ text: String) -> Double? {
        let clean = text.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard !clean.isEmpty, let value = Double(clean), value.isFinite else { return nil }
        return value
    }

    static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    static func checkbox(_ text: String) -> Bool? {
        switch SearchText.normalize(text.trimmingCharacters(in: .whitespaces)) {
        case "true", "да", "1", "yes": return true
        case "false", "нет", "0", "no": return false
        default: return nil
        }
    }

    /// Адрес без пробелов; открывать разрешено только эти схемы. Домен без схемы считается https.
    static func url(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(where: \.isWhitespace), openable(clean) != nil else { return nil }
        return clean
    }

    static func openable(_ text: String) -> URL? {
        // Кириллица в адресе допустима: кодируется только для открытия, сохраняется как введена.
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: ":?#&=%+,;@[]!$'()*")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed), let url = URL(string: encoded) else { return nil }
        if let scheme = url.scheme?.lowercased() {
            return ["http", "https", "mailto"].contains(scheme) ? url : nil
        }
        guard text.contains("."), !text.hasPrefix("."), !text.contains("/..") else { return nil }
        return URL(string: "https://\(encoded)")
    }

    /// `ГГГГ-ММ-ДД`, `ДД.ММ.ГГГГ`, диапазон через « — » и момент `ГГГГ-ММ-ДДTЧЧ:ММ`.
    static func date(_ text: String, zone: String) -> DateValue? {
        let parts = text.components(separatedBy: " — ")
        guard parts.count <= 2, let start = point(parts[0], zone: zone) else { return nil }
        let value = DateValue(start: start, end: parts.count == 2 ? point(parts[1], zone: zone) : nil)
        if parts.count == 2, value.end == nil { return nil }
        return value.isValid ? value : nil
    }

    private static func point(_ raw: String, zone: String) -> DatePoint? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let day = LocalDate(iso: text) { return .day(day) }
        let dotted = text.split(separator: ".", omittingEmptySubsequences: false)
        if dotted.count == 3, dotted[0].count <= 2, dotted[1].count <= 2, dotted[2].count == 4,
           let d = Int(dotted[0]), let m = Int(dotted[1]), let y = Int(dotted[2]), let day = LocalDate(year: y, month: m, day: d) {
            return .day(day)
        }
        let pieces = text.split(separator: "T")
        guard pieces.count == 2, let day = LocalDate(iso: String(pieces[0])), let tz = TimeZone(identifier: zone) else { return nil }
        let clock = pieces[1].split(separator: ":")
        guard clock.count == 2, let h = Int(clock[0]), let mi = Int(clock[1]), (0...23).contains(h), (0...59).contains(mi) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: h, minute: mi)) else { return nil }
        return .moment(ms: Int64(date.timeIntervalSince1970 * 1000), zone: zone)
    }
}

/// Смена типа свойства: значение → общий текст → новый тип. Неудача даёт `.unconverted`, значение не теряется.
enum PropertyConversion {
    static func text(of value: PropertyValue, options: [PropertyOption]) -> String {
        switch value {
        case .text(let s), .url(let s), .unconverted(let s): return s
        case .number(let n): return PropertyParse.numberText(n)
        case .checkbox(let b): return b ? "true" : "false"
        case .options(let ids): return ids.compactMap { id in options.first { $0.id == id }?.name }.joined(separator: ", ")
        case .date(let d): return d.end.map { "\(d.start.localText) — \($0.localText)" } ?? d.start.localText
        case .relation(let pages): return pages.map(\.title).joined(separator: ", ")
        case .people(let people): return people.map(\.name).joined(separator: ", ")
        case .files(let files): return files.map(\.name).joined(separator: ", ")
        case .time(let ms): return DatePoint.moment(ms: ms, zone: TimeZone.current.identifier).localText
        case .error: return ""
        }
    }

    /// `options` дополняется вариантами, которых ещё нет: имена совпадают без учёта регистра и ё/е.
    static func convert(_ text: String, to type: PropertyType, options: inout [PropertyOption], zone: String, makeOption: (String) -> PropertyOption) -> PropertyValue {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func optionID(_ name: String) -> UUID {
            let key = SearchText.normalize(name)
            if let found = options.first(where: { SearchText.normalize($0.name) == key }) { return found.id }
            let made = makeOption(name)
            options.append(made)
            return made.id
        }
        switch type {
        case .text, .title: return .text(text)
        case .number: return PropertyParse.number(clean).map { .number($0) } ?? .unconverted(text)
        case .checkbox: return PropertyParse.checkbox(clean).map { .checkbox($0) } ?? .unconverted(text)
        case .date: return PropertyParse.date(clean, zone: zone).map { .date($0) } ?? .unconverted(text)
        case .url: return PropertyParse.url(clean).map { .url($0) } ?? .unconverted(text)
        case .status, .select: return .options([optionID(clean)])
        case .multiSelect:
            let names = clean.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var ids: [UUID] = []
            for name in names {
                let id = optionID(name)
                if !ids.contains(id) { ids.append(id) }
            }
            return .options(ids)
        default: return .unconverted(text)
        }
    }
}

/// Результат предварительного просмотра смены типа.
struct TypeChangePreview: Equatable {
    struct Sample: Equatable {
        var from: String
        /// nil — значение не преобразуется и сохранится как есть.
        var to: String?
    }
    var total = 0
    var failed = 0
    var newOptions: [String] = []
    var samples: [Sample] = []
}

// MARK: Запрос

/// Операция фильтра. Строка: операция из новой версии сохраняется и пропускается, а не ломает представление.
struct FilterOp: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let contains = FilterOp(rawValue: "contains")
    static let notContains = FilterOp(rawValue: "not_contains")
    static let equals = FilterOp(rawValue: "equals")
    static let notEquals = FilterOp(rawValue: "not_equals")
    static let startsWith = FilterOp(rawValue: "starts_with")
    static let less = FilterOp(rawValue: "lt")
    static let lessOrEqual = FilterOp(rawValue: "le")
    static let greater = FilterOp(rawValue: "gt")
    static let greaterOrEqual = FilterOp(rawValue: "ge")
    static let isTrue = FilterOp(rawValue: "is_true")
    static let isFalse = FilterOp(rawValue: "is_false")
    static let isEmpty = FilterOp(rawValue: "is_empty")
    static let isNotEmpty = FilterOp(rawValue: "is_not_empty")

    /// Операции типа: единственное место, определяющее допустимые сочетания.
    static func available(for type: PropertyType) -> [FilterOp] {
        switch type {
        case .title, .text, .url: return [.contains, .notContains, .equals, .notEquals, .startsWith, .isEmpty, .isNotEmpty]
        case .number: return [.equals, .notEquals, .less, .lessOrEqual, .greater, .greaterOrEqual, .isEmpty, .isNotEmpty]
        case .date: return [.equals, .less, .lessOrEqual, .greater, .greaterOrEqual, .isEmpty, .isNotEmpty]
        case .checkbox: return [.isTrue, .isFalse]
        case .status, .select: return [.equals, .notEquals, .isEmpty, .isNotEmpty]
        case .multiSelect: return [.contains, .notContains, .isEmpty, .isNotEmpty]
        case .relation: return [.contains, .notContains, .isEmpty, .isNotEmpty]
        case .person: return [.contains, .notContains, .isEmpty, .isNotEmpty]
        case .files: return [.isEmpty, .isNotEmpty]
        case .createdTime, .editedTime: return [.equals, .less, .lessOrEqual, .greater, .greaterOrEqual]
        default: return []
        }
    }

    var needsValue: Bool { ![FilterOp.isEmpty, .isNotEmpty, .isTrue, .isFalse].contains(self) }
}

struct FilterRule: Equatable, Codable {
    var property: UUID
    var op: FilterOp
    /// Число, дата `ГГГГ-ММ-ДД`, ID варианта или текст (у связи — часть заголовка записи): значение всегда передаётся параметром.
    var value: String
}

enum FilterMode: String, Codable { case and, or }

struct FilterGroup: Equatable, Codable {
    var mode: FilterMode = .and
    var items: [FilterNode] = []

    /// Правила на всех уровнях.
    var ruleCount: Int { items.reduce(0) { $0 + $1.ruleCount } }

    /// Убирает правила по условию; опустевшие вложенные группы исчезают.
    func removingRules(where shouldRemove: (FilterRule) -> Bool) -> FilterGroup {
        var out = self
        out.items = items.compactMap { node in
            switch node {
            case .rule(let r): return shouldRemove(r) ? nil : node
            case .group(let g):
                let inner = g.removingRules(where: shouldRemove)
                return inner.items.isEmpty ? nil : .group(inner)
            }
        }
        return out
    }
}

indirect enum FilterNode: Equatable, Codable {
    case rule(FilterRule)
    case group(FilterGroup)

    var ruleCount: Int {
        switch self {
        case .rule: return 1
        case .group(let g): return g.ruleCount
        }
    }
}

struct SortRule: Equatable, Codable {
    var property: UUID
    var descending = false
}

struct ColumnState: Equatable, Codable {
    var property: UUID
    var visible = true
    /// Ширина столбца таблицы в точках (M10.4); nil — ширина по типу свойства.
    var width: Double? = nil

    static let minWidth = 60.0, maxWidth = 800.0
    /// Ширина в допустимых пределах; нечисло и бесконечность дают nil.
    static func clamp(_ width: Double) -> Double? { width.isFinite ? min(maxWidth, max(minWidth, width.rounded())) : nil }
}

/// Состояние представления: хранится отдельно от записей. Неизвестные поля более новой версии не теряются.
struct DatabaseViewState: Equatable {
    var filter = FilterGroup()
    var sorts: [SortRule] = []
    var columns: [ColumnState] = []
    /// Свойство группировки: столбцы доски и разделы других видов.
    var groupBy: UUID?
    /// Свойство даты календаря.
    var dateProperty: UUID?
    /// Показывать обложку страницы на карточке галереи.
    var showCover = true
    /// Масштаб Timeline (M11).
    var timelineScale: TimelineScale = .week
    /// Хронология: день у левого края при последнем просмотре; nil — открывать на сегодня.
    var timelineDay: LocalDate?
    /// Хронология: связь базы с самой собой, по которой рисуются стрелки «зависит от».
    var dependencyProperty: UUID?
    var extra: [String: JSONValue] = [:]

    private struct Known: Codable {
        var filter: FilterGroup?
        var sorts: [SortRule]?
        var columns: [ColumnState]?
        var groupBy: UUID?
        var dateProperty: UUID?
        var showCover: Bool?
        /// Строкой: незнакомый масштаб более новой версии не должен ломать чтение всего состояния.
        var timelineScale: String?
        var timelineDay: String?
        var dependencyProperty: UUID?
    }

    init() {}

    /// Испорченное состояние даёт вид по умолчанию: записи от этого не зависят.
    init(json: String) {
        guard let data = json.data(using: .utf8), case .object(var object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if let known = try? JSONDecoder().decode(Known.self, from: data) {
            filter = known.filter ?? FilterGroup()
            sorts = known.sorts ?? []
            columns = known.columns ?? []
            groupBy = known.groupBy
            dateProperty = known.dateProperty
            showCover = known.showCover ?? true
            timelineDay = known.timelineDay.flatMap(LocalDate.init(iso:))
            dependencyProperty = known.dependencyProperty
            for key in ["filter", "sorts", "columns", "groupBy", "dateProperty", "showCover", "timelineDay", "dependencyProperty"] { object[key] = nil }
            // Незнакомый масштаб остаётся в `extra` и записывается обратно как был.
            if let raw = known.timelineScale, let scale = TimelineScale(rawValue: raw) {
                timelineScale = scale
                object["timelineScale"] = nil
            }
        }
        extra = object
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let known = try encoder.encode(Known(filter: filter, sorts: sorts, columns: columns, groupBy: groupBy, dateProperty: dateProperty, showCover: showCover,
                                                 timelineScale: timelineScale == .week ? nil : timelineScale.rawValue,
                                                 timelineDay: timelineDay?.iso, dependencyProperty: dependencyProperty))
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: known) else { return "{}" }
        let merged = extra.merging(fields) { _, new in new }
        return String(decoding: try encoder.encode(JSONValue.object(merged)), as: UTF8.self)
    }

    /// Группировка: заданное свойство, если оно ещё подходит; у доски без выбора — первое подходящее.
    func groupProperty(_ properties: [PropertyDefinition], kind: String) -> PropertyDefinition? {
        if let groupBy, let found = properties.first(where: { $0.id == groupBy && RecordGroup.isGroupable($0.type) }) { return found }
        guard kind == DatabaseView.boardKind else { return nil }
        return properties.first { $0.type == .status } ?? properties.first { RecordGroup.isGroupable($0.type) }
    }

    /// Свойство зависимостей, если оно всё ещё связь этой базы с самой собой.
    func dependencyProperty(_ properties: [PropertyDefinition], database: UUID) -> PropertyDefinition? {
        properties.first { $0.id == dependencyProperty && $0.type == .relation && $0.config.target == database }
    }

    func calendarProperty(_ properties: [PropertyDefinition]) -> PropertyDefinition? {
        properties.first { $0.id == dateProperty && $0.type == .date } ?? properties.first { $0.type == .date }
    }

    /// То же представление, сужённое до условия: текущий фильтр не меняется.
    func narrowed(by rules: [FilterRule]) -> DatabaseViewState {
        var out = self
        out.filter = FilterGroup(mode: .and, items: [.group(filter)] + rules.map { .rule($0) })
        return out
    }

    /// Столбцы в порядке представления: новые свойства в конце и видимы, удалённые исчезают, заголовок всегда виден.
    /// Сохранённая ширина столбца свойства или nil.
    func columnWidth(_ property: UUID) -> Double? { columns.first { $0.property == property }?.width.flatMap(ColumnState.clamp) }

    /// Ширина задаётся и для столбца, которого ещё нет в списке: он добавляется с порядком по умолчанию.
    mutating func setColumnWidth(_ property: UUID, _ width: Double?, properties: [PropertyDefinition]) {
        columns = orderedColumns(properties)
        guard let i = columns.firstIndex(where: { $0.property == property }) else { return }
        columns[i].width = width.flatMap(ColumnState.clamp)
    }

    func orderedColumns(_ properties: [PropertyDefinition]) -> [ColumnState] {
        let live = Set(properties.map(\.id))
        var out = columns.filter { live.contains($0.property) }
        for p in properties where !out.contains(where: { $0.property == p.id }) { out.append(ColumnState(property: p.id)) }
        if let title = properties.first(where: { $0.type == .title }), let i = out.firstIndex(where: { $0.property == title.id }) {
            out[i].visible = true
        }
        return out
    }
}

struct DatabaseView: Equatable, Identifiable {
    /// Вид представления: M5 показывает таблицу, остальные появятся в M6 и хранятся без потерь.
    static let tableKind = "table"
    static let boardKind = "board"
    static let listKind = "list"
    static let calendarKind = "calendar"
    static let galleryKind = "gallery"
    static let timelineKind = "timeline"
    static let knownKinds = [tableKind, boardKind, listKind, calendarKind, galleryKind, timelineKind]
    /// Виды, которым нужно свойство даты.
    static func usesDate(_ kind: String) -> Bool { kind == calendarKind || kind == timelineKind }

    var id: UUID
    var databaseID: UUID
    var name: String
    var kind: String
    var sortKey: String
    var state: DatabaseViewState
}

/// База: коллекция страниц-записей. Сама база тоже страница (`pageID`), поэтому дерево и корзина общие.
struct Database: Equatable, Identifiable {
    var id: UUID
    var pageID: UUID
    var properties: [PropertyDefinition]
    var views: [DatabaseView]

    var titleProperty: PropertyDefinition? { properties.first { $0.type == .title } }
    func property(_ id: UUID) -> PropertyDefinition? { properties.first { $0.id == id } }
}

/// Начальная структура новой базы: подписи приходят из оболочки, хранилище их не переводит.
struct NewDatabase {
    var title: String
    var titleProperty: String
    var statusProperty: String
    var statusOptions: [String]
    var dateProperty: String
    var viewName: String
    /// Остальные представления новой базы: название и вид.
    var extraViews: [(name: String, kind: String)] = []
}

/// Группа записей: столбец доски или раздел. Отбор — обычное правило фильтра, поэтому механизм запроса один.
struct RecordGroup: Equatable, Identifiable {
    var id: String
    var property: UUID
    var option: PropertyOption?
    var checked: Bool?
    var person: Person? = nil
    var rule: FilterRule

    static func isGroupable(_ type: PropertyType) -> Bool { type.usesOptions || type == .checkbox || type == .person }

    /// Сначала варианты по порядку, в конце группа без значения: запись не должна пропасть из вида.
    /// У «Человека» группы — люди справочника; запись с несколькими людьми видна в группе каждого.
    static func groups(for def: PropertyDefinition, people: [Person] = []) -> [RecordGroup] {
        if def.type == .person {
            return people.map { RecordGroup(id: $0.id.uuidString, property: def.id, person: $0, rule: FilterRule(property: def.id, op: .contains, value: $0.id.uuidString)) }
                + [RecordGroup(id: "empty", property: def.id, rule: FilterRule(property: def.id, op: .isEmpty, value: ""))]
        }
        if def.type == .checkbox {
            return [RecordGroup(id: "true", property: def.id, checked: true, rule: FilterRule(property: def.id, op: .isTrue, value: "")),
                    RecordGroup(id: "false", property: def.id, checked: false, rule: FilterRule(property: def.id, op: .isFalse, value: ""))]
        }
        guard def.type.usesOptions else { return [] }
        let op: FilterOp = def.type == .multiSelect ? .contains : .equals
        return def.options.map { RecordGroup(id: $0.id.uuidString, property: def.id, option: $0, rule: FilterRule(property: def.id, op: op, value: $0.id.uuidString)) }
            + [RecordGroup(id: "empty", property: def.id, rule: FilterRule(property: def.id, op: .isEmpty, value: ""))]
    }

    /// Значение записи после переноса в эту группу. Во множественном выборе заменяется только вариант исходной группы.
    func value(replacing current: PropertyValue?, from source: RecordGroup?, type: PropertyType) -> PropertyValue? {
        if let checked { return .checkbox(checked) }
        if type == .person {
            // Заменяется только человек исходной группы, остальные остаются; в группу «пусто» — без людей.
            guard let person else { return nil }
            if source?.person?.id == person.id, case .people? = current { return current }
            var people: [Person] = []
            if case .people(let old)? = current { people = old.filter { $0.id != source?.person?.id } }
            if !people.contains(where: { $0.id == person.id }) { people.append(person) }
            return .people(people)
        }
        guard type == .multiSelect else { return option.map { .options([$0.id]) } }
        guard let option else { return nil }
        var ids: [UUID] = []
        if case .options(let old)? = current { ids = old.filter { $0 != source?.option?.id } }
        if !ids.contains(option.id) { ids.append(option.id) }
        return .options(ids)
    }
}

/// Шаблон пользователя: скрытая копия страницы с поддеревом. У записи указана база.
struct PageTemplate: Equatable, Identifiable {
    var id: UUID
    var name: String
    var rootPage: UUID
    var databaseID: UUID?
    var createdAt: Int64
}

struct RecordRow: Equatable, Identifiable {
    var id: UUID
    var title: String
    var icon: String?
    var cover: UUID? = nil
    var values: [UUID: PropertyValue]
}

struct RecordPage: Equatable {
    var rows: [RecordRow]
    /// Всего записей под фильтром, а не на этой странице.
    var total: Int
}
