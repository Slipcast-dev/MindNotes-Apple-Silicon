import Foundation

/// Расписание автоматических копий (FR-15): раз в сутки; хранятся 7 дневных и 4 недельные.
/// Решает только по датам: какие файлы удалять, выбирает вызывающий, и только среди автоматических копий.
enum BackupSchedule {
    static let interval: TimeInterval = 24 * 3600
    static let dailyKept = 7
    static let weeklyKept = 4

    static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        // Часы переведены назад: копия старше «будущей» даты не считается свежей.
        return now.timeIntervalSince(last) >= interval || last > now.addingTimeInterval(3600)
    }

    /// Оставляет новейшую копию каждого из 7 последних дней, где копии есть, и новейшую каждой из 4 предыдущих недель.
    /// Остальное — к удалению. Самая новая копия остаётся всегда.
    static func toDelete(_ items: [(id: String, date: Date)], calendar: Calendar = .current) -> Set<String> {
        let sorted = items.sorted { $0.date > $1.date }
        var keep: Set<String> = []
        var days: [DateComponents] = []
        var weeks: [DateComponents] = []
        for item in sorted {
            let day = calendar.dateComponents([.year, .month, .day], from: item.date)
            if days.contains(day) { continue }
            if days.count < dailyKept {
                days.append(day)
                keep.insert(item.id)
                continue
            }
            let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: item.date)
            if weeks.count < weeklyKept, !weeks.contains(week) {
                weeks.append(week)
                keep.insert(item.id)
            }
            days.append(day)
        }
        if let newest = sorted.first { keep.insert(newest.id) }
        return Set(items.map(\.id)).subtracting(keep)
    }
}
