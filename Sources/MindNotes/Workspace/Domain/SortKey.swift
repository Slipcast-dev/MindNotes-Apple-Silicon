import Foundation

/// Дробные ключи порядка (base-62, сравнение побайтовое).
///
/// Ключ — целая часть (символ-длина + цифры) и необязательная дробная. Целая голова нужна, чтобы
/// добавление в конец почти не удлиняло ключ. Ключи не уникальны: при равенстве порядок решает id.
enum SortKey {
    /// После этой длины соседей перенумеровывают в той же транзакции.
    static let maxLength = 48

    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let base = 62
    private static let zero = digits[0]
    private static let smallestInteger = Array("A".utf8) + [UInt8](repeating: digits[0], count: 26)

    private static func index(_ b: UInt8) -> Int {
        switch b {
        case 48...57: return Int(b) - 48
        case 65...90: return Int(b) - 65 + 10
        case 97...122: return Int(b) - 97 + 36
        default: return 0
        }
    }

    static func isValid(_ key: String) -> Bool {
        let k = Array(key.utf8)
        guard let head = k.first, integerLength(head) != nil, k.allSatisfy({ digits.contains($0) }) else { return false }
        guard let n = integerLength(head), k.count >= n else { return false }
        if k.count > n && k.last == zero { return false }
        return Array(k.prefix(n)) != smallestInteger || k.count > n
    }

    /// Ключ строго между соседями; `nil` означает край списка.
    static func between(_ a: String?, _ b: String?) -> String {
        let aa = a.map { Array($0.utf8) }, bb = b.map { Array($0.utf8) }
        if let aa, let bb, !lessThan(aa, bb) {
            // Равные или перепутанные ключи бывают у данных старых версий; вставка не должна падать.
            return String(decoding: generate(aa, nil), as: UTF8.self)
        }
        return String(decoding: generate(aa, bb), as: UTF8.self)
    }

    /// `count` ключей подряд между соседями, для пакетной вставки.
    static func keys(after a: String?, before b: String?, count: Int) -> [String] {
        var out: [String] = []
        var previous = a
        for _ in 0..<count {
            let k = between(previous, b)
            out.append(k)
            previous = k
        }
        return out
    }

    private static func lessThan(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.lexicographicallyPrecedes(b) }

    private static func integerLength(_ head: UInt8) -> Int? {
        switch head {
        case 97...122: return Int(head) - 97 + 2
        case 65...90: return 90 - Int(head) + 2
        default: return nil
        }
    }

    private static func generate(_ a: [UInt8]?, _ b: [UInt8]?) -> [UInt8] {
        if a == nil && b == nil { return Array("a0".utf8) }
        guard let a else {
            let b = b!
            let ib = integerPart(b), fb = Array(b.dropFirst(ib.count))
            if ib == smallestInteger { return ib + midpoint([], fb) }
            if ib.count < b.count { return ib }
            return decrement(ib) ?? (ib + midpoint([], fb))
        }
        let ia = integerPart(a), fa = Array(a.dropFirst(ia.count))
        guard let b else {
            return increment(ia) ?? (ia + midpoint(fa, nil))
        }
        let ib = integerPart(b), fb = Array(b.dropFirst(ib.count))
        if ia == ib { return ia + midpoint(fa, fb) }
        if let next = increment(ia), lessThan(next, b) { return next }
        return ia + midpoint(fa, nil)
    }

    private static func integerPart(_ key: [UInt8]) -> [UInt8] {
        guard let head = key.first, let n = integerLength(head), key.count >= n else { return Array("a0".utf8) }
        return Array(key.prefix(n))
    }

    /// Дробная строка строго между a и b; b == nil означает «единица».
    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) -> [UInt8] {
        if let b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : zero) == b[n] { n += 1 }
            if n > 0 {
                return Array(b.prefix(n)) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let da = a.first.map(index) ?? 0
        let db = b?.first.map(index) ?? base
        if db - da > 1 {
            return [digits[(da + db + 1) / 2]]
        }
        if let b, b.count > 1 { return [b[0]] }
        return [digits[da]] + midpoint(Array(a.dropFirst()), nil)
    }

    private static func increment(_ x: [UInt8]) -> [UInt8]? {
        var head = x[0]
        var d = Array(x.dropFirst())
        var carry = true
        var i = d.count - 1
        while carry && i >= 0 {
            let v = index(d[i]) + 1
            if v == base { d[i] = zero } else { d[i] = digits[v]; carry = false }
            i -= 1
        }
        if !carry { return [head] + d }
        if head == 90 { return Array("a0".utf8) } // Z → a0
        if head == 122 { return nil }             // z: целая часть исчерпана
        head += 1
        if head > 97 { d.append(zero) } else { d.removeLast() }
        return [head] + d
    }

    private static func decrement(_ x: [UInt8]) -> [UInt8]? {
        var head = x[0]
        var d = Array(x.dropFirst())
        var borrow = true
        var i = d.count - 1
        while borrow && i >= 0 {
            let v = index(d[i]) - 1
            if v == -1 { d[i] = digits[base - 1] } else { d[i] = digits[v]; borrow = false }
            i -= 1
        }
        if !borrow { return [head] + d }
        if head == 97 { return Array("Z".utf8) + [digits[base - 1]] } // a → Zz
        if head == 65 { return nil }
        head -= 1
        if head < 90 { d.append(digits[base - 1]) } else { d.removeLast() }
        return [head] + d
    }
}
