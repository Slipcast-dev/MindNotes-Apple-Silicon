import AppKit
import Combine
import SwiftUI

/// Календарь в духе Apple Календаря: боковая панель с мини-месяцем и календарями, виды «День», «Неделя», «Месяц».
/// Читает и пишет EventKit напрямую; элементы приложения подтягиваются сверкой движка.
struct CalendarView: View {
    let engine: CalendarSyncEngine
    @AppStorage("calendarSync.viewMode") private var modeRaw = CalendarMath.Mode.week.rawValue
    @AppStorage("calendarSync.sidebar") private var showSidebar = true
    @State private var date = Date()
    @State private var entries: [AgendaEntry] = []
    @State private var draft: EventEditorSheet.Draft?
    @State private var pendingMove: PendingMove?
    @State private var error: String?
    @State private var reloadTick = 0
    @State private var reminderDraft: ReminderEditorSheet.Draft?

    struct PendingMove: Identifiable {
        let id = UUID()
        var entry: AgendaEntry
        var start: Date
        var end: Date
    }

    private var mode: CalendarMath.Mode { CalendarMath.Mode(rawValue: modeRaw) ?? .week }
    private var hasAccess: Bool { engine.status(.event) == .granted }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar && hasAccess {
                CalendarSidebar(engine: engine, date: $date)
                    .frame(width: 228)
                Rectangle().fill(CalStyle.line).frame(width: 1)
            }
            VStack(spacing: 0) {
                toolbar
                titleRow
                if !hasAccess {
                    Group {
                        // Доступ ещё не спрашивали — сразу системный запрос; отказали — подсказка, как вернуть.
                        if engine.status(.event) == .notDetermined {
                            CalCard { CalendarConnectCard(engine: engine) }
                        } else {
                            AccessDeniedBanner(kind: .event)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    Spacer()
                } else {
                    switch mode {
                    case .month:
                        MonthGridView(date: date, entries: entries,
                                      openDay: { date = $0; modeRaw = CalendarMath.Mode.day.rawValue },
                                      open: open, create: { create(day: $0, minutes: 9 * 60) },
                                      remind: { newReminder(day: $0, minutes: nil) })
                            .modifier(ScrollPager(vertical: true) { date = CalendarMath.step(.month, from: date, by: $0) })
                    case .week:
                        TimeGridView(days: CalendarMath.weekDays(date), entries: entries, open: open,
                                     create: { create(day: $0, minutes: $1) }, move: requestMove, toggle: toggle,
                                     selectDay: { date = $0; modeRaw = CalendarMath.Mode.day.rawValue },
                                     remind: { newReminder(day: $0, minutes: $1) })
                            .modifier(ScrollPager(vertical: false) { date = CalendarMath.step(.week, from: date, by: $0) })
                    case .day:
                        HStack(spacing: 0) {
                            TimeGridView(days: [Calendar.current.startOfDay(for: date)], entries: entries, open: open,
                                         create: { create(day: $0, minutes: $1) }, move: requestMove, toggle: toggle,
                                         selectDay: { _ in }, remind: { newReminder(day: $0, minutes: $1) })
                                .modifier(ScrollPager(vertical: false) { date = CalendarMath.step(.day, from: date, by: $0) })
                            Rectangle().fill(CalStyle.line).frame(width: 1)
                            DaySummaryView(date: date, entries: entries, open: open, toggle: toggle)
                                .frame(width: 260)
                        }
                    }
                }
            }
            .background(CalStyle.paper)
        }
        .task(id: "\(modeRaw)|\(date.timeIntervalSince1970)|\(engine.settings.lastSyncAt?.timeIntervalSince1970 ?? 0)|\(reloadTick)|\(engine.settings.visibleCalendarIDs?.count ?? -1)|\(hasAccess)") {
            await load()
        }
        .onAppear { engine.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            engine.refreshAccess()
            reloadTick += 1
        }
        .sheet(item: $reminderDraft) { d in
            ReminderEditorSheet(draft: d, lists: engine.gateway.containers(.reminder).filter(\.isEditable)) { saveReminder($0) }
        }
        .sheet(item: $draft) { d in
            EventEditorSheet(draft: d, calendars: engine.gateway.containers(.event).filter(\.isEditable)) { apply($0) }
        }
        .confirmationDialog(L("Это повторяющееся событие"), isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
                            presenting: pendingMove) { m in
            Button(L("Только это событие")) { commitMove(m, span: .thisOnly) }
            Button(L("Это и все следующие")) { commitMove(m, span: .future) }
            Button(L("Отмена"), role: .cancel) { pendingMove = nil }
        }
        .alert(L("Не удалось сохранить"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: Панель инструментов: как в Календаре — слева календари и «+», по центру вид.

    private var toolbar: some View {
        ZStack {
            HStack(spacing: 2) {
                Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(L("Показывать календари"))
                    .disabled(!hasAccess)
                Button { create(day: date, minutes: nextSlot()) } label: { Image(systemName: "plus") }
                    .help(L("Новое событие"))
                    .disabled(!hasAccess)
                    .keyboardShortcut("n", modifiers: [.command])
                Spacer()
            }
            .buttonStyle(CalButtonStyle(kind: .plain))
            SegmentedModes(selection: $modeRaw)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(CalStyle.line).frame(height: 1) }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title
            Spacer()
            HStack(spacing: 0) {
                Button { date = CalendarMath.step(mode, from: date, by: -1) } label: { Image(systemName: "chevron.left") }
                    .help(L("Назад"))
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button(L("Сегодня")) { date = Date() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button { date = CalendarMath.step(mode, from: date, by: 1) } label: { Image(systemName: "chevron.right") }
                    .help(L("Вперёд"))
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
            .buttonStyle(CalButtonStyle(kind: .normal))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// «Ноябрь 2026»: месяц тёмным, год приглушённым — как в Календаре.
    @ViewBuilder private var title: some View {
        let month = standaloneMonth(date)
        let year = date.formatted(.dateTime.year())
        switch mode {
        case .day:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(date.formatted(.dateTime.day().month(.wide))).font(CalStyle.titleFont(28)).foregroundStyle(CalStyle.ink)
                Text(year).font(CalStyle.titleFont(28)).foregroundStyle(CalStyle.muted)
                Text(date.formatted(.dateTime.weekday(.wide))).font(.system(size: 15)).foregroundStyle(CalStyle.muted).padding(.leading, 6)
            }
        case .week, .month:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(month.prefix(1).uppercased() + month.dropFirst()).font(CalStyle.titleFont(28)).foregroundStyle(CalStyle.ink)
                Text(year).font(CalStyle.titleFont(28)).foregroundStyle(CalStyle.muted)
            }
        }
    }

    private func nextSlot() -> Int {
        let now = Date()
        guard Calendar.current.isDate(now, inSameDayAs: date) else { return 9 * 60 }
        return min(CalendarMath.snap(minutes: CalendarMath.minutes(of: now, in: now) + 30, step: 30), 23 * 60)
    }

    private func load() async {
        guard hasAccess || engine.status(.reminder) == .granted else { entries = []; return }
        let visible = engine.settings.visibleCalendarIDs
        let lists = engine.gateway.containers(.reminder).map(\.id).filter { visible?.contains($0) ?? true }
        entries = await engine.gateway.agenda(CalendarMath.interval(mode, around: date),
                                              calendarIDs: engine.settings.visibleCalendarIDs, reminderListIDs: lists)
    }

    // MARK: Действия

    /// Правый щелчок «Новое напоминание»: при необходимости сначала спрашивается доступ к Напоминаниям.
    private func newReminder(day: Date, minutes: Int?) {
        Task {
            if engine.status(.reminder) != .granted {
                _ = await engine.gateway.requestAccess(.reminder)
                engine.refreshAccess()
            }
            guard engine.status(.reminder) == .granted else { error = L("Нет доступа к Напоминаниям"); return }
            let lists = engine.gateway.containers(.reminder).filter(\.isEditable)
            let preferred = [engine.settings.reminderListID, engine.gateway.defaultReminderListID()].compactMap { $0 }
            let list = preferred.first { id in lists.contains { $0.id == id } } ?? lists.first?.id ?? ""
            let due = CalendarMath.moment(day, minutes: minutes ?? 9 * 60)
            reminderDraft = .init(listID: list, due: due, hasTime: minutes != nil)
        }
    }

    private func saveReminder(_ d: ReminderEditorSheet.Draft) {
        do {
            try engine.gateway.saveReminder(ReminderDraft(listID: d.listID, title: d.title, notes: d.notes.isEmpty ? nil : d.notes,
                                                          due: d.due, hasTime: d.hasTime, priority: d.priority))
        } catch { self.error = "\(error)" }
        reloadTick += 1
    }

    private func create(day: Date, minutes: Int) {
        let start = CalendarMath.moment(day, minutes: minutes)
        let cal = engine.settings.eventCalendarID
            ?? engine.gateway.containers(.event).first(where: \.isEditable)?.id ?? ""
        draft = .init(externalID: nil, occurrenceStart: nil, isRecurring: false, calendarID: cal, title: "", notes: "",
                      start: start, end: start.addingTimeInterval(3600), isAllDay: false, recurrence: nil)
    }

    private func open(_ e: AgendaEntry) {
        guard e.kind == .event else { toggle(e); return }
        draft = .init(externalID: e.externalID, occurrenceStart: e.start, isRecurring: e.isRecurring, calendarID: e.calendarID,
                      title: e.title, notes: e.notes ?? "", start: e.start, end: e.end, isAllDay: e.isAllDay,
                      recurrence: engine.gateway.lookup([e.externalID], kind: .event).first?.fields.recurrence,
                      readOnly: !e.isEditable)
    }

    private func toggle(_ e: AgendaEntry) {
        guard e.kind == .reminder, e.isEditable else { return }
        do { try engine.gateway.setReminderCompleted(externalID: e.externalID, !e.isCompleted) } catch { self.error = "\(error)" }
        reloadTick += 1
    }

    private func requestMove(_ e: AgendaEntry, _ start: Date, _ end: Date) {
        guard e.isEditable, start != e.start || end != e.end else { return }
        if e.isRecurring { pendingMove = PendingMove(entry: e, start: start, end: end) }
        else { commitMove(PendingMove(entry: e, start: start, end: end), span: .thisOnly) }
    }

    private func commitMove(_ m: PendingMove, span: EditSpan) {
        pendingMove = nil
        let e = m.entry
        var d = EventDraft(externalID: e.externalID, occurrenceStart: e.start, calendarID: e.calendarID, title: e.title,
                           notes: e.notes, start: m.start, end: m.end, isAllDay: e.isAllDay, recurrence: nil, alarmMinutes: nil)
        // Серии передаётся её текущее правило: шлюз сравнит его с сохранённым и не тронет повтор.
        if e.isRecurring { d.recurrence = engine.gateway.lookup([e.externalID], kind: .event).first?.fields.recurrence }
        do { try engine.gateway.saveEvent(d, span: span) } catch { self.error = "\(error)" }
        reloadTick += 1
    }

    private func apply(_ r: EventEditorSheet.Result) {
        do {
            switch r {
            case .save(let d, let span):
                try engine.gateway.saveEvent(EventDraft(externalID: d.externalID, occurrenceStart: d.occurrenceStart,
                                                        calendarID: d.calendarID, title: d.title,
                                                        notes: d.notes.isEmpty ? nil : d.notes,
                                                        start: d.start, end: d.isAllDay ? d.start : d.end, isAllDay: d.isAllDay,
                                                        recurrence: d.recurrence,
                                                        alarmMinutes: d.externalID == nil ? engine.settings.defaultAlarmMinutes : nil),
                                             span: span)
            case .delete(let d, let span):
                if let id = d.externalID { try engine.gateway.deleteEvent(externalID: id, occurrenceStart: d.occurrenceStart, span: span) }
            }
        } catch { self.error = "\(error)" }
        reloadTick += 1
    }
}

// MARK: Переключатель видов

struct SegmentedModes: View {
    @Binding var selection: String
    private let modes: [(CalendarMath.Mode, String, KeyEquivalent)] = [(.day, L("День"), "1"), (.week, L("Неделя"), "2"), (.month, L("Месяц"), "3")]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.0) { m, title, key in
                let on = selection == m.rawValue
                Button { selection = m.rawValue } label: {
                    Text(title)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? CalStyle.ink : CalStyle.muted)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? CalStyle.card : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? CalStyle.line : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(key, modifiers: [.command])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(CalStyle.soft))
    }
}

// MARK: Боковая панель: мини-месяц и календари

struct CalendarSidebar: View {
    let engine: CalendarSyncEngine
    @Binding var date: Date
    @State private var shown = Date()
    @State private var calendars: [CalendarInfo] = []
    @State private var lists: [CalendarInfo] = []
    /// Календарь, который сейчас переименовывается прямо в списке (как в Календаре).
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: CalendarInfo?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    /// Цвета Календаря macOS.
    static let palette: [(String, UInt32)] = [
        (L("Красный"), 0xFF3B30), (L("Оранжевый"), 0xFF9500), (L("Жёлтый"), 0xFFCC00), (L("Зелёный"), 0x34C759),
        (L("Голубой"), 0x5AC8FA), (L("Синий"), 0x007AFF), (L("Фиолетовый"), 0xAF52DE), (L("Розовый"), 0xFF2D55),
        (L("Коричневый"), 0xA2845E), (L("Графит"), 0x8E8E93),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MiniMonth(date: $date, shown: $shown)
                ForEach(groups(calendars), id: \.0) { source, cals in
                    section(source.isEmpty ? L("Другие") : source, cals, kind: .event)
                }
                ForEach(groups(lists), id: \.0) { source, cals in
                    section(lists.count == cals.count ? L("Напоминания") : L("Напоминания · %@", source), cals, kind: .reminder)
                }
            }
            .padding(14)
        }
        .background(CalStyle.side)
        .onAppear { reload(); shown = date }
        .onChange(of: date) { _, d in shown = d }
        .onChange(of: engine.settings.lastSyncAt) { _, _ in reload() }
        .confirmationDialog(L("Удалить «%@»?", deleting?.title ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { c in
            Button(L("Удалить"), role: .destructive) { remove(c) }
            Button(L("Отмена"), role: .cancel) { deleting = nil }
        } message: { c in
            Text(c.id == engine.settings.containerID(.event) || c.id == engine.settings.containerID(.reminder)
                 ? L("Это календарь синхронизации: все его элементы удалятся на всех устройствах, а синхронизация этого вида выключится. Включить её снова можно в настройках.")
                 : L("Все элементы удалятся на всех устройствах. Действие нельзя отменить."))
        }
        .alert(L("Не удалось изменить календарь"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func reload() {
        calendars = engine.gateway.containers(.event)
        lists = engine.gateway.containers(.reminder)
    }

    private func groups(_ items: [CalendarInfo]) -> [(String, [CalendarInfo])] {
        Dictionary(grouping: items, by: \.source).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func section(_ title: String, _ cals: [CalendarInfo], kind: SyncKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(CalStyle.muted).lineLimit(1)
                Spacer()
                // «+» — новый календарь или список в этом источнике, сразу с полем для названия.
                if let source = cals.first(where: \.canEditCalendar)?.sourceID {
                    Button { create(kind, sourceID: source) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(CalStyle.muted)
                        .help(kind == .event ? L("Новый календарь") : L("Новый список"))
                }
            }
            ForEach(cals) { c in row(c) }
        }
    }

    private func visible(_ id: String) -> Bool { engine.settings.visibleCalendarIDs?.contains(id) ?? true }

    private func setVisible(_ id: String, _ on: Bool) {
        let all = Set((calendars + lists).map(\.id))
        var ids = engine.settings.visibleCalendarIDs ?? all
        if on { ids.insert(id) } else { ids.remove(id) }
        engine.setVisibleCalendars(ids.isSuperset(of: all) ? nil : ids)
    }

    private func row(_ c: CalendarInfo) -> some View {
        HStack(spacing: 8) {
            // Флажок — отдельная кнопка: щелчок по названию его не переключает.
            Button { setVisible(c.id, !visible(c.id)) } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(visible(c.id) ? Color(rgb: c.color) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(rgb: c.color), lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .opacity(visible(c.id) ? 1 : 0))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(c.title))
            .accessibilityValue(Text(visible(c.id) ? L("Показан") : L("Скрыт")))

            if renaming == c.id {
                TextField("", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(CalStyle.card))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(CalStyle.accent))
                    .focused($nameFocused)
                    .onSubmit { commitRename(c) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: nameFocused) { _, f in if !f && renaming == c.id { commitRename(c) } }
            } else {
                Text(c.title).font(.system(size: 13)).foregroundStyle(CalStyle.ink).lineLimit(1)
                    .onTapGesture(count: 2) { if c.canEditCalendar { startRename(c) } }
                if !c.isEditable { Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(CalStyle.muted) }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Показать только этот")) { engine.setVisibleCalendars([c.id]) }
            Button(L("Показать все")) { engine.setVisibleCalendars(nil) }
            if c.canEditCalendar {
                Divider()
                Button(L("Переименовать…")) { startRename(c) }
                Menu(L("Цвет")) {
                    ForEach(Self.palette, id: \.1) { name, rgb in
                        Button { recolor(c, rgb) } label: {
                            Label { Text(name) } icon: { Image(nsImage: Self.swatch(rgb)) }
                        }
                    }
                }
                Divider()
                Button(L("Удалить…"), role: .destructive) { deleting = c }
            }
        }
        .help(c.canEditCalendar ? L("Двойной щелчок — переименовать, правый щелчок — цвет и удаление")
              : (c.isEditable ? c.title : L("Только для чтения")))
    }

    // MARK: Правка календарей

    private func startRename(_ c: CalendarInfo) {
        newName = c.title
        renaming = c.id
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename(_ c: CalendarInfo) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, name != c.title else { return }
        do { try engine.gateway.updateContainer(c.id, title: name, color: nil) } catch { self.error = "\(error)" }
        reload()
    }

    private func recolor(_ c: CalendarInfo, _ rgb: UInt32) {
        do { try engine.gateway.updateContainer(c.id, title: nil, color: rgb) } catch { self.error = "\(error)" }
        reload()
        engine.scheduleSync()   // виды календаря перечитают цвета
    }

    private func create(_ kind: SyncKind, sourceID: String) {
        do {
            let title = kind == .event ? L("Новый календарь") : L("Новый список")
            let id = try engine.gateway.createContainer(kind, title: title, color: Self.palette[5].1, sourceID: sourceID)
            reload()
            if let c = (calendars + lists).first(where: { $0.id == id }) { startRename(c) }
        } catch { self.error = "\(error)" }
    }

    private func remove(_ c: CalendarInfo) {
        deleting = nil
        do { try engine.gateway.removeContainer(c.id) } catch { self.error = "\(error)" }
        reload()
        engine.scheduleSync()
    }

    /// Кружок цвета для меню (в меню macOS цвет SwiftUI-иконки не сохраняется, поэтому картинка).
    static func swatch(_ rgb: UInt32) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

struct MiniMonth: View {
    @Binding var date: Date
    @Binding var shown: Date

    var body: some View {
        let cal = Calendar.current
        let days = CalendarMath.monthGrid(shown)
        VStack(spacing: 6) {
            HStack {
                Text(standaloneMonth(shown).capitalized + " " + shown.formatted(.dateTime.year())).font(.system(size: 13, weight: .semibold)).foregroundStyle(CalStyle.ink)
                Spacer()
                Button { shown = cal.date(byAdding: .month, value: -1, to: shown)! } label: { Image(systemName: "chevron.left") }
                Button { shown = cal.date(byAdding: .month, value: 1, to: shown)! } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(days.prefix(7), id: \.self) {
                    Text($0.formatted(.dateTime.weekday(.narrow))).font(.system(size: 10)).foregroundStyle(CalStyle.muted)
                }
                ForEach(days, id: \.self) { d in
                    let today = cal.isDateInToday(d)
                    let selected = cal.isDate(d, inSameDayAs: date)
                    let inMonth = cal.isDate(d, equalTo: shown, toGranularity: .month)
                    Button { date = d } label: {
                        Text("\(cal.component(.day, from: d))")
                            .font(.system(size: 11, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? Color.white : (inMonth ? CalStyle.ink : CalStyle.muted.opacity(0.5)))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(today ? Color.red : (selected ? CalStyle.soft : .clear)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Месяц

struct MonthGridView: View {
    let date: Date
    let entries: [AgendaEntry]
    let openDay: (Date) -> Void
    let open: (AgendaEntry) -> Void
    let create: (Date) -> Void
    let remind: (Date) -> Void

    var body: some View {
        let days = CalendarMath.monthGrid(date)
        let cal = Calendar.current
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 12)).foregroundStyle(CalStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8).padding(.vertical, 4)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(CalStyle.line).frame(height: 1) }
            GeometryReader { geo in
                let h = geo.size.height / 6
                let limit = max(Int((h - 26) / 17), 1)
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(days[(row * 7)..<(row * 7 + 7)], id: \.self) { d in
                                cell(d, inMonth: cal.isDate(d, equalTo: date, toGranularity: .month), limit: limit)
                                    .frame(height: h)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, inMonth: Bool, limit: Int) -> some View {
        let cal = Calendar.current
        let items = entries.filter { e in
            e.isAllDay || e.kind == .reminder ? cal.isDate(e.start, inSameDayAs: day)
                : e.start < cal.date(byAdding: .day, value: 1, to: day)! && e.end > day
        }.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
        let today = cal.isDateInToday(day)
        let weekend = cal.isDateInWeekend(day)
        let first = cal.component(.day, from: day) == 1
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Spacer()
                Text(first ? day.formatted(.dateTime.day().month(.abbreviated)) : "\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: today ? .semibold : .regular))
                    .foregroundStyle(today ? Color.white : (inMonth ? CalStyle.ink : CalStyle.muted.opacity(0.6)))
                    .padding(.horizontal, today ? 6 : 0).frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(today ? Color.red : .clear))
            }
            .padding(.top, 3).padding(.trailing, 4)
            ForEach(items.prefix(limit)) { e in
                Button { open(e) } label: { MonthEventLine(entry: e) }.buttonStyle(.plain)
            }
            if items.count > limit {
                Button(L("ещё %d", items.count - limit)) { openDay(day) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CalStyle.muted).padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Будни светлые, выходные темнее — и в этом месяце, и в соседних.
        .background(weekend ? CalStyle.soft.opacity(0.55) : CalStyle.paper)
        .overlay(alignment: .trailing) { Rectangle().fill(CalStyle.line).frame(width: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(CalStyle.line).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { create(day) }
        .onTapGesture { openDay(day) }
        .contextMenu {
            Button { remind(day) } label: { Label(L("Новое напоминание…"), systemImage: "checklist") }
            Button { create(day) } label: { Label(L("Новое событие…"), systemImage: "calendar.badge.plus") }
            Divider()
            Button { openDay(day) } label: { Label(L("Открыть день"), systemImage: "calendar.day.timeline.left") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }
}

/// Строка события в месяце: событие на весь день — цветная плашка, остальные — точка, название и время.
struct MonthEventLine: View {
    let entry: AgendaEntry

    var body: some View {
        let color = Color(rgb: entry.color)
        HStack(spacing: 4) {
            if entry.kind == .reminder {
                Image(systemName: entry.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 9)).foregroundStyle(color)
            } else if !entry.isAllDay {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(entry.title.isEmpty ? L("Без названия") : entry.title)
                .font(.system(size: 11, weight: entry.isAllDay ? .medium : .regular))
                .foregroundStyle(entry.isAllDay ? Color.white : CalStyle.ink)
                .strikethrough(entry.isCompleted)
                .lineLimit(1)
            Spacer(minLength: 2)
            if !entry.isAllDay {
                Text(entry.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(CalStyle.muted)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(entry.isAllDay ? color : .clear))
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
    }
}

// MARK: День и неделя

struct TimeGridView: View {
    let days: [Date]
    let entries: [AgendaEntry]
    let open: (AgendaEntry) -> Void
    let create: (Date, Int) -> Void
    let move: (AgendaEntry, Date, Date) -> Void
    let toggle: (AgendaEntry) -> Void
    let selectDay: (Date) -> Void
    let remind: (Date, Int) -> Void

    private let hourHeight: CGFloat = 52
    /// Где курсор: правый щелчок создаёт напоминание или событие на это время. Класс — чтобы движение мыши не перерисовывало сетку.
    @State private var pointer = Pointer()
    final class Pointer { var minutes = 9 * 60 }
    private let gutter: CGFloat = 56
    @State private var drag: DragState?
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    struct DragState: Equatable {
        var id: String
        var resize: Bool
        var dx: CGFloat
        var dy: CGFloat
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            allDayStrip
            Rectangle().fill(CalStyle.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in grid(width: geo.size.width) }
                        .frame(height: hourHeight * 24)
                        .background(alignment: .topLeading) {
                            VStack(spacing: 0) { ForEach(0..<24, id: \.self) { Color.clear.frame(height: hourHeight).id($0) } }
                        }
                }
                .onAppear {
                    let h = max(Calendar.current.component(.hour, from: Date()) - 2, 0)
                    DispatchQueue.main.async { proxy.scrollTo(min(h, 16), anchor: .top) }
                }
            }
        }
        .onReceive(timer) { now = $0 }
    }

    /// «Пн 9»: число сегодняшнего дня — в красном круге.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let today = Calendar.current.isDateInToday(d)
                Button { selectDay(d) } label: {
                    HStack(spacing: 5) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated)))
                            .foregroundStyle(today ? Color.red : CalStyle.muted)
                        Text("\(Calendar.current.component(.day, from: d))")
                            .fontWeight(today ? .semibold : .regular)
                            .foregroundStyle(today ? Color.white : CalStyle.ink)
                            .frame(minWidth: 24, minHeight: 24)
                            .background(Circle().fill(today ? Color.red : Color.clear))
                    }
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 34)
        .padding(.bottom, 2)
    }

    /// Полоса «весь день» и задачи со сроком.
    @ViewBuilder private var allDayStrip: some View {
        let cal = Calendar.current
        let lists = days.map { d in entries.filter { ($0.isAllDay || $0.kind == .reminder) && cal.isDate($0.start, inSameDayAs: d) } }
        if lists.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text(L("весь день")).font(.system(size: 10)).foregroundStyle(CalStyle.muted)
                    .frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8).padding(.top, 3)
                ForEach(days.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lists[i]) { e in
                            Button { e.kind == .reminder ? toggle(e) : open(e) } label: { MonthEventLine(entry: e) }
                                .buttonStyle(.plain)
                                .help(e.kind == .reminder ? L("Отметить выполненной") : e.title)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.vertical, 3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func grid(width: CGFloat) -> some View {
        let colW = (width - gutter) / CGFloat(max(days.count, 1))
        let cal = Calendar.current
        let todayIndex = days.firstIndex { cal.isDate($0, inSameDayAs: now) }
        let nowY = CGFloat(CalendarMath.minutes(of: now, in: now) / 60) * hourHeight
        return ZStack(alignment: .topLeading) {
            // Выходные — серым фоном, как в Календаре.
            ForEach(days.indices, id: \.self) { i in
                if cal.isDateInWeekend(days[i]) && days.count > 1 {
                    Rectangle().fill(CalStyle.soft.opacity(0.35))
                        .frame(width: colW, height: hourHeight * 24)
                        .offset(x: gutter + CGFloat(i) * colW)
                }
            }
            ForEach(0..<24, id: \.self) { h in
                Rectangle().fill(CalStyle.line).frame(width: max(width - gutter + 6, 0), height: 0.5)
                    .offset(x: gutter - 6, y: CGFloat(h) * hourHeight)
                if h > 0 {
                    // Подпись часа рядом с текущим временем прячется, как в Календаре.
                    let hidden = todayIndex != nil && abs(nowY - CGFloat(h) * hourHeight) < 12
                    Text(String(format: "%02d:00", h)).font(.system(size: 10)).foregroundStyle(CalStyle.muted)
                        .frame(width: gutter - 10, alignment: .trailing)
                        .offset(y: CGFloat(h) * hourHeight - 6)
                        .opacity(hidden ? 0 : 1)
                }
            }
            ForEach(days.indices, id: \.self) { i in
                Rectangle().fill(CalStyle.line).frame(width: 0.5, height: hourHeight * 24)
                    .offset(x: gutter + CGFloat(i) * colW)
                // Пустое место: двойной щелчок создаёт событие.
                Color.clear.contentShape(Rectangle())
                    .frame(width: colW, height: hourHeight * 24)
                    .offset(x: gutter + CGFloat(i) * colW)
                    .onTapGesture(count: 2, coordinateSpace: .local) { p in
                        create(days[i], CalendarMath.snap(minutes: Double(p.y / hourHeight * 60) - 30))
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .active(let p) = phase {
                            pointer.minutes = min(CalendarMath.snap(minutes: Double(p.y / hourHeight * 60) - 15), 24 * 60 - 15)
                        }
                    }
                    .contextMenu {
                        Button { remind(days[i], pointer.minutes) } label: { Label(L("Новое напоминание…"), systemImage: "checklist") }
                        Button { create(days[i], pointer.minutes) } label: { Label(L("Новое событие…"), systemImage: "calendar.badge.plus") }
                    }
            }
            ForEach(days.indices, id: \.self) { i in
                let day = days[i]
                let timed = entries.filter { $0.kind == .event && !$0.isAllDay && $0.start < cal.date(byAdding: .day, value: 1, to: day)! && $0.end > day }
                let slots = DayLayout.layout(timed.map { (start: max($0.start, day), end: $0.end) })
                ForEach(slots, id: \.index) { slot in
                    block(timed[slot.index], day: day, dayIndex: i, slot: slot, colW: colW)
                }
            }
            if let i = todayIndex {
                // Текущее время: красная подпись в колонке часов и линия через сегодняшний день.
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.red)
                    .frame(width: gutter - 10, alignment: .trailing)
                    .offset(y: nowY - 6)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.red.opacity(0.35)).frame(width: max(width - gutter, 0), height: 1)
                    .offset(x: gutter, y: nowY)
                    .allowsHitTesting(false)
                HStack(spacing: 0) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Rectangle().fill(Color.red).frame(width: max(colW - 4, 0), height: 1.5)
                }
                .offset(x: gutter + CGFloat(i) * colW - 4, y: nowY - 4)
                .allowsHitTesting(false)
            }
        }
    }

    private func block(_ e: AgendaEntry, day: Date, dayIndex: Int, slot: DayLayout.Slot, colW: CGFloat) -> some View {
        let top = CGFloat(CalendarMath.minutes(of: e.start, in: day) / 60) * hourHeight
        let bottom = CGFloat(CalendarMath.minutes(of: e.end, in: day) / 60) * hourHeight
        let w = (colW - 6) / CGFloat(max(slot.columns, 1))
        let d = drag?.id == e.id ? drag : nil
        let height = max(bottom - top + (d?.resize == true ? d!.dy : 0), 20)
        let x = gutter + CGFloat(dayIndex) * colW + 2 + CGFloat(slot.column) * w + (d?.resize == false ? d!.dx : 0)
        let y = top + (d?.resize == false ? d!.dy : 0)
        let color = Color(rgb: e.color)

        return VStack(alignment: .leading, spacing: 1) {
            Text(e.title.isEmpty ? L("Без названия") : e.title)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(color.mix(with: CalStyle.ink, by: 0.45)).lineLimit(2)
            if height > 36 {
                Text(e.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(color.mix(with: CalStyle.ink, by: 0.35))
            }
            Spacer(minLength: 0)
            if e.isEditable {
                // Нижний край: потянуть, чтобы изменить длительность.
                Rectangle().fill(Color.clear).frame(height: 6).frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in drag = DragState(id: e.id, resize: true, dx: 0, dy: g.translation.height) }
                        .onEnded { g in
                            drag = nil
                            let endMin = CalendarMath.snap(minutes: Double((bottom + g.translation.height) / hourHeight * 60))
                            move(e, e.start, CalendarMath.resized(start: e.start, toEndMinutes: endMin, day: day))
                        })
            }
        }
        .padding(.leading, 7).padding(.trailing, 4).padding(.top, 3)
        .frame(width: max(w - 2, 10), height: height, alignment: .topLeading)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(color.opacity(d != nil ? 0.4 : 0.22))
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 2).padding(.leading, 1)
            }
        )
        .shadow(color: d != nil ? .black.opacity(0.15) : .clear, radius: 4, y: 2)
        .offset(x: x, y: y)
        .zIndex(d != nil ? 1 : 0)
        .onTapGesture { open(e) }
        .gesture(e.isEditable ? DragGesture(minimumDistance: 4)
            .onChanged { g in drag = DragState(id: e.id, resize: false, dx: g.translation.width, dy: g.translation.height) }
            .onEnded { g in
                drag = nil
                let shiftDays = Int((g.translation.width / colW).rounded())
                let target = min(max(dayIndex + shiftDays, 0), days.count - 1)
                let startMin = CalendarMath.snap(minutes: Double((top + g.translation.height) / hourHeight * 60))
                let (s, en) = CalendarMath.moved(start: e.start, end: e.end, toDay: days[target], minutes: min(startMin, 24 * 60 - 15))
                move(e, s, en)
            } : nil)
        .help(e.isEditable ? L("Перетащите, чтобы перенести; потяните за нижний край, чтобы изменить длительность") : L("Только для чтения"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%@, с %@ до %@", e.title, e.start.formatted(date: .omitted, time: .shortened),
                              e.end.formatted(date: .omitted, time: .shortened)))
        .accessibilityAction { open(e) }
    }
}

// MARK: Правая панель вида «День»

struct DaySummaryView: View {
    let date: Date
    let entries: [AgendaEntry]
    let open: (AgendaEntry) -> Void
    let toggle: (AgendaEntry) -> Void

    var body: some View {
        let day = entries.filter { Calendar.current.isDate($0.start, inSameDayAs: date) || ($0.start < date && $0.end > date) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date.formatted(.dateTime.weekday(.wide))).font(.system(size: 13)).foregroundStyle(CalStyle.muted)
                    Text("\(Calendar.current.component(.day, from: date))").font(CalStyle.titleFont(44))
                        .foregroundStyle(Calendar.current.isDateInToday(date) ? Color.red : CalStyle.ink)
                }
                if day.isEmpty {
                    Text(L("Нет событий")).foregroundStyle(CalStyle.muted).font(.system(size: 13))
                }
                ForEach(day) { e in
                    Button { e.kind == .reminder ? toggle(e) : open(e) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            if e.kind == .reminder {
                                Image(systemName: e.isCompleted ? "checkmark.circle.fill" : "circle").foregroundStyle(Color(rgb: e.color))
                            } else {
                                RoundedRectangle(cornerRadius: 1.5).fill(Color(rgb: e.color)).frame(width: 3, height: 32)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title.isEmpty ? L("Без названия") : e.title).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(CalStyle.ink).strikethrough(e.isCompleted)
                                Text(e.isAllDay ? L("весь день")
                                     : e.kind == .reminder ? e.start.formatted(date: .omitted, time: .shortened)
                                     : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(CalStyle.muted)
                                Text(e.calendarTitle).font(.system(size: 11)).foregroundStyle(CalStyle.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CalStyle.paper)
    }
}

/// Месяц в именительном падеже («ноябрь», а не «ноября»).
func standaloneMonth(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = .current
    f.setLocalizedDateFormatFromTemplate("LLLL")
    return f.string(from: date)
}
