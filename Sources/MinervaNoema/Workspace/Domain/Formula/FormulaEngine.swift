import Foundation

/// Типы значений формулы. Пустое значение возможно у любого типа и проверяется функцией `empty()`.
enum FormulaType: String, Equatable, Codable {
    case number, text, bool, date

    /// Тип значения свойства в формуле: по типу хранения (у свёртки — по её результату).
    static func of(_ property: PropertyDefinition) -> FormulaType {
        switch property.valueType {
        case .number: return .number
        case .checkbox: return .bool
        case .date, .createdTime, .editedTime: return .date
        default: return .text
        }
    }
}

/// Допустимые даты: годы 1…9999, как у `LocalDate`. Значения из хранилища или копии проверяются до вычисления.
enum FormulaDates {
    static let minMs: Int64 = -62_135_596_800_000
    static let maxMs: Int64 = 253_402_300_799_999

    static func isSane(_ point: DatePoint) -> Bool {
        switch point {
        case .moment(let ms, _): return (minMs...maxMs).contains(ms)
        case .day(let d): return LocalDate(year: d.year, month: d.month, day: d.day) != nil
        }
    }

    static func isSane(_ value: DateValue) -> Bool { isSane(value.start) && (value.end.map(isSane) ?? true) }
}

enum FormulaValue: Equatable {
    case number(Double)
    case text(String)
    case bool(Bool)
    case date(DateValue)
    case empty

    /// Значение свойства записи как вход формулы.
    static func from(_ value: PropertyValue?, property: PropertyDefinition) -> FormulaValue {
        let type = FormulaType.of(property)
        switch (value, type) {
        case (nil, .bool): return .bool(false)
        case (nil, _): return .empty
        case (.number(let n)?, .number): return .number(n)
        case (.checkbox(let b)?, _): return .bool(b)
        case (.date(let d)?, _): return FormulaDates.isSane(d) ? .date(d) : .empty
        case (.time(let ms)?, _):
            let point = DatePoint.moment(ms: ms, zone: TimeZone.current.identifier)
            return FormulaDates.isSane(point) ? .date(DateValue(start: point)) : .empty
        case (.unconverted?, .number), (.unconverted?, .date), (.unconverted?, .bool): return .empty
        case (let v?, .text):
            let text = PropertyConversion.text(of: v, options: property.options)
            return text.isEmpty ? .empty : .text(text)
        default: return .empty
        }
    }
}

/// Сведения о функции для подсказок и справки.
struct FormulaFunctionInfo: Equatable {
    var name: String
    var signature: String
}

enum FormulaFunctions {
    static let units = ["years", "months", "weeks", "days", "hours", "minutes"]

    /// Полный список функций: только они и могут быть вызваны.
    static let all: [FormulaFunctionInfo] = [
        .init(name: "if", signature: "if(условие, да, нет)"),
        .init(name: "ifs", signature: "ifs(условие1, значение1, …, иначе)"),
        .init(name: "empty", signature: "empty(значение)"),
        .init(name: "not", signature: "not(логическое)"),
        .init(name: "abs", signature: "abs(число)"),
        .init(name: "round", signature: "round(число, знаков)"),
        .init(name: "ceil", signature: "ceil(число)"),
        .init(name: "floor", signature: "floor(число)"),
        .init(name: "min", signature: "min(число, …)"),
        .init(name: "max", signature: "max(число, …)"),
        .init(name: "sqrt", signature: "sqrt(число)"),
        .init(name: "pow", signature: "pow(число, степень)"),
        .init(name: "mod", signature: "mod(число, делитель)"),
        .init(name: "sign", signature: "sign(число)"),
        .init(name: "length", signature: "length(текст)"),
        .init(name: "lower", signature: "lower(текст)"),
        .init(name: "upper", signature: "upper(текст)"),
        .init(name: "trim", signature: "trim(текст)"),
        .init(name: "contains", signature: "contains(текст, часть)"),
        .init(name: "startsWith", signature: "startsWith(текст, начало)"),
        .init(name: "endsWith", signature: "endsWith(текст, конец)"),
        .init(name: "replace", signature: "replace(текст, что, на что)"),
        .init(name: "replaceAll", signature: "replaceAll(текст, что, на что)"),
        .init(name: "slice", signature: "slice(текст, с, до)"),
        .init(name: "format", signature: "format(значение)"),
        .init(name: "toNumber", signature: "toNumber(текст)"),
        .init(name: "join", signature: "join(разделитель, текст, …)"),
        .init(name: "today", signature: "today()"),
        .init(name: "dateAdd", signature: "dateAdd(дата, число, \"days\")"),
        .init(name: "dateSubtract", signature: "dateSubtract(дата, число, \"days\")"),
        .init(name: "dateBetween", signature: "dateBetween(дата1, дата2, \"days\")"),
        .init(name: "formatDate", signature: "formatDate(дата, \"DD.MM.YYYY\")"),
        .init(name: "year", signature: "year(дата)"),
        .init(name: "month", signature: "month(дата)"),
        .init(name: "day", signature: "day(дата)"),
        .init(name: "weekday", signature: "weekday(дата)"),
        .init(name: "dateStart", signature: "dateStart(дата)"),
        .init(name: "dateEnd", signature: "dateEnd(дата)"),
        .init(name: "prop", signature: "prop(\"Имя свойства\")"),
    ]

