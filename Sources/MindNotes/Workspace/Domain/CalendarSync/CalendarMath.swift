import Foundation

/// Расчёты сетки календаря без UI: диапазоны видов, дни месяца и недели, шаг перетаскивания.
enum CalendarMath {
    enum Mode: String, CaseIterable, Codable, Sendable { case day, week, month }

    /// Видимый интервал вида.
    static func interval(_ mode: Mode, around date: Date, calendar: Calendar = .current) -> DateInterval {
        switch mode {
        case .day:
            let s = calendar.startOfDay(for: date)
            return DateInterval(start: s, end: calendar.date(byAdding: .day, value: 1, to: s)!)
        case .week:
            let days = weekDays(date, calendar: calendar)
            return DateInterval(start: days[0], end: calendar.date(byAdding: .day, value: 1, to: days[6])!)
        case .month:
            let days = monthGrid(date, calendar: calendar)
            return DateInterval(start: days[0], end: calendar.date(byAdding: .day, value: 1, to: days[41])!)
        }
    }

    /// 7 дней недели, начиная с первого дня недели календаря (в России — понедельник).
    static func weekDays(_ date: Date, calendar: Calendar = .current) -> [Date] {
        let day = calendar.startOfDay(for: date)
        let shift = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -shift, to: day)!
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }

    /// 42 дня сетки месяца: 6 недель, первая содержит 1-е число.
    static func monthGrid(_ date: Date, calendar: Calendar = .current) -> [Date] {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let start = weekDays(first, calendar: calendar)[0]
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    /// Шаг вида: на день, неделю или месяц вперёд или назад.
    static func step(_ mode: Mode, from date: Date, by n: Int, calendar: Calendar = .current) -> Date {
        switch mode {
        case .day: return calendar.date(byAdding: .day, value: n, to: date)!
        case .week: return calendar.date(byAdding: .weekOfYear, value: n, to: date)!
        case .month: return calendar.date(byAdding: .month, value: n, to: date)!
        }
    }

    /// Минуты от начала дня, округлённые до шага и ограниченные сутками.
    static func snap(minutes: Double, step: Int = 15) -> Int {
        let m = Int((minutes / Double(step)).rounded()) * step
        return min(max(m, 0), 24 * 60)
    }

    /// Момент дня `day` в `minutes` минут от полуночи (с учётом перехода на летнее время).
    static func moment(_ day: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: start)
            .map { minutes >= 24 * 60 ? calendar.date(byAdding: .day, value: 1, to: start)! : $0 } ?? start
    }

    /// Минуты от полуночи дня `day` до `date` по часам (а не по секундам: в день перевода часов их 23 или 25).
    static func minutes(of date: Date, in day: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: day)
        if date <= start { return 0 }
        if !calendar.isDate(date, inSameDayAs: start) { return 24 * 60 }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Перенос события: новое начало на `day` в `minutes`, длительность сохраняется.
    static func moved(start: Date, end: Date, toDay day: Date, minutes: Int, calendar: Calendar = .current) -> (Date, Date) {
        let s = moment(day, minutes: minutes, calendar: calendar)
        return (s, s.addingTimeInterval(end.timeIntervalSince(start)))
    }

    /// Новая длительность: конец не раньше начала + шаг.
    static func resized(start: Date, toEndMinutes minutes: Int, day: Date, step: Int = 15, calendar: Calendar = .current) -> Date {
        let e = moment(day, minutes: minutes, calendar: calendar)
        return max(e, start.addingTimeInterval(TimeInterval(step * 60)))
    }
}
