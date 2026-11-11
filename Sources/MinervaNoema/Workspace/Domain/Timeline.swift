import Foundation

/// Масштаб шкалы Timeline (M11): ширина дня, порция подгрузки и шаг прилипания.
enum TimelineScale: String, CaseIterable, Codable {
    case hour, day, week, month

    /// Точек на один день.
    var dayWidth: Double {
        switch self {
        case .hour: return 24 * 44
        case .day: return 36
        case .week: return 14
        case .month: return 4
        }
    }

    /// Дней в порции: столько добавляется, когда прокрутка подходит к краю шкалы.
    var chunkDays: Int {
        switch self {
        case .hour: return 7
        case .day: return 90
        case .week: return 26 * 7
        case .month: return 730
        }
    }

    /// Больше этого шкала не растёт: дальше окно перестраивается вокруг видимого дня.
    var maxDays: Int { chunkDays * 8 }

    /// Шаг переноса и растягивания в минутах: в масштабе «Часы» момент прилипает к 15 минутам, иначе — к дням.
    func snapMinutes(moment: Bool) -> Int { self == .hour && moment ? 15 : 1440 }
}

/// Шкала: первый день и число дней. Растёт порциями в обе стороны по мере прокрутки.
struct TimelineWindow: Equatable {
    let scale: TimelineScale
    let start: LocalDate
    let count: Int

    init(scale: TimelineScale, start: LocalDate, count: Int) {
        self.scale = scale
        self.start = start
        self.count = max(1, count)
    }

    /// Начальная шкала: порция до опорного дня и две после.
    init(scale: TimelineScale, anchor: LocalDate) {
        self.init(scale: scale, start: anchor.adding(days: -scale.chunkDays), count: scale.chunkDays * 3)
    }

    var end: LocalDate { start.adding(days: count - 1) }
    var width: Double { Double(count) * scale.dayWidth }
    var days: [LocalDate] { (0..<count).map { start.adding(days: $0) } }

    func x(of day: LocalDate) -> Double { Double(start.days(to: day)) * scale.dayWidth }

    /// Положение точки времени: момент — с долей суток по часам своего пояса.
    func x(of point: DatePoint) -> Double {
        x(of: point.localDay) + point.dayFraction * scale.dayWidth
    }

    /// День под точкой шкалы; за краями — крайний день.
    func day(atX x: Double) -> LocalDate {
        let index = Int((x / scale.dayWidth).rounded(.down))
        return start.adding(days: min(count - 1, max(0, index)))
    }

    /// Шкала, продлённая на порцию влево или вправо, и на сколько точек сдвинулось начало.
    func extended(before: Bool) -> (window: TimelineWindow, shift: Double) {
        let add = scale.chunkDays
        if before { return (TimelineWindow(scale: scale, start: start.adding(days: -add), count: count + add), Double(add) * scale.dayWidth) }
        return (TimelineWindow(scale: scale, start: start, count: count + add), 0)
    }

    var canGrow: Bool { count + scale.chunkDays <= scale.maxDays }

    /// Полоса значения: смещение и ширина в точках; часть за краями обрезана, вне шкалы — nil.
    /// Дни занимают клетки целиком, моменты стоят по времени суток, но не уже `minWidth`.
    func bar(_ value: DateValue, minWidth: Double = 6) -> (x: Double, width: Double, clippedStart: Bool, clippedEnd: Bool)? {
        let first = value.start.localDay, last = (value.end ?? value.start).localDay
        guard first <= end, last >= start else { return nil }
        let left: Double, right: Double
        switch (value.start, value.end ?? value.start) {
        case (.moment, .moment):
            left = x(of: value.start)
            right = max(x(of: value.end ?? value.start), left + minWidth)
        default:
            left = x(of: first)
            right = x(of: last) + scale.dayWidth
        }
        let a = max(0, left), b = min(width, right)
        guard b > a else { return nil }
        return (a, b - a, left < 0, right > width)
    }

    /// Деления: часы — каждый час, дни — каждый день, недели — понедельники, месяцы — первые числа.
    var ticks: [(day: LocalDate, hour: Int, major: Bool)] {
        days.flatMap { day -> [(day: LocalDate, hour: Int, major: Bool)] in
            switch scale {
            case .hour: return (0..<24).map { (day, $0, $0 == 0) }
            case .day: return [(day, 0, day.day == 1 || day == start)]
            case .week: return day.weekdayFromMonday == 0 ? [(day, 0, day.day <= 7)] : []
            case .month: return day.day == 1 ? [(day, 0, day.month == 1)] : []
            }
        }
    }
}

extension DatePoint {
    /// Доля суток по часам собственного пояса: 0 у дня без времени.
    var dayFraction: Double {
        guard case .moment = self else { return 0 }
        let text = localText
        guard text.count >= 16, let h = Int(text.dropFirst(11).prefix(2)), let m = Int(text.dropFirst(14).prefix(2)) else { return 0 }
        return Double(h * 60 + m) / 1440
    }

    /// Тот же момент на `days` дней позже по часам своего пояса: переход на летнее время не сдвигает час.
    func adding(days: Int) -> DatePoint {
        switch self {
        case .day(let d): return .day(d.adding(days: days))
        case .moment(let ms, let zone):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0) ?? .current
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)
            let moved = calendar.date(byAdding: .day, value: days, to: date) ?? date
            return .moment(ms: Int64((moved.timeIntervalSince1970 * 1000).rounded()), zone: zone)
        }
    }

    /// Сдвиг на минуты: целые сутки — по часам пояса, остаток — по реальному времени. День без времени сдвигается только целыми сутками.
    func adding(minutes: Int) -> DatePoint {
        let days = minutes / 1440, rest = minutes % 1440
        let shifted = adding(days: days)
        guard rest != 0, case .moment(let ms, let zone) = shifted else { return shifted }
        return .moment(ms: ms + Int64(rest) * 60_000, zone: zone)
    }

    fileprivate var order: Int64 {
        switch self {
        case .day(let d): return Int64(LocalDate(year: 1970, month: 1, day: 1)!.days(to: d))
        case .moment(let ms, _): return ms
        }
    }

    var isMoment: Bool { if case .moment = self { return true }; return false }
}