    static let names = Set(all.map(\.name))
}

/// Связанная и проверенная формула: дерево, тип результата и зависимости.
struct CompiledFormula: Equatable {
    var node: FormulaNode
    var type: FormulaType
    var dependencies: Set<UUID> { node.properties }

    /// Разбор, связывание ссылок и проверка типов. `resolve` получает аргумент `prop("…")` — ID в хранимом тексте
    /// или имя при вводе — и возвращает свойство с типом его значения.
    static func compile(_ source: String, resolve: (String) -> (id: UUID, type: FormulaType)?) throws -> CompiledFormula {
        var types: [UUID: FormulaType] = [:]
        let chars = Array(source)
        // Только прямая запись prop("…"): её переписывает FormulaReferences, иначе переименование сломало бы ссылку.
        let plain: (FormulaRange) -> Bool = { r in r.lowerBound < chars.count && chars[r.lowerBound] == "\"" }
        let bound = try bind(try FormulaParser.parse(source), plain: plain) { arg in
            guard let found = resolve(arg) else { return nil }
            types[found.id] = found.type
            return found.id
        }
        let type = try FormulaChecker(types: types).check(bound)
        return CompiledFormula(node: bound, type: type)
    }

    private static func bind(_ node: FormulaNode, plain: (FormulaRange) -> Bool, _ resolve: (String) -> UUID?) throws -> FormulaNode {
        switch node {
        case .call("prop", let args, let r):
            guard args.count == 1, case .text(let name, let argRange) = args[0], plain(argRange) else {
                throw FormulaError("prop() принимает имя свойства в кавычках.", at: r)
            }
            guard let id = resolve(name) else { throw FormulaError("Нет свойства «%@».", name, at: argRange) }
            return .property(id, r)
        case .call(let name, let args, let r): return .call(name, try args.map { try bind($0, plain: plain, resolve) }, r)
        case .unary(let op, let e, let r): return .unary(op, try bind(e, plain: plain, resolve), r)
        case .binary(let op, let a, let b, let r): return .binary(op, try bind(a, plain: plain, resolve), try bind(b, plain: plain, resolve), r)
        default: return node
        }
    }
}

/// Проверка типов до сохранения: формула с ошибкой не записывается.
struct FormulaChecker {
    var types: [UUID: FormulaType]

    private static func name(_ t: FormulaType) -> String {
        switch t {
        case .number: return NSLocalizedString("число", comment: "")
        case .text: return NSLocalizedString("текст", comment: "")
        case .bool: return NSLocalizedString("логическое", comment: "")
        case .date: return NSLocalizedString("дата", comment: "")
        }
    }

    private func expect(_ node: FormulaNode, _ type: FormulaType) throws {
        let actual = try check(node)
        guard actual == type else {
            throw FormulaError("Ожидалось %@, а здесь %@.", Self.name(type), Self.name(actual), at: node.range)
        }
    }

