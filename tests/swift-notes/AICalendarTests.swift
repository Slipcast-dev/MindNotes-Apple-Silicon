import Foundation

/// Инструменты Notes AI для Календаря: разбор ввода, свободные окна, текст для модели, правила подтверждения.
@MainActor
func runAICalendarTests() async {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    func d(_ s: String) -> Date { AICalendar.parseDate(s, calendar: cal)!.0 }
    func v(_ name: String, _ o: [String: JSONValue]) -> Result<AIToolCall, AITools.ValidationError> { AITools.validate(name: name, input: .object(o)) }

    await atest("ai calendar: инструменты появляются только при включённом доступе") {
        let names = { (defs: [JSONValue]) in defs.compactMap { $0["name"]?.stringValue } }
        check(!names(AITools.definitions()).contains("calendar_events"), "по умолчанию календаря нет")
        let with = names(AITools.definitions(calendar: true))
        check(AICalendar.toolNames.isSubset(of: Set(with)), "все шесть инструментов")
        checkEqual(with.count, names(AITools.definitions()).count + 6)
    }

    await atest("ai calendar: даты и время") {
        checkEqual(AICalendar.parseDate("2026-11-20", calendar: cal)?.1, false)
        checkEqual(AICalendar.parseDate("2026-11-20T14:30", calendar: cal)?.1, true)
        checkEqual(cal.component(.hour, from: d("2026-11-20 14:30")), 14, "пробел вместо T")
        check(AICalendar.parseDate("2026-02-30", calendar: cal) == nil, "несуществующий день")
        check(AICalendar.parseDate("20.11.2026", calendar: cal) == nil)
        check(AICalendar.parseDate("2026-11-20T25:00", calendar: cal) == nil)
    }

    await atest("ai calendar: проверка ввода инструментов") {
        guard case .success(.calendar(.createEvent(let e))) = v("calendar_create_event", [
            "title": "Встреча", "start": "2026-11-20T10:00", "end": "2026-11-20T11:30", "notes": ""]) else { return check(false, "событие") }
        check(!e.isAllDay && e.notes == nil)
        guard case .success(.calendar(.createEvent(let allDay))) = v("calendar_create_event", [
            "title": "Отпуск", "start": "2026-12-20", "end": "2026-12-27", "notes": "море"]) else { return check(false, "весь день") }
        check(allDay.isAllDay && allDay.notes == "море")
        if case .success = v("calendar_create_event", ["title": "X", "start": "2026-11-20T10:00", "end": "2026-11-20T09:00", "notes": ""]) {
            check(false, "конец раньше начала")
        }
        guard case .success(.calendar(.createReminder(let r))) = v("calendar_create_reminder", [
            "title": "Оплатить", "due": "2026-11-15", "notes": "", "priority": "высокий"]) else { return check(false, "напоминание") }
        check(!r.hasTime && r.priority == 1)
        guard case .success(.calendar(.moveEvent(let id, let occ, _, _))) = v("calendar_move_event", [
            "event_id": "ABC:1@1800000000", "start": "2026-11-21T10:00", "end": "2026-11-21T11:00"]) else { return check(false, "перенос") }
        checkEqual(id, "ABC:1")
        checkEqual(occ, Date(timeIntervalSince1970: 1_800_000_000))
        if case .success = v("calendar_events", ["from": "2026-01-01", "to": "2026-06-01"]) { check(false, "больше 62 дней") }
        if case .success = v("calendar_complete_reminder", ["reminder_id": "x", "done": "да"]) { check(false, "done — boolean") }
        if case .success = v("calendar_events", ["from": "2026-11-01", "to": "2026-11-02", "x": "1"]) { check(false, "лишнее поле") }
    }

    await atest("ai calendar: подтверждение") {
        let ev = AIToolCall.calendar(.createEvent(AIEventInput(title: "A", start: Date(), end: Date(), isAllDay: false, notes: nil)))
        check(AIPolicy.needsConfirmation(ev, confirmCreation: true))
        check(!AIPolicy.needsConfirmation(ev, confirmCreation: false), "создание — по настройке")
        check(AIPolicy.needsConfirmation(.calendar(.moveEvent(id: "x", occurrence: nil, start: Date(), end: Date())), confirmCreation: false),
              "перенос — всегда с вопросом")
        check(!AIPolicy.needsConfirmation(.calendar(.events(from: Date(), to: Date())), confirmCreation: true))
        check(!AIToolCall.calendar(.events(from: Date(), to: Date())).mutates)
    }

    await atest("ai calendar: свободные окна") {
        let day = d("2026-11-20")
        let busy = [(start: d("2026-11-20T10:00"), end: d("2026-11-20T11:00")),
                    (start: d("2026-11-20T10:30"), end: d("2026-11-20T12:00")),
                    (start: d("2026-11-20T15:00"), end: d("2026-11-20T15:20"))]
        let slots = AICalendar.freeSlots(busy: busy, day: day, minutes: 60, from: 9 * 60, to: 18 * 60, calendar: cal)
        let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "HH:mm"
        checkEqual(slots.map { "\(f.string(from: $0.start))-\(f.string(from: $0.end))" }, ["09:00-10:00", "12:00-15:00", "15:20-18:00"])
        checkEqual(AICalendar.freeSlots(busy: busy, day: day, minutes: 240, from: 9 * 60, to: 18 * 60, calendar: cal).count, 0)
    }

    await atest("ai calendar: текст для модели") {
        let e = AgendaEntry(id: "1", kind: .event, externalID: "EV1", title: "Планёрка", notes: nil, start: d("2026-11-20T10:00"),
                            end: d("2026-11-20T10:30"), isAllDay: false, isCompleted: false, isRecurring: true, isEditable: true,
                            calendarID: "c", calendarTitle: "Работа", color: 0)
        let r = AgendaEntry(id: "2", kind: .reminder, externalID: "RM1", title: "Оплатить", notes: nil, start: d("2026-11-20"),
                            end: d("2026-11-20"), isAllDay: true, isCompleted: true, isRecurring: false, isEditable: true,
                            calendarID: "l", calendarTitle: "Напоминания", color: 0)
        let text = AICalendar.eventsText([r, e], calendar: cal)
        check(text.contains("10:00–10:30 Планёрка [Работа] (повторяется) (event_id: EV1@"))
        check(text.contains("задача на день Оплатить [Напоминания] — выполнена (reminder_id: RM1)"))
        check(AICalendar.todayNote(d("2026-11-20T15:00"), calendar: cal).contains("2026-11-20"))
    }

    await atest("ai: дата со временем и диапазон в записях баз") {
        let p = PropertyDefinition(id: UUID(), databaseID: UUID(), name: "Срок", type: .date, sortKey: "a")
        checkEqual(AIValues.parse("2026-11-20", property: p), .date(DateValue(start: .day(LocalDate(iso: "2026-11-20")!))))
        guard case .date(let timed)? = AIValues.parse("2026-11-20T14:30", property: p), case .moment = timed.start else {
            return check(false, "время")
        }
        guard case .date(let range)? = AIValues.parse("2026-12-20/2026-12-27", property: p) else { return check(false, "диапазон") }
        checkEqual(range.end, .day(LocalDate(iso: "2026-12-27")!))
        check(AIValues.parse("завтра", property: p) == nil)
    }
}
