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
/// Один жест — ровно один шаг: инерция трекпада («докатка») игнорируется, у колеса мыши шаги идут не чаще
/// раза в 0,35 с, поэтому быстрая прокрутка не проскакивает несколько месяцев.
/// Работает, только пока курсор над календарём; вертикальная прокрутка часов в неделе не перехватывается.
struct ScrollPager: ViewModifier {
    let vertical: Bool
    let step: (Int) -> Void
    @State private var box = Box()

    final class Box {
        var hovering = false
        var monitor: Any?
        var accumulated: CGFloat = 0
        /// Жест трекпада уже дал свой шаг: до конца жеста больше не листаем.
        var fired = false
        var lastWheel = Date.distantPast
        /// Текущий жест — горизонтальный (в неделе и дне): его докатку тоже глотаем.
        var paging = false
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
                    let isMomentum = !e.momentumPhase.isEmpty
                    if e.phase == .began || e.phase == .mayBegin { box.paging = false }
                    // Докатка после жеста листания глотается, чтобы календарь не листался дальше;
                    // докатка прокрутки часов в неделе проходит как обычно.
                    if isMomentum { return vertical || box.paging ? nil : e }
                    if !vertical && along == 0 { return e }
                    box.paging = true

                    if e.hasPreciseScrollingDeltas {
                        // Трекпад: начало жеста сбрасывает счётчик, конец — разрешает следующий шаг.
                        if e.phase == .began || e.phase == .mayBegin { box.accumulated = 0; box.fired = false }
                        if !box.fired {
                            box.accumulated += along
                            if abs(box.accumulated) >= 40 {
                                step(box.accumulated > 0 ? -1 : 1)
                                box.fired = true
                            }
                        }
                        if e.phase == .ended || e.phase == .cancelled { box.accumulated = 0; box.fired = false }
                    } else {
                        // Колесо мыши: одно деление — один шаг.
                        if along != 0, Date().timeIntervalSince(box.lastWheel) > 0.35 {
                            step(along > 0 ? -1 : 1)
                            box.lastWheel = Date()
                        }
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