    func check(_ node: FormulaNode) throws -> FormulaType {
        switch node {
        case .number: return .number
        case .text: return .text
        case .bool: return .bool
        case .property(let id, let r):
            guard let t = types[id] else { throw FormulaError("Нет свойства.", at: r) }
            return t
        case .unary(let op, let e, _):
            try expect(e, op == "not" ? .bool : .number)
            return op == "not" ? .bool : .number
        case .binary(let op, let a, let b, let r):
            switch op {
            case "+":
                let ta = try check(a), tb = try check(b)
                if ta == .number && tb == .number { return .number }
                if ta == .text || tb == .text { return .text }
                throw FormulaError("«+» складывает числа или склеивает текст. Для дат — dateAdd().", at: r)
            case "-", "*", "/", "%", "^":
                try expect(a, .number); try expect(b, .number)
                return .number
            case "and", "or":
                try expect(a, .bool); try expect(b, .bool)
                return .bool
            default:
                let ta = try check(a), tb = try check(b)
                guard ta == tb else { throw FormulaError("Сравниваются разные типы: %@ и %@.", Self.name(ta), Self.name(tb), at: r) }
                if op != "==" && op != "!=" && ta == .bool { throw FormulaError("Логические значения можно только сравнить на равенство.", at: r) }
                return .bool
            }
        case .call(let name, let args, let r):
            return try call(name, args, r)
        }
    }

    private func count(_ args: [FormulaNode], _ allowed: ClosedRange<Int>, _ name: String, _ r: FormulaRange) throws {
        guard allowed.contains(args.count) else {
            if allowed.upperBound == Int.max {
                throw FormulaError("%@: нужно аргументов не меньше %ld, передано %ld.", name, allowed.lowerBound, args.count, at: r)
            }
            let expected = allowed.lowerBound == allowed.upperBound ? "\(allowed.lowerBound)" : "\(allowed.lowerBound)–\(allowed.upperBound)"
            throw FormulaError("%@: нужно аргументов %@, передано %ld.", name, expected, args.count, at: r)
        }
    }

    private func unit(_ node: FormulaNode) throws {
        try expect(node, .text)
        if case .text(let u, let r) = node, !FormulaFunctions.units.contains(u) {
            throw FormulaError("Единица «%@» не поддерживается: years, months, weeks, days, hours, minutes.", u, at: r)
        }
    }

    private func call(_ name: String, _ args: [FormulaNode], _ r: FormulaRange) throws -> FormulaType {
        let many = Int.max
        switch name {
        case "if":
            try count(args, 3...3, name, r)
            try expect(args[0], .bool)
            let a = try check(args[1]), b = try check(args[2])
            guard a == b else { throw FormulaError("Ветки if должны быть одного типа: %@ и %@.", Self.name(a), Self.name(b), at: r) }
            return a
        case "ifs":
            guard args.count >= 3, args.count % 2 == 1 else { throw FormulaError("ifs: пары «условие, значение» и значение по умолчанию.", at: r) }
            let result = try check(args[args.count - 1])
            for i in stride(from: 0, to: args.count - 1, by: 2) {
                try expect(args[i], .bool)
                try expect(args[i + 1], result)
            }
            return result
        case "empty":
            try count(args, 1...1, name, r); _ = try check(args[0]); return .bool
        case "not":
            try count(args, 1...1, name, r); try expect(args[0], .bool); return .bool
        case "abs", "ceil", "floor", "sqrt", "sign":
            try count(args, 1...1, name, r); try expect(args[0], .number); return .number
        case "round":
            try count(args, 1...2, name, r); for a in args { try expect(a, .number) }; return .number
        case "pow", "mod":
            try count(args, 2...2, name, r); for a in args { try expect(a, .number) }; return .number
        case "min", "max":
            try count(args, 1...many, name, r); for a in args { try expect(a, .number) }; return .number
        case "length":
            try count(args, 1...1, name, r); try expect(args[0], .text); return .number
        case "lower", "upper", "trim":
            try count(args, 1...1, name, r); try expect(args[0], .text); return .text
        case "contains", "startsWith", "endsWith":
            try count(args, 2...2, name, r); for a in args { try expect(a, .text) }; return .bool
        case "replace", "replaceAll":
            try count(args, 3...3, name, r); for a in args { try expect(a, .text) }; return .text
        case "slice":
            try count(args, 2...3, name, r); try expect(args[0], .text); for a in args.dropFirst() { try expect(a, .number) }; return .text
        case "format":
            try count(args, 1...1, name, r); _ = try check(args[0]); return .text
        case "toNumber":
            try count(args, 1...1, name, r); try expect(args[0], .text); return .number
        case "join":
            try count(args, 2...many, name, r); for a in args { try expect(a, .text) }; return .text
        case "today":
            try count(args, 0...0, name, r); return .date
        case "dateAdd", "dateSubtract":
            try count(args, 3...3, name, r); try expect(args[0], .date); try expect(args[1], .number); try unit(args[2]); return .date
        case "dateBetween":
            try count(args, 3...3, name, r); try expect(args[0], .date); try expect(args[1], .date); try unit(args[2]); return .number
        case "formatDate":
            try count(args, 1...2, name, r); try expect(args[0], .date); if args.count == 2 { try expect(args[1], .text) }; return .text
        case "year", "month", "day", "weekday":
            try count(args, 1...1, name, r); try expect(args[0], .date); return .number
        case "dateStart", "dateEnd":
            try count(args, 1...1, name, r); try expect(args[0], .date); return .date
        default:
            throw FormulaError("Нет функции «%@».", name, at: r)
        }
    }
}

