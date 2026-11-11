import Foundation

/// Отрезок текста с метками. На диске хранятся отрезки, а не смещения, поэтому формат не зависит от UTF-16.
struct TextRun: Equatable {
    var text: String
    /// Метки: b, i, u, s, code; неизвестные метки сохраняются.
    var marks: [String]
    /// Неизвестные поля отрезка.
    var extra: [String: JSONValue]

    init(_ text: String, marks: [String] = [], extra: [String: JSONValue] = [:]) {
        self.text = text
        self.marks = marks
        self.extra = extra
    }

    init?(json: JSONValue) {
        guard case .object(var o) = json, case .string(let t)? = o.removeValue(forKey: "t") else { return nil }
        text = t
        marks = []
        if case .array(let m)? = o.removeValue(forKey: "m") {
            marks = m.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        extra = o
    }

    var json: JSONValue {
        var o = extra
        o["t"] = .string(text)
        if !marks.isEmpty { o["m"] = .array(marks.map { .string($0) }) }
        return .object(o)
    }
}

/// Операции над последовательностью отрезков. Смещения — в единицах UTF-16, как у NSTextView.
enum RichText {
    static func plain(_ runs: [TextRun]) -> String { runs.map(\.text).joined() }

    static func length(_ runs: [TextRun]) -> Int { runs.reduce(0) { $0 + $1.text.utf16.count } }

    /// Заменяет диапазон текстом; вставка наследует метки отрезка слева. Границы приводятся к целым символам.
    static func replace(_ runs: [TextRun], range: Range<Int>, with text: String) -> [TextRun] {
        let total = plain(runs)
        let lower = snap(total, range.lowerBound), upper = max(lower, snap(total, range.upperBound))
        let (left, rest) = split(runs, at: lower)
        let (_, right) = split(rest, at: upper - lower)
        var out = left
        if !text.isEmpty {
            let source = left.last?.marks ?? right.first?.marks ?? []
            // Набор рядом с упоминанием — обычный текст: упоминание не растёт.
            let marks = source.filter { !Mention.isMentionMark($0, in: source) }
            let extra = left.last?.extra ?? right.first?.extra ?? [:]
            out.append(TextRun(text, marks: marks, extra: extra))
        }
        return normalized(out + right)
    }

    /// Делит отрезки по смещению. Смещение внутри составного символа сдвигается к его началу.
    static func split(_ runs: [TextRun], at offset: Int) -> (left: [TextRun], right: [TextRun]) {
        let target = snap(plain(runs), offset)
        var left: [TextRun] = [], right: [TextRun] = []
        var position = 0
        for run in runs {
            let n = run.text.utf16.count
            if position + n <= target {
                left.append(run)
            } else if position >= target {
                right.append(run)
            } else {
                let u = run.text.utf16
                let cut = u.index(u.startIndex, offsetBy: target - position)
                var a = run, b = run
                a.text = String(run.text[..<cut])
                b.text = String(run.text[cut...])
                left.append(a)
                right.append(b)
            }
            position += n
        }
        return (left, right)
    }

    /// Меняет метки в диапазоне; текст не меняется.
    static func mapMarks(_ runs: [TextRun], range: Range<Int>, _ transform: ([String]) -> [String]) -> [TextRun] {
        let (left, rest) = split(runs, at: range.lowerBound)
        let (middle, right) = split(rest, at: range.count)
        let changed = middle.map { run -> TextRun in
            var r = run
            r.marks = transform(run.marks)
            return r
        }
        return normalized(left + changed + right)
    }

    /// Весь текст диапазона несёт метку.
    static func hasMark(_ runs: [TextRun], range: Range<Int>, _ mark: String) -> Bool {
        let (_, rest) = split(runs, at: range.lowerBound)
        let (middle, _) = split(rest, at: range.count)
        return !middle.isEmpty && middle.allSatisfy { $0.marks.contains(mark) }
    }

    /// Склеивает соседние отрезки с одинаковыми метками и убирает пустые.
    static func normalized(_ runs: [TextRun]) -> [TextRun] {
        var out: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.marks == run.marks, last.extra == run.extra {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// Ближайшая граница целого символа (не позже смещения): emoji и составные символы не разрываются.
    static func snap(_ text: String, _ offset: Int) -> Int {
        let u = text.utf16
        let clamped = min(max(0, offset), u.count)
        // На конце строки символа нет: rangeOfComposedCharacterSequence бросил бы исключение.
        if clamped == u.count { return clamped }
        let index = u.index(u.startIndex, offsetBy: clamped)
        let snapped = text.rangeOfComposedCharacterSequence(at: index).lowerBound
        return u.distance(from: u.startIndex, to: snapped)
    }

    /// Минимальная замена, превращающая `old` в `new`: сохраняет форматирование неизменённых частей.
    static func diff(old: String, new: String) -> (range: Range<Int>, text: String)? {
        // Сравнение по скалярам: канонически равные NFC и NFD иначе дали бы расхождение поля и модели.
        func same(_ x: Character, _ y: Character) -> Bool { x.unicodeScalars.elementsEqual(y.unicodeScalars) }
        if old.unicodeScalars.elementsEqual(new.unicodeScalars) { return nil }
        let a = Array(old), b = Array(new)
        var p = 0
        while p < a.count && p < b.count && same(a[p], b[p]) { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && same(a[a.count - 1 - s], b[b.count - 1 - s]) { s += 1 }
        let lower = String(a[0..<p]).utf16.count
        let removed = String(a[p..<(a.count - s)]).utf16.count
        return (lower..<(lower + removed), String(b[p..<(b.count - s)]))
    }
}
