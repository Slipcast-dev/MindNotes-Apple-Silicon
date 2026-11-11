import Foundation

/// Язык формул (FR-13): собственный разбор и интерпретатор над закрытой таблицей функций.
/// Никакого исполнения строки как кода, системных вычислителей выражений и вызовов по имени: формула видит только
/// значения свойств своей записи и не имеет доступа к файлам и сети.

/// Положение в тексте формулы: номера символов (Character), а не байтов.
typealias FormulaRange = Range<Int>

enum FormulaLimits {
    static let maxSource = 4096
    static let maxDepth = 64
    /// Глубина дерева: цепочка «1+1+…» без скобок тоже растит её. Обход дерева рекурсивный, предел бережёт стек.
    static let maxTreeDepth = 128
    static let maxSteps = 10_000
    static let maxText = 64 * 1024
}

/// Ошибка с местом в тексте: интерфейс подчёркивает его.
struct FormulaError: Error, Equatable, LocalizedError {
    var message: String
    var range: FormulaRange

    init(_ key: String, _ args: CVarArg..., at range: FormulaRange) {
        message = String(format: NSLocalizedString(key, comment: ""), arguments: args)
        self.range = range
    }

    init(message: String, range: FormulaRange) {
        self.message = message
        self.range = range
    }

    var errorDescription: String? { message }
}

struct FormulaToken: Equatable {
    enum Kind: Equatable {
        case number(Double)
        case text(String)
        case name(String)
        case op(String)
        case open, close, comma, end
    }
    var kind: Kind
    var range: FormulaRange
}

enum FormulaLexer {
    private static let operators = ["==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/", "%", "^", "<", ">", "!"]

    static func tokens(_ source: String) throws -> [FormulaToken] {
        let chars = Array(source)
        guard chars.count <= FormulaLimits.maxSource else {
            throw FormulaError("Формула длиннее %ld символов.", FormulaLimits.maxSource, at: FormulaLimits.maxSource..<chars.count)
        }
        var out: [FormulaToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            let start = i
            if c.isASCII && c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
                if i < chars.count, chars[i] == ".", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                    i += 1
                    while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
                }
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                        i = j
                        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
                    }
                }
                guard let value = Double(String(chars[start..<i])), value.isFinite else {
                    throw FormulaError("Неверное число.", at: start..<i)
                }
                out.append(FormulaToken(kind: .number(value), range: start..<i))
                continue
            }
            if c == "\"" {
                i += 1
                var text = ""
                var closed = false
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "\"" { closed = true; i += 1; break }
                    if ch == "\\", i + 1 < chars.count {
                        switch chars[i + 1] {
                        case "u":
                            // \u{301}: так записывается знак, который иначе слился бы с кавычкой.
                            var j = i + 2
                            guard j < chars.count, chars[j] == "{" else { throw FormulaError("Неизвестная экранированная последовательность.", at: i..<(i + 2)) }
                            j += 1
                            var hex = ""
                            while j < chars.count, chars[j] != "}", hex.count <= 6 { hex.append(chars[j]); j += 1 }
                            guard j < chars.count, chars[j] == "}", let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                                throw FormulaError("Неизвестная экранированная последовательность.", at: i..<Swift.min(j + 1, chars.count))
                            }
                            text.unicodeScalars.append(scalar)
                            i = j + 1
                            continue
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        case "\"": text.append("\"")
                        case "\\": text.append("\\")
                        default: throw FormulaError("Неизвестная экранированная последовательность.", at: i..<(i + 2))
                        }
                        i += 2
                        continue
                    }
                    text.append(ch)
                    i += 1
                }
                guard closed else { throw FormulaError("Строка не закрыта кавычкой.", at: start..<chars.count) }
                out.append(FormulaToken(kind: .text(text), range: start..<i))
                continue
            }
            if c.isLetter || c == "_" {
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
                out.append(FormulaToken(kind: .name(String(chars[start..<i])), range: start..<i))
                continue
            }
            switch c {
            case "(": out.append(FormulaToken(kind: .open, range: i..<(i + 1))); i += 1; continue
            case ")": out.append(FormulaToken(kind: .close, range: i..<(i + 1))); i += 1; continue
            case ",": out.append(FormulaToken(kind: .comma, range: i..<(i + 1))); i += 1; continue
            default: break
            }
            if let op = operators.first(where: { op in
                let o = Array(op)
                return i + o.count <= chars.count && Array(chars[i..<(i + o.count)]) == o
            }) {
                out.append(FormulaToken(kind: .op(op), range: i..<(i + op.count)))
                i += op.count
                continue
            }
            throw FormulaError("Недопустимый символ «%@».", String(c), at: i..<(i + 1))
        }
        out.append(FormulaToken(kind: .end, range: chars.count..<chars.count))
        return out
    }
}