/// Входные данные вычисления. «Сегодня» передаётся снаружи: результат зависит только от входа.
struct FormulaContext {
    var values: [UUID: FormulaValue]
    var today: LocalDate
    var zone: TimeZone = .current
}

/// Интерпретатор. Шаги считаются: зацикливания нет по построению, но предел защищает от тяжёлых формул.
struct FormulaEvaluator {
    let context: FormulaContext
    private var steps = 0

    init(context: FormulaContext) { self.context = context }

    static func evaluate(_ formula: CompiledFormula, context: FormulaContext) throws -> FormulaValue {
        var e = FormulaEvaluator(context: context)
        return try e.eval(formula.node)
    }

    // MARK: Приведение аргументов

    private func number(_ v: FormulaValue) -> Double? { if case .number(let n) = v { return n }; return nil }
    private func text(_ v: FormulaValue) -> String { if case .text(let s) = v { return s }; return "" }
    private func bool(_ v: FormulaValue) -> Bool { if case .bool(let b) = v { return b }; return false }
    private func date(_ v: FormulaValue) -> DateValue? { if case .date(let d) = v { return d }; return nil }

    private func finite(_ n: Double, _ r: FormulaRange) throws -> FormulaValue {
        guard n.isFinite else { throw FormulaError("Результат не число: деление на ноль или переполнение.", at: r) }
        return .number(n)
    }

    private func checked(_ s: String, _ r: FormulaRange) throws -> FormulaValue {
        guard s.count <= FormulaLimits.maxText else { throw FormulaError("Текст результата длиннее %ld символов.", FormulaLimits.maxText, at: r) }
        return .text(s)
    }

    // MARK: Вычисление

    private mutating func eval(_ node: FormulaNode) throws -> FormulaValue {
        steps += 1
        guard steps <= FormulaLimits.maxSteps else { throw FormulaError("Вычисление слишком долгое.", at: node.range) }
        switch node {
        case .number(let n, _): return .number(n)
        case .text(let s, _): return .text(s)
        case .bool(let b, _): return .bool(b)
        case .property(let id, let r): return try property(id, r)
        case .unary(let op, let e, let r): return try negate(op, try eval(e), r)
        case .binary(let op, let a, let b, let r):
            return try binary(op, a, b, r)
        case .call(let name, let args, let r):
            return try call(name, args, r)
        }
    }

    // Всё, что не рекурсия, вынесено из `eval`: его кадр повторяется на каждом уровне дерева.