extension DateValue {
    /// Перенос на минуты целиком: длина сохраняется.
    func moved(byMinutes minutes: Int) -> DateValue {
        guard minutes % 1440 != 0 || start.isMoment else { return moved(byDays: minutes / 1440) }
        return DateValue(start: start.adding(minutes: minutes), end: end?.adding(minutes: minutes))
    }

    /// Растягивание полосы за левый край: начало сдвигается, но не дальше конца.
    func resized(startBy days: Int) -> DateValue { resized(startByMinutes: days * 1440) }
    func resized(endBy days: Int) -> DateValue { resized(endByMinutes: days * 1440) }

    func resized(startByMinutes minutes: Int) -> DateValue {
        let last = end ?? start
        var first = start.adding(minutes: minutes)
        if first.order > last.order { first = last }
        return DateValue(start: first, end: Self.endOrNil(first, last, had: end != nil))
    }

    /// Растягивание за правый край: конец сдвигается, но не раньше начала. Одна дата становится диапазоном.
    func resized(endByMinutes minutes: Int) -> DateValue {
        var last = (end ?? start).adding(minutes: minutes)
        if last.order < start.order { last = start }
        return DateValue(start: start, end: Self.endOrNil(start, last, had: end != nil))
    }

    /// Диапазон, сжатый в одну точку, снова одна дата, если раньше конца не было.
    private static func endOrNil(_ first: DatePoint, _ last: DatePoint, had: Bool) -> DatePoint? {
        first == last && !had ? nil : last
    }
}

/// Раскладка строк хронологии по высоте: заголовки групп и строки записей. Нужна для стрелок и переноса строк.
struct TimelineLayout {
    enum Item: Equatable {
        case header(section: String)
        case row(section: String, record: UUID)
    }

    static let rowHeight = 30.0
    static let headerHeight = 36.0

    private(set) var items: [(item: Item, y: Double, height: Double)] = []
    private var index: [UUID: Int] = [:]
    var height: Double { items.last.map { $0.y + $0.height } ?? 0 }

    /// `sections` — группы в порядке показа: ID группы, есть ли заголовок, записи.
    init(sections: [(id: String, header: Bool, records: [UUID])]) {
        var y = 0.0
        for section in sections {
            if section.header {
                items.append((.header(section: section.id), y, Self.headerHeight))
                y += Self.headerHeight
            }
            for record in section.records {
                index[record] = items.count
                items.append((.row(section: section.id, record: record), y, Self.rowHeight))
                y += Self.rowHeight
            }
        }
    }

    /// Середина строки записи по высоте; запись не на шкале — nil.
    func midY(_ record: UUID) -> Double? { index[record].map { items[$0].y + items[$0].height / 2 } }

    /// Запись под точкой по высоте.
    func record(atY y: Double) -> UUID? {
        guard let hit = items.first(where: { y >= $0.y && y < $0.y + $0.height }), case .row(_, let id) = hit.item else { return nil }
        return id
    }

    /// Куда встаёт перенесённая строка: группа и запись, перед которой (nil — в конец группы).
    /// Точка над заголовком группы ставит в начало этой группы.
    func drop(_ record: UUID, atY y: Double) -> (section: String, before: UUID?)? {
        guard !items.isEmpty else { return nil }
        let target = items.firstIndex(where: { y >= $0.y && y < $0.y + $0.height }) ?? (y < 0 ? 0 : items.count - 1)
        let hit = items[target]
        let group: String
        var from = target + 1
        switch hit.item {
        case .header(let s): group = s
        case .row(let s, _):
            group = s
            // Верхняя половина строки — встать перед ней, нижняя — после неё.
            if y < hit.y + hit.height / 2 { from = target }
        }
        // Первая строка той же группы от этого места, без самой переносимой.
        let before = items[min(from, items.count)...].lazy.compactMap { entry -> UUID? in
            guard case .row(let s, let id) = entry.item, s == group, id != record else { return nil }
            return id
        }.first
        return (group, before)
    }
}

/// Стрелка зависимости: запись `to` зависит от `from`. Конфликт — зависимая начинается раньше, чем кончается та, от которой она зависит.
struct TimelineDependency: Equatable {
    let from: UUID
    let to: UUID
    let conflict: Bool

    /// `values` — значения дат записей шкалы; `links` — для каждой записи, от каких она зависит.
    static func arrows(values: [UUID: DateValue], links: [UUID: [UUID]]) -> [TimelineDependency] {
        var out: [TimelineDependency] = []
        for (to, sources) in links.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let target = values[to] else { continue }
            for from in sources where from != to {
                guard let source = values[from] else { continue }
                let sourceEnd = (source.end ?? source.start)
                out.append(TimelineDependency(from: from, to: to, conflict: Self.before(target.start, sourceEnd)))
            }
        }
        return out
    }

    /// Начинается ли `a` раньше конца `b`: дни сравниваются целиком (тот же день — не конфликт для конца дня без времени).
    private static func before(_ a: DatePoint, _ b: DatePoint) -> Bool {
        switch (a, b) {
        case (.moment(let x, _), .moment(let y, _)): return x < y
        default: return a.localDay < b.localDay
        }
    }
}
