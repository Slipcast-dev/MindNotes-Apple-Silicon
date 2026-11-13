import SwiftUI

/// Создание и правка события из видов календаря.
struct EventEditorSheet: View {
    struct Draft: Identifiable, Equatable {
        var id: String { (externalID ?? "new") + "@\(occurrenceStart?.timeIntervalSince1970 ?? 0)" }
        var externalID: String?
        var occurrenceStart: Date?
        var isRecurring: Bool
        var calendarID: String
        var title: String
        var notes: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var recurrence: SyncRecurrence?
        var readOnly = false
    }

    enum Result { case save(Draft, EditSpan), delete(Draft, EditSpan) }

    @State var draft: Draft
    let calendars: [CalendarInfo]
    let done: (Result) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var askSpan: ((EditSpan) -> Void)?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Group { fields }.disabled(draft.readOnly)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            buttons
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(CalStyle.paper)
        .frame(width: 440)
        .confirmationDialog(L("Это повторяющееся событие"), isPresented: Binding(get: { askSpan != nil }, set: { if !$0 { askSpan = nil } })) {
            Button(L("Только это событие")) { askSpan?(.thisOnly); askSpan = nil }
            Button(L("Это и все следующие")) { askSpan?(.future); askSpan = nil }
            Button(L("Отмена"), role: .cancel) { askSpan = nil }
        }
        .confirmationDialog(L("Удалить событие «%@»?", draft.title), isPresented: $confirmDelete) {
            Button(L("Удалить"), role: .destructive) { done(.delete(draft, .thisOnly)); dismiss() }
        } message: { Text(L("Событие удалится и из Календаря.")) }
    }

    @ViewBuilder private var fields: some View {
            TextField(L("Название"), text: $draft.title).font(.title3)
            Picker(L("Календарь"), selection: $draft.calendarID) {
                ForEach(calendars) { c in
                    Label { Text(c.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(rgb: c.color)) }.tag(c.id)
                }
                if !calendars.contains(where: { $0.id == draft.calendarID }) { Text(L("Только для чтения")).tag(draft.calendarID) }
            }
            Toggle(L("Весь день"), isOn: $draft.isAllDay)
            DatePicker(L("Начало"), selection: Binding(get: { draft.start }, set: { new in
                // Конец сдвигается вместе с началом: длительность сохраняется.
                let len = draft.end.timeIntervalSince(draft.start)
                draft.start = new
                draft.end = new.addingTimeInterval(max(len, 0))
            }), displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
            if !draft.isAllDay {
                DatePicker(L("Конец"), selection: $draft.end, displayedComponents: [.date, .hourAndMinute])
            }
            Picker(L("Повтор"), selection: Binding(get: { draft.recurrence?.frequency }, set: { f in
                draft.recurrence = f.map { SyncRecurrence(frequency: $0, interval: draft.recurrence?.interval ?? 1, until: draft.recurrence?.until) }
            })) {
                Text(L("Никогда")).tag(SyncRecurrence.Frequency?.none)
                Text(L("Каждый день")).tag(SyncRecurrence.Frequency?.some(.daily))
                Text(L("Каждую неделю")).tag(SyncRecurrence.Frequency?.some(.weekly))
                Text(L("Каждый месяц")).tag(SyncRecurrence.Frequency?.some(.monthly))
                Text(L("Каждый год")).tag(SyncRecurrence.Frequency?.some(.yearly))
            }
            if draft.recurrence != nil {
                Stepper(L("Интервал: %d", draft.recurrence?.interval ?? 1),
                        value: Binding(get: { draft.recurrence?.interval ?? 1 }, set: { draft.recurrence?.interval = $0 }), in: 1...99)
                Toggle(L("Окончание повтора"), isOn: Binding(get: { draft.recurrence?.until != nil }, set: { on in
                    draft.recurrence?.until = on ? Calendar.current.date(byAdding: .month, value: 3, to: draft.start) : nil
                }))
                if let until = draft.recurrence?.until {
                    DatePicker(L("Последний день"), selection: Binding(get: { until }, set: { draft.recurrence?.until = $0 }),
                               in: draft.start..., displayedComponents: [.date])
                }
            }
            TextField(L("Заметки"), text: $draft.notes, axis: .vertical).lineLimit(3...8)
    }

    private var buttons: some View {
        HStack {
            if draft.externalID != nil && !draft.readOnly {
                Button(L("Удалить"), role: .destructive) {
                    if draft.isRecurring { askSpan = { done(.delete(draft, $0)); dismiss() } } else { confirmDelete = true }
                }
            }
            Spacer()
            Button(draft.readOnly ? L("Закрыть") : L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
            if !draft.readOnly {
                Button(L("Готово")) { save() }.keyboardShortcut(.defaultAction).buttonStyle(CalButtonStyle(kind: .primary))
            }
        }
    }

    private func save() {
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { error = L("Введите название"); return }
        if !draft.isAllDay && draft.end <= draft.start { error = L("Конец должен быть позже начала"); return }
        if draft.calendarID.isEmpty || !calendars.contains(where: { $0.id == draft.calendarID }) {
            error = L("Выберите календарь, в который можно писать"); return
        }
        if draft.isRecurring { askSpan = { done(.save(draft, $0)); dismiss() } }
        else { done(.save(draft, .future)); dismiss() }
    }
}
