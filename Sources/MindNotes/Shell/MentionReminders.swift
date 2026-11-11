import Foundation
import UserNotifications

/// Напоминания к датам упоминаний (M12): только локальные уведомления macOS, без серверов.
enum MentionReminders {
    /// `when` — `ГГГГ-ММ-ДДTЧЧ:ММ` по часам этого Mac. Разрешение спрашивается при первом напоминании.
    static func schedule(_ when: String, text: String, report: @escaping @MainActor (String) -> Void) {
        let parts = when.split(separator: "T")
        guard parts.count == 2, let day = LocalDate(iso: String(parts[0])) else { return }
        let clock = parts[1].split(separator: ":").compactMap { Int($0) }
        guard clock.count == 2 else { return }
        var components = DateComponents(year: day.year, month: day.month, day: day.day, hour: clock[0], minute: clock[1])
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        guard let date = components.date, date > Date() else {
            Task { @MainActor in report(L("Время напоминания уже прошло: уведомление не запланировано.")) }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Task { @MainActor in report(L("Уведомления выключены для MindNotes в Системных настройках: напоминание не придёт.")) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = L("Напоминание")
            content.body = text
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: "mention-" + UUID().uuidString, content: content, trigger: trigger))
        }
    }
}