    @inline(never)
    private func property(_ id: UUID, _ r: FormulaRange) throws -> FormulaValue {
        let value = context.values[id] ?? .empty
        switch value {
        case .text(let s) where s.count > FormulaLimits.maxText:
            throw FormulaError("Значение свойства длиннее %ld символов.", FormulaLimits.maxText, at: r)
        case .date(let d) where !FormulaDates.isSane(d): return .empty
        case .number(let n) where !n.isFinite: return .empty
        default: return value
        }
    }

    @inline(never)
    private func negate(_ op: String, _ v: FormulaValue, _ r: FormulaRange) throws -> FormulaValue {
        if op == "not" { return .bool(!bool(v)) }
        guard let n = number(v) else { return .empty }
        return try finite(-n, r)
    }

    /// Рекурсивная часть мала: применение оператора — отдельная функция, её кадр не копится на стеке.
    private mutating func binary(_ op: String, _ a: FormulaNode, _ b: FormulaNode, _ r: FormulaRange) throws -> FormulaValue {
        // Логика вычисляется лениво: правая часть не нужна, если ответ уже ясен.
        if op == "and" { return .bool(bool(try eval(a)) ? bool(try eval(b)) : false) }
        if op == "or" { return .bool(bool(try eval(a)) ? true : bool(try eval(b))) }
        let x = try eval(a), y = try eval(b)
        return try apply(op, x, y, r)
    }

    @inline(never)
    private func apply(_ op: String, _ x: FormulaValue, _ y: FormulaValue, _ r: FormulaRange) throws -> FormulaValue {
        switch op {
        case "+":
            if case .number(let p) = x, case .number(let q) = y { return try finite(p + q, r) }
            if x == .empty && y == .empty { return .empty }
            if case .number = x, y == .empty { return .empty }
            if case .number = y, x == .empty { return .empty }
            return try checked(display(x) + display(y), r)
        case "-", "*", "/", "%", "^":
            guard let p = number(x), let q = number(y) else { return .empty }
            switch op {
            case "-": return try finite(p - q, r)
            case "*": return try finite(p * q, r)
            case "/":
                guard q != 0 else { throw FormulaError("Деление на ноль.", at: r) }
                return try finite(p / q, r)
            case "%":
                guard q != 0 else { throw FormulaError("Деление на ноль.", at: r) }
                return try finite(p.truncatingRemainder(dividingBy: q), r)
            default: return try finite(Foundation.pow(p, q), r)
            }
        case "==": return .bool(x == y)
        case "!=": return .bool(x != y)
        default:
            guard let order = compare(x, y) else { return .bool(false) }
            switch op {
            case "<": return .bool(order < 0)
            case "<=": return .bool(order <= 0)
            case ">": return .bool(order > 0)
            default: return .bool(order >= 0)
            }
        }
    }

    /// -1, 0, 1; nil — сравнивать нечего (пусто или разные типы).
    private func compare(_ x: FormulaValue, _ y: FormulaValue) -> Int? {
        switch (x, y) {
        case (.number(let a), .number(let b)): return a < b ? -1 : a > b ? 1 : 0
        case (.text(let a), .text(let b)): return a < b ? -1 : a > b ? 1 : 0
        case (.date(let a), .date(let b)):
            let p = instant(a.start), q = instant(b.start)
            return p < q ? -1 : p > q ? 1 : 0
        default: return nil
        }
    }

    /// Момент точки: день — его полночь в поясе пользователя.
    private func instant(_ point: DatePoint) -> Int64 {
        switch point {
        case .moment(let ms, _): return ms
        case .day(let d):
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = context.zone
            let date = cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date(timeIntervalSince1970: 0)
            return Int64(date.timeIntervalSince1970 * 1000)
        }
    }