/// Дерево формулы. Ссылка на свойство после связывания хранит его ID.
indirect enum FormulaNode: Equatable {
    case number(Double, FormulaRange)
    case text(String, FormulaRange)
    case bool(Bool, FormulaRange)
    case property(UUID, FormulaRange)
    case call(String, [FormulaNode], FormulaRange)
    case unary(String, FormulaNode, FormulaRange)
    case binary(String, FormulaNode, FormulaNode, FormulaRange)

    var range: FormulaRange {
        switch self {
        case .number(_, let r), .text(_, let r), .bool(_, let r), .property(_, let r), .call(_, _, let r), .unary(_, _, let r), .binary(_, _, _, let r): return r
        }
    }

    /// Глубина дерева без рекурсии: её считают до любого рекурсивного обхода.
    var depth: Int {
        var deepest = 0
        var stack: [(FormulaNode, Int)] = [(self, 1)]
        while let (node, level) = stack.popLast() {
            deepest = Swift.max(deepest, level)
            switch node {
            case .call(_, let args, _): for a in args { stack.append((a, level + 1)) }
            case .unary(_, let e, _): stack.append((e, level + 1))
            case .binary(_, let a, let b, _): stack.append((a, level + 1)); stack.append((b, level + 1))
            default: break
            }
        }
        return deepest
    }

    /// Свойства, на которые ссылается формула: зависимости для пересчёта и поиска циклов.
    var properties: Set<UUID> {
        switch self {
        case .property(let id, _): return [id]
        case .call(_, let args, _): return args.reduce(into: []) { $0.formUnion($1.properties) }
        case .unary(_, let e, _): return e.properties
        case .binary(_, let l, let r, _): return l.properties.union(r.properties)
        default: return []
        }
    }
}

/// Рекурсивный спуск с приоритетами. Глубина ограничена: длинная цепочка скобок не исчерпает стек.
struct FormulaParser {
    private let tokens: [FormulaToken]
    private var pos = 0
    private var depth = 0

    static func parse(_ source: String) throws -> FormulaNode {
        var parser = FormulaParser(tokens: try FormulaLexer.tokens(source))
        guard parser.tokens.count > 1 else { throw FormulaError("Формула пуста.", at: 0..<0) }
        let node = try parser.expression()
        guard case .end = parser.peek.kind else {
            throw FormulaError("Лишний текст после выражения.", at: parser.peek.range)
        }
        guard node.depth <= FormulaLimits.maxTreeDepth else {
            throw FormulaError("Формула слишком сложная: больше %ld операций подряд. Разбейте её на несколько свойств.", FormulaLimits.maxTreeDepth, at: node.range)
        }
        return node
    }

    private init(tokens: [FormulaToken]) { self.tokens = tokens }

    private var peek: FormulaToken { tokens[pos] }

    private mutating func advance() -> FormulaToken {
        let t = tokens[pos]
        if pos < tokens.count - 1 { pos += 1 }
        return t
    }

    private func isOp(_ ops: Set<String>) -> String? {
        switch peek.kind {
        case .op(let o) where ops.contains(o): return o
        case .name(let n) where ops.contains(n): return n
        default: return nil
        }
    }

    private mutating func enter(_ at: FormulaRange) throws {
        depth += 1
        guard depth <= FormulaLimits.maxDepth else { throw FormulaError("Слишком глубокая вложенность.", at: at) }
    }

    /// Вложенность считается по выражениям, скобкам и вызовам, а не по уровням приоритета.
    private mutating func expression() throws -> FormulaNode {
        try enter(peek.range)
        defer { depth -= 1 }
        return try binary(level: 0)
    }

    /// Уровни: или < и < сравнение < сложение < умножение < степень (справа налево).
    private static let levels: [Set<String>] = [["or", "||"], ["and", "&&"], ["==", "!=", "<", "<=", ">", ">="], ["+", "-"], ["*", "/", "%"]]

    private mutating func binary(level: Int) throws -> FormulaNode {
        guard level < Self.levels.count else { return try power() }
        var left = try binary(level: level + 1)
        while let op = isOp(Self.levels[level]) {
            _ = advance()
            let right = try binary(level: level + 1)
            let canonical = op == "||" ? "or" : op == "&&" ? "and" : op
            left = .binary(canonical, left, right, left.range.lowerBound..<right.range.upperBound)
            // Сравнения не цепляются: «a < b < c» почти всегда ошибка.
            if level == 2, isOp(Self.levels[2]) != nil { throw FormulaError("Сравнения нельзя записывать цепочкой.", at: peek.range) }
        }
        return left
    }

