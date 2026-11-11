import Foundation

/// `@`-упоминание (M12): неделимый отрезок текста. Метка `@` отличает его от обычного текста,
/// вторая метка говорит, на что оно указывает: страница — обычная ссылка `PageLink` (поэтому обратные ссылки
/// и переход по щелчку работают как у `[[`), человек — `@p:ID`, дата — `@d:ГГГГ-ММ-ДД[TЧЧ:ММ]`.
/// Версии без M12 хранят метки как неизвестные и показывают подпись обычным текстом.
enum Mention {
    static let flag = "@"
    static let personPrefix = "@p:"
    static let datePrefix = "@d:"
    /// Напоминание к дате: время уведомления `ГГГГ-ММ-ДДTЧЧ:ММ` по часам этого Mac.
    static let reminderPrefix = "@r:"
    static let untitled = "Без названия"

    enum Target: Equatable {
        case page(UUID)
        case person(UUID)
        case date(String)
    }

    static func isMention(_ run: TextRun) -> Bool { run.marks.contains(flag) }

    static func target(of run: TextRun) -> Target? {
        guard isMention(run) else { return nil }
        for mark in run.marks {
            if let page = PageLink.page(fromMark: mark) { return .page(page) }
            if mark.hasPrefix(personPrefix), let id = UUID(uuidString: String(mark.dropFirst(personPrefix.count))) { return .person(id) }
            if mark.hasPrefix(datePrefix) { return .date(String(mark.dropFirst(datePrefix.count))) }
        }
        return nil
    }

    static func reminder(of run: TextRun) -> String? {
        run.marks.first { $0.hasPrefix(reminderPrefix) }.map { String($0.dropFirst(reminderPrefix.count)) }
    }

    /// Метки, которые принадлежат упоминанию и не переходят на набранный рядом текст.
    static func isMentionMark(_ mark: String, in marks: [String]) -> Bool {
        guard marks.contains(flag) else { return false }
        return mark == flag || mark.hasPrefix(personPrefix) || mark.hasPrefix(datePrefix) || mark.hasPrefix(reminderPrefix)
            || PageLink.page(fromMark: mark) != nil
    }

    static func pageLabel(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? untitled : clean
    }

    static func page(_ id: UUID, title: String) -> TextRun { TextRun(pageLabel(title), marks: [flag, PageLink.mark(id)]) }
    static func person(_ person: Person) -> TextRun { TextRun("@" + person.name, marks: [flag, personPrefix + person.id.uuidString.lowercased()]) }

    /// `iso` — `ГГГГ-ММ-ДД` или `ГГГГ-ММ-ДДTЧЧ:ММ`; подпись готовит оболочка на языке интерфейса.
    static func date(_ iso: String, label: String, reminder: String? = nil) -> TextRun? {
        guard validDate(iso) else { return nil }
        var marks = [flag, datePrefix + iso]
        if let reminder, validDate(reminder), reminder.contains("T") { marks.append(reminderPrefix + reminder) }
        return TextRun("@" + label, marks: marks)
    }

    static func validDate(_ iso: String) -> Bool {
        let parts = iso.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count <= 2, LocalDate(iso: String(parts[0])) != nil else { return false }
        guard parts.count == 2 else { return true }
        let clock = parts[1].split(separator: ":")
        guard clock.count == 2, clock.allSatisfy({ $0.count == 2 }), let h = Int(clock[0]), let m = Int(clock[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// Упоминания блока в смещениях UTF-16 его текста.
    static func ranges(in runs: [TextRun]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var position = 0
        for run in runs {
            let n = run.text.utf16.count
            if isMention(run) { out.append(position..<(position + n)) }
            position += n
        }
        return out
    }

    /// Правка, расширенная до целых упоминаний: часть упоминания не стирается и внутрь него не вставляется.
    /// Вставка внутрь уходит за его конец. nil — правка и так не задевает упоминания.
    static func atomic(_ range: Range<Int>, in runs: [TextRun]) -> Range<Int>? {
        var lower = range.lowerBound, upper = range.upperBound
        var changed = false
        for m in ranges(in: runs) {
            if range.isEmpty {
                if m.lowerBound < lower, lower < m.upperBound { return m.upperBound..<m.upperBound }
                continue
            }
            // Задевает часть упоминания: берётся целиком.
            if lower < m.upperBound, upper > m.lowerBound, lower > m.lowerBound || upper < m.upperBound {
                lower = min(lower, m.lowerBound)
                upper = max(upper, m.upperBound)
                changed = true
            }
        }
        return changed ? lower..<upper : nil
    }

    /// Подписи упоминаний страницы под новым заголовком. Ссылка `[[` тоже обновляется, если её текст
    /// совпадал с прежним заголовком: ссылку, подписанную вручную, переименование не трогает.
    /// nil — менять нечего.
    static func relabel(_ runs: [TextRun], page: UUID, old: String?, new: String) -> [TextRun]? {
        let mark = PageLink.mark(page)
        var changed = false
        let out = runs.map { run -> TextRun in
            guard run.marks.contains(mark) else { return run }
            var r = run
            if isMention(run) {
                r.text = pageLabel(new)
            } else if let old, run.text == old || run.text == pageLabel(old), !new.isEmpty {
                r.text = new
            }
            if r.text != run.text { changed = true }
            return r
        }
        return changed ? out : nil
    }

    static func relabel(_ runs: [TextRun], person: Person) -> [TextRun]? {
        let mark = personPrefix + person.id.uuidString.lowercased()
        var changed = false
        let out = runs.map { run -> TextRun in
            guard isMention(run), run.marks.contains(mark), run.text != "@" + person.name else { return run }
            changed = true
            var r = run
            r.text = "@" + person.name
            return r
        }
        return changed ? out : nil
    }
}