    /// Текст значения: для склейки и format().
    func display(_ v: FormulaValue) -> String {
        switch v {
        case .number(let n): return PropertyParse.numberText(n)
        case .text(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return formatDate(d, nil)
        case .empty: return ""
        }
    }

    private func formatDate(_ d: DateValue, _ pattern: String?) -> String {
        func one(_ p: DatePoint) -> String {
            let local = p.localText
            let year = String(local.prefix(4)), month = String(local.dropFirst(5).prefix(2)), day = String(local.dropFirst(8).prefix(2))
            var hour = "00", minute = "00", hasTime = false
            if local.count >= 16 { hour = String(local.dropFirst(11).prefix(2)); minute = String(local.dropFirst(14).prefix(2)); hasTime = true }
            let format = pattern ?? (hasTime ? "DD.MM.YYYY HH:mm" : "DD.MM.YYYY")
            return format.replacingOccurrences(of: "YYYY", with: year).replacingOccurrences(of: "MM", with: month)
                .replacingOccurrences(of: "DD", with: day).replacingOccurrences(of: "HH", with: hour).replacingOccurrences(of: "mm", with: minute)
        }
        return d.end.map { "\(one(d.start)) — \(one($0))" } ?? one(d.start)
    }

    private func shift(_ point: DatePoint, by n: Int, unit: String, _ r: FormulaRange) throws -> DatePoint {
        switch point {
        case .day(let d):
            switch unit {
            case "years", "months", "weeks", "days":
                let moved: LocalDate
                switch unit {
                case "years": moved = d.addingMonths(12 * n)
                case "months": moved = d.addingMonths(n)
                case "weeks": moved = d.adding(days: 7 * n)
                default: moved = d.adding(days: n)
                }
                // Сдвиг обязан идти в свою сторону: уход за 1 год н. э. календарь отдаёт как год без эры.
                let direction = n > 0 ? d < moved : n < 0 ? moved < d : moved == d
                guard FormulaDates.isSane(.day(moved)), direction || (unit == "months" || unit == "years") && moved == d else {
                    throw FormulaError("Дата вне допустимого диапазона.", at: r)
                }
                return .day(moved)
            default:
                // Часы к дню без времени: момент от полуночи в поясе пользователя.
                return try shift(.moment(ms: instant(point), zone: context.zone.identifier), by: n, unit: unit, r)
            }
        case .moment(let ms, let zone):
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: zone) ?? context.zone
            let component: Calendar.Component
            switch unit {
            case "years": component = .year
            case "months": component = .month
            case "weeks": component = .weekOfYear
            case "days": component = .day
            case "hours": component = .hour
            case "minutes": component = .minute
            default: throw FormulaError("Неизвестная единица «%@».", unit, at: r)
            }
            let millis = (cal.date(byAdding: component, value: n, to: Date(timeIntervalSince1970: Double(ms) / 1000))?.timeIntervalSince1970).map { $0 * 1000 }
            guard let millis, millis.isFinite, millis >= Double(FormulaDates.minMs), millis <= Double(FormulaDates.maxMs) else {
                throw FormulaError("Дата вне допустимого диапазона.", at: r)
            }
            return .moment(ms: Int64(millis), zone: zone)
        }
    }

    private func between(_ a: DatePoint, _ b: DatePoint, unit: String) -> Double {
        switch unit {
        case "hours": return Double((instant(a) - instant(b)) / 3_600_000)
        case "minutes": return Double((instant(a) - instant(b)) / 60_000)
        default:
            let days = b.localDay.days(to: a.localDay)
            switch unit {
            case "weeks": return Double(days / 7)
            case "months", "years":
                var months = (a.localDay.year - b.localDay.year) * 12 + (a.localDay.month - b.localDay.month)
                // Неполный месяц не считается: 31 января → 28 февраля — 0 месяцев.
                if months > 0 && a.localDay.day < b.localDay.day { months -= 1 }
                if months < 0 && a.localDay.day > b.localDay.day { months += 1 }
                return Double(unit == "years" ? months / 12 : months)
            default: return Double(days)
            }
        }
    }

    private mutating func call(_ name: String, _ nodes: [FormulaNode], _ r: FormulaRange) throws -> FormulaValue {
        switch name {
        case "if":
            return bool(try eval(nodes[0])) ? try eval(nodes[1]) : try eval(nodes[2])
        case "ifs":
            for i in stride(from: 0, to: nodes.count - 1, by: 2) {
                if bool(try eval(nodes[i])) { return try eval(nodes[i + 1]) }
            }
            return try eval(nodes[nodes.count - 1])
        default: break
        }
        var args: [FormulaValue] = []
        for n in nodes { args.append(try eval(n)) }
        return try apply(name, args, r)
    }

