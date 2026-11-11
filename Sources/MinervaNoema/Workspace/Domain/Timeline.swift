import Foundation

/// Масштаб шкалы Timeline (M11): ширина дня и длина видимого окна.
enum TimelineScale: String, CaseIterable, Codable {
    case day, week, month

    /// Точек на один день.
    var dayWidth: Double {
        switch self {
        case .day: return 36
        case .week: return 14
        case .month: return 4
        }
    }

    /// Шаг стрелок «назад/вперёд» в днях или месяцах.
    func step(_ anchor: LocalDate, forward: Bool) -> LocalDate {
        let sign = forward ? 1 : -1
        switch self {
        case .day: return anchor.adding(days: 14 * sign)
        case .week: return anchor.adding(days: 28 * sign)
        case .month: return anchor.addingMonths(3 * sign)
        }
    }
}

/// Видимое окно шкалы: первый день и число дней. Опорный день оказывается ближе к левому краю.
struct TimelineWindow: Equatable {
    let scale: TimelineScale
    let start: LocalDate
    let count: Int

    init(scale: TimelineScale, anchor: LocalDate) {
        self.scale = scale
        switch scale {
        case .day:
            start = anchor.adding(days: -7)
            count = 42
        case .week:
            let monday = anchor.adding(days: -anchor.weekdayFromMonday)
            start = monday.adding(days: -14)
            count = 26 * 7
        case .month:
            let first = anchor.firstOfMonth.addingMonths(-1)
            start = first
            count = first.days(to: first.addingMonths(12))
        }
    }

    var end: LocalDate { start.adding(days: count - 1) }
    var width: Double { Double(count) * scale.dayWidth }
    var days: [LocalDate] { (0..<count).map { start.adding(days: $0) } }

    func x(of day: LocalDate) -> Double { Double(start.days(to: day)) * scale.dayWidth }

    /// День под точкой шкалы; за краями — крайний день окна.
    func day(atX x: Double) -> LocalDate {
        let index = Int((x / scale.dayWidth).rounded(.down))
        return start.adding(days: min(count - 1, max(0, index)))
    }

    /// Полоса значения в окне: смещение и ширина в точках; часть за краями обрезана, вне окна — nil.
    func bar(_ value: DateValue) -> (x: Double, width: Double, clippedStart: Bool, clippedEnd: Bool)? {
        let first = value.start.localDay, last = (value.end ?? value.start).localDay
        guard first <= end, last >= start else { return nil }
        let a = max(first, start), b = min(last, end)
        return (x(of: a), Double(a.days(to: b) + 1) * scale.dayWidth, first < start, last > end)
    }

    /// Подписи шкалы: день — число, неделя — понедельник, месяц — первое число месяца.
    var ticks: [(day: LocalDate, major: Bool)] {
        days.compactMap { day in
            switch scale {
            case .day: return (day, day.day == 1 || day == start)
            case .week: return day.weekdayFromMonday == 0 ? (day, day.day <= 7) : nil
            case .month: return day.day == 1 ? (day, day.month == 1) : nil
            }
        }
    }
}

extension DatePoint {
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

    fileprivate var order: Int64 {
        switch self {
        case .day(let d): return Int64(LocalDate(year: 1970, month: 1, day: 1)!.days(to: d))
        case .moment(let ms, _): return ms
        }
    }
}

extension DateValue {
    /// Растягивание полосы за левый край: начало сдвигается, но не дальше конца.
    func resized(startBy days: Int) -> DateValue {
        let last = end ?? start
        var first = start.adding(days: days)
        if first.order > last.order { first = last }
        return DateValue(start: first, end: Self.endOrNil(first, last, had: end != nil))
    }

    /// Растягивание за правый край: конец сдвигается, но не раньше начала. Одна дата становится диапазоном.
    func resized(endBy days: Int) -> DateValue {
        var last = (end ?? start).adding(days: days)
        if last.order < start.order { last = start }
        return DateValue(start: start, end: Self.endOrNil(start, last, had: end != nil))
    }

    /// Диапазон, сжатый в одну точку, снова одна дата, если раньше конца не было.
    private static func endOrNil(_ first: DatePoint, _ last: DatePoint, had: Bool) -> DatePoint? {
        first == last && !had ? nil : last
    }
}