    private mutating func power() throws -> FormulaNode {
        let base = try unary()
        if isOp(["^"]) != nil {
            _ = advance()
            try enter(peek.range)
            defer { depth -= 1 }
            let exponent = try power()
            return .binary("^", base, exponent, base.range.lowerBound..<exponent.range.upperBound)
        }
        return base
    }

    private mutating func unary() throws -> FormulaNode {
        if let op = isOp(["-", "not", "!"]) {
            let t = advance()
            try enter(t.range)
            defer { depth -= 1 }
            let operand = try unary()
            return .unary(op == "!" ? "not" : op, operand, t.range.lowerBound..<operand.range.upperBound)
        }
        return try primary()
    }

    private mutating func primary() throws -> FormulaNode {
        let t = advance()
        switch t.kind {
        case .number(let n): return .number(n, t.range)
        case .text(let s): return .text(s, t.range)
        case .open:
            try enter(t.range)
            defer { depth -= 1 }
            let inner = try expression()
            guard case .close = peek.kind else { throw FormulaError("Нет закрывающей скобки.", at: t.range.lowerBound..<peek.range.lowerBound) }
            let close = advance()
            return withRange(inner, t.range.lowerBound..<close.range.upperBound)
        case .name(let name):
            if name == "true" || name == "false" { return .bool(name == "true", t.range) }
            guard case .open = peek.kind else { throw FormulaError("Неизвестное имя «%@». Свойство записывается как prop(\"Имя\").", name, at: t.range) }
            _ = advance()
            try enter(t.range)
            defer { depth -= 1 }
            var args: [FormulaNode] = []
            if case .close = peek.kind {} else {
                while true {
                    args.append(try expression())
                    if case .comma = peek.kind { _ = advance(); continue }
                    break
                }
            }
            guard case .close = peek.kind else { throw FormulaError("Ожидалась запятая или закрывающая скобка.", at: peek.range) }
            let close = advance()
            return .call(name, args, t.range.lowerBound..<close.range.upperBound)
        case .end: throw FormulaError("Формула оборвалась.", at: t.range)
        default: throw FormulaError("Здесь ожидалось значение.", at: t.range)
        }
    }

    /// Скобки входят в место выражения: ошибка подчёркивает всю скобку.
    private func withRange(_ node: FormulaNode, _ r: FormulaRange) -> FormulaNode {
        switch node {
        case .number(let v, _): return .number(v, r)
        case .text(let v, _): return .text(v, r)
        case .bool(let v, _): return .bool(v, r)
        case .property(let v, _): return .property(v, r)
        case .call(let n, let a, _): return .call(n, a, r)
        case .unary(let o, let e, _): return .unary(o, e, r)
        case .binary(let o, let a, let b, _): return .binary(o, a, b, r)
        }
    }
}

/// Ссылки на свойства: пользователь пишет имя, хранится ID. Переименование свойства формулу не ломает.
enum FormulaReferences {
    /// Заменяет аргумент каждого `prop("…")`. `transform` возвращает новое значение или nil — оставить как есть.
    static func rewrite(_ source: String, _ transform: (String) -> String?) throws -> String {
        let chars = Array(source)
        let tokens = try FormulaLexer.tokens(source)
        var replacements: [(FormulaRange, String)] = []
        var i = 0
        while i + 3 < tokens.count {
            if case .name("prop") = tokens[i].kind, case .open = tokens[i + 1].kind, case .text(let arg) = tokens[i + 2].kind, case .close = tokens[i + 3].kind,
               let new = transform(arg) {
                replacements.append((tokens[i + 2].range, quote(new)))
            }
            i += 1
        }
        var out = ""
        var last = 0
        for (range, text) in replacements {
            out += String(chars[last..<range.lowerBound]) + text
            last = range.upperBound
        }
        return out + String(chars[last...])
    }

    static func quote(_ s: String) -> String {
        var body = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        // Знак в начале (ударение и т. п.) слился бы с открывающей кавычкой в один символ: он экранируется.
        if let first = body.unicodeScalars.first, [.nonspacingMark, .spacingMark, .enclosingMark].contains(first.properties.generalCategory) {
            body = "\\u{" + String(first.value, radix: 16) + "}" + String(String.UnicodeScalarView(body.unicodeScalars.dropFirst()))
        }
        return "\"" + body + "\""
    }

    /// Текст для хранения: имена → ID. Неизвестное имя остаётся и даст ошибку при проверке.
    static func toStorage(_ source: String, names: [String: UUID]) throws -> String {
        try rewrite(source) { name in names[name]?.uuidString }
    }

    /// Текст для показа: ID → текущие имена.
    static func toDisplay(_ stored: String, names: [UUID: String]) throws -> String {
        try rewrite(stored) { arg in UUID(uuidString: arg).flatMap { names[$0] } }
    }
}