    /// Целое из числа формулы без аварийной остановки: NaN — нижняя граница, за пределами — ближайшая граница.
    private func clamp(_ d: Double, _ lo: Int, _ hi: Int) -> Int {
        guard d.isFinite else { return d == .infinity ? hi : lo }
        return Int(Swift.min(Swift.max(d, Double(lo)), Double(hi)))
    }

    @inline(never)
    private func apply(_ name: String, _ args: [FormulaValue], _ r: FormulaRange) throws -> FormulaValue {
        for case .text(let s) in args where s.count > FormulaLimits.maxText {
            throw FormulaError("Текст длиннее %ld символов.", FormulaLimits.maxText, at: r)
        }
        switch name {
        case "empty":
            switch args[0] {
            case .empty: return .bool(true)
            case .text(let s): return .bool(s.isEmpty)
            default: return .bool(false)
            }
        case "not": return .bool(!bool(args[0]))
        case "abs", "ceil", "floor", "sqrt", "sign":
            guard let n = number(args[0]) else { return .empty }
            switch name {
            case "abs": return .number(Swift.abs(n))
            case "ceil": return .number(n.rounded(.up))
            case "floor": return .number(n.rounded(.down))
            case "sign": return .number(n > 0 ? 1 : n < 0 ? -1 : 0)
            default:
                guard n >= 0 else { throw FormulaError("Корень из отрицательного числа.", at: r) }
                return .number(n.squareRoot())
            }
        case "round":
            guard let n = number(args[0]) else { return .empty }
            let raw = args.count > 1 ? (number(args[1]) ?? 0) : 0
            guard raw.isFinite, raw >= 0, raw <= 10 else { throw FormulaError("round: знаков после запятой от 0 до 10.", at: r) }
            let digits = Int(raw)
            let scale = Foundation.pow(10, Double(digits))
            return try finite((n * scale).rounded(.toNearestOrAwayFromZero) / scale, r)
        case "pow":
            guard let a = number(args[0]), let b = number(args[1]) else { return .empty }
            return try finite(Foundation.pow(a, b), r)
        case "mod":
            guard let a = number(args[0]), let b = number(args[1]) else { return .empty }
            guard b != 0 else { throw FormulaError("Деление на ноль.", at: r) }
            return .number(a.truncatingRemainder(dividingBy: b))
        case "min", "max":
            let nums = args.compactMap(number)
            guard !nums.isEmpty else { return .empty }
            return .number(name == "min" ? nums.min()! : nums.max()!)
        case "length": return .number(Double(text(args[0]).count))
        case "lower": return .text(text(args[0]).lowercased())
        case "upper": return .text(text(args[0]).uppercased())
        case "trim": return .text(text(args[0]).trimmingCharacters(in: .whitespacesAndNewlines))
        case "contains":
            let needle = text(args[1])
            return .bool(needle.isEmpty || text(args[0]).contains(needle))
        case "startsWith": return .bool(text(args[0]).hasPrefix(text(args[1])))
        case "endsWith": return .bool(text(args[0]).hasSuffix(text(args[1])))
        case "replace", "replaceAll":
            let source = text(args[0]), what = text(args[1]), with = text(args[2])
            guard !what.isEmpty else { return .text(source) }
            if name == "replaceAll" {
                // Размер результата считается до замены: строка не раздувается в памяти сверх предела.
                var count = 0, rest = source.startIndex..<source.endIndex
                while let found = source.range(of: what, range: rest) {
                    count += 1
                    rest = found.upperBound..<source.endIndex
                }
                guard source.count + count * (with.count - what.count) <= FormulaLimits.maxText else {
                    throw FormulaError("Текст результата длиннее %ld символов.", FormulaLimits.maxText, at: r)
                }
                return try checked(source.replacingOccurrences(of: what, with: with), r)
            }
            guard let found = source.range(of: what) else { return .text(source) }
            return try checked(source.replacingCharacters(in: found, with: with), r)
        case "slice":
            let chars = Array(text(args[0]))
            guard let from = number(args[1]) else { return .empty }
            let to = args.count > 2 ? number(args[2]) : Double(chars.count)
            let lo = clamp(from, 0, chars.count), hi = Swift.max(lo, clamp(to ?? Double(chars.count), 0, chars.count))
            return .text(String(chars[lo..<hi]))
        case "format": return try checked(display(args[0]), r)
        case "toNumber": return PropertyParse.number(text(args[0])).map { .number($0) } ?? .empty
        case "join":
            let parts = args.dropFirst().compactMap { v -> String? in if case .text(let s) = v, !s.isEmpty { return s }; return nil }
            return try checked(parts.joined(separator: text(args[0])), r)
        case "today": return .date(DateValue(start: .day(context.today)))
        case "dateAdd", "dateSubtract":
            guard let d = date(args[0]), let n = number(args[1]) else { return .empty }
            guard n.isFinite, Swift.abs(n) <= 1_000_000 else { throw FormulaError("Слишком большой сдвиг даты.", at: r) }
            let step = (name == "dateAdd" ? 1 : -1) * Int(n.rounded(.towardZero))
            let u = text(args[2])
            return .date(DateValue(start: try shift(d.start, by: step, unit: u, r), end: try d.end.map { try shift($0, by: step, unit: u, r) }))
        case "dateBetween":
            guard let a = date(args[0]), let b = date(args[1]) else { return .empty }
            let u = text(args[2])
            guard FormulaFunctions.units.contains(u) else { throw FormulaError("Неизвестная единица «%@».", u, at: r) }
            return .number(between(a.start, b.start, unit: u))
        case "formatDate":
            guard let d = date(args[0]) else { return .empty }
            return try checked(formatDate(d, args.count > 1 ? text(args[1]) : nil), r)
        case "year", "month", "day", "weekday":
            guard let d = date(args[0]) else { return .empty }
            let day = d.start.localDay
            switch name {
            case "year": return .number(Double(day.year))
            case "month": return .number(Double(day.month))
            case "day": return .number(Double(day.day))
            default: return .number(Double(day.weekdayFromMonday + 1))
            }
        case "dateStart":
            guard let d = date(args[0]) else { return .empty }
            return .date(DateValue(start: d.start))
        case "dateEnd":
            guard let d = date(args[0]) else { return .empty }
            return .date(DateValue(start: d.end ?? d.start))
        default:
            throw FormulaError("Нет функции «%@».", name, at: r)
        }
    }
}

