import SwiftUI

/// Новое напоминание из календаря: правый щелчок по дню или по времени.
struct ReminderEditorSheet: View {
    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var listID: String
        var title = ""
        var notes = ""
        var due: Date
        var hasTime: Bool
        var priority = 0
    }

    @State var draft: Draft
    let lists: [CalendarInfo]
    let save: (Draft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(CalStyle.accent)
                Text(L("Новое напоминание")).font(CalStyle.titleFont(22)).foregroundStyle(CalStyle.ink)
            }
            TextField(L("Название"), text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(CalStyle.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CalStyle.line))
                .focused($titleFocused)
                .onSubmit(submit)
            CalCard {
                CalRow(L("Список")) {
                    Picker("", selection: $draft.listID) {
                        ForEach(lists) { l in Text(l.title).tag(l.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                CalDivider()
                CalRow(L("Дата")) {
                    DatePicker("", selection: $draft.due, displayedComponents: [.date]).labelsHidden().fixedSize()
                }
                CalDivider()
                CalRow(L("Время"), draft.hasTime ? L("Уведомление придёт в это время") : L("Весь день, без уведомления")) {
                    HStack(spacing: 8) {
                        if draft.hasTime {
                            DatePicker("", selection: $draft.due, displayedComponents: [.hourAndMinute]).labelsHidden().fixedSize()
                        }
                        Toggle("", isOn: $draft.hasTime).toggleStyle(.switch).labelsHidden()
                    }
                }
                CalDivider()
                CalRow(L("Приоритет")) {
                    Picker("", selection: $draft.priority) {
                        Text(L("Нет")).tag(0); Text(L("Низкий")).tag(9); Text(L("Средний")).tag(5); Text(L("Высокий")).tag(1)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            TextField(L("Заметки"), text: $draft.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(CalStyle.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CalStyle.line))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(CalStyle.danger) }
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(CalButtonStyle(kind: .normal)).keyboardShortcut(.cancelAction)
                Button(L("Добавить")) { submit() }.buttonStyle(CalButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(CalStyle.paper)
        .onAppear { titleFocused = true }
    }

    private func submit() {
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { error = L("Введите название"); return }
        if !lists.contains(where: { $0.id == draft.listID }) { error = L("Выберите список"); return }
        save(draft)
        dismiss()
    }
}

/// Листание календаря колесом мыши или жестом трекпада: месяц — по вертикали, неделя и день — по горизонтали.
/// Работает, только пока курсор над календарём; вертикальная прокрутка часов в неделе не перехватывается.
struct ScrollPager: ViewModifier {
    let vertical: Bool
    let step: (Int) -> Void
    @State private var box = Box()

    final class Box {
        var hovering = false
        var monitor: Any?
        var accumulated: CGFloat = 0
        var last = Date.distantPast
    }

    func body(content: Content) -> some View {
        content
            .onHover { box.hovering = $0 }
            .onAppear {
                let box = self.box
                let vertical = self.vertical
                let step = self.step
                box.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                    guard box.hovering else { return e }
                    let dy = e.scrollingDeltaY, dx = e.scrollingDeltaX
                    // В неделе вертикальная прокрутка — это часы; листаем только горизонтальным жестом.
                    let along = vertical ? (abs(dy) >= abs(dx) ? dy : dx) : (abs(dx) > abs(dy) ? dx : 0)
                    if !vertical && along == 0 { return e }
                    if e.phase == .began { box.accumulated = 0 }
                    // Колесо мыши даёт строки, трекпад — точки.
                    box.accumulated += e.hasPreciseScrollingDeltas ? along : along * 12
                    let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 70 : 10
                    if abs(box.accumulated) >= threshold, Date().timeIntervalSince(box.last) > 0.35 {
                        step(box.accumulated > 0 ? -1 : 1)
                        box.accumulated = 0
                        box.last = Date()
                    }
                    return nil
                }
            }
            .onDisappear {
                if let m = box.monitor { NSEvent.removeMonitor(m) }
                box.monitor = nil
            }
    }
}