/// Граф зависимостей свойств: поиск цикла до сохранения формулы.
enum DependencyGraph {
    /// Путь цикла, начинающийся и кончающийся в `start`, или nil. `edges` — от чего зависит свойство.
    /// Обход без рекурсии: длинная цепочка свойств из повреждённой копии не исчерпает стек.
    static func cycle(from start: UUID, edges: (UUID) -> Set<UUID>) -> [UUID]? {
        var path: [UUID] = [start]
        var pending: [[UUID]] = [sorted(edges(start))]
        var onPath: Set<UUID> = [start], done: Set<UUID> = []
        while !pending.isEmpty {
            guard let next = pending[pending.count - 1].popLast() else {
                pending.removeLast()
                let finished = path.removeLast()
                onPath.remove(finished)
                done.insert(finished)
                continue
            }
            if next == start { return path + [start] }
            if onPath.contains(next) || done.contains(next) { continue }
            path.append(next)
            onPath.insert(next)
            pending.append(sorted(edges(next)))
        }
        return nil
    }

    /// Любой цикл среди `nodes`: проверка данных, пришедших из копии или другой версии.
    static func anyCycle(in nodes: [UUID], edges: (UUID) -> Set<UUID>) -> [UUID]? {
        var checked: Set<UUID> = []
        for node in nodes where !checked.contains(node) {
            if let found = cycle(from: node, edges: edges) { return found }
            checked.insert(node)
        }
        return nil
    }

    /// Обратный порядок: `popLast` берёт соседей по возрастанию, результат воспроизводим.
    private static func sorted(_ s: Set<UUID>) -> [UUID] { s.sorted { $0.uuidString > $1.uuidString } }
}
