import AppKit
import Combine
import SwiftUI

/// Календарь внутри приложения: день, неделя, месяц. Читает и пишет EventKit напрямую,
/// элементы приложения подтягиваются сверкой движка.
struct CalendarView: View {
    let engine: CalendarSyncEngine
    @AppStorage("calendarSync.viewMode") private var modeRaw = CalendarMath.Mode.week.rawValue
    @State private var date = Date()
    @State private var entries: [AgendaEntry] = []
    @State private var draft: EventEditorSheet.Draft?
    @State private var showPicker = false
    @State private var pendingMove: PendingMove?
    @State private var error: String?
    @State private var reloadTick = 0

    struct PendingMove: Identifiable {
        let id = UUID()
        var entry: AgendaEntry
        var start: Date
        var end: Date
    }

    private var mode: CalendarMath.Mode { CalendarMath.Mode(rawValue: modeRaw) ?? .week }
    private var hasAccess: Bool { engine.status(.event) == .granted }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !hasAccess {
                AccessDeniedBanner(kind: .event).padding(20)
                Spacer()
            } else {
                switch mode {
                case .month:
                    MonthGridView(date: date, entries: entries,
                                  openDay: { date = $0; modeRaw = CalendarMath.Mode.day.rawValue },
                                  open: open, create: { create(day: $0, minutes: 9 * 60, allDay: false) })
                case .week:
                    TimeGridView(days: CalendarMath.weekDays(date), entries: entries,
                                 open: open, create: { create(day: $0, minutes: $1, allDay: false) },
                                 move: requestMove, toggle: toggle)
                case .day:
                    TimeGridView(days: [Calendar.current.startOfDay(for: date)], entries: entries,
                                 open: open, create: { create(day: $0, minutes: $1, allDay: false) },
                                 move: requestMove, toggle: toggle)
                }
            }
        }
        .task(id: "\(modeRaw)|\(date.timeIntervalSince1970)|\(engine.settings.lastSyncAt?.timeIntervalSince1970 ?? 0)|\(reloadTick)") {
            await load()
        }
        .sheet(item: $draft) { d in
            EventEditorSheet(draft: d, calendars: engine.gateway.containers(.event).filter(\.isEditable)) { result in
                apply(result)
            }
        }
        .sheet(isPresented: $showPicker) { CalendarPickerView(engine: engine) }
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

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { date = CalendarMath.step(mode, from: date, by: -1) } label: { Image(systemName: "chevron.left") }
                .help(L("Назад"))
            Button(L("Сегодня")) { date = Date() }
            Button { date = CalendarMath.step(mode, from: date, by: 1) } label: { Image(systemName: "chevron.right") }
                .help(L("Вперёд"))
            Text(title).font(.title3.weight(.semibold)).padding(.leading, 6)
            Spacer()
            Picker("", selection: $modeRaw) {
                Text(L("День")).tag(CalendarMath.Mode.day.rawValue)
                Text(L("Неделя")).tag(CalendarMath.Mode.week.rawValue)
                Text(L("Месяц")).tag(CalendarMath.Mode.month.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            Button { showPicker = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .help(L("Показывать календари"))
                .disabled(!hasAccess)
            Button { create(day: date, minutes: nextSlot(), allDay: false) } label: { Image(systemName: "plus") }
                .help(L("Новое событие"))
                .disabled(!hasAccess)
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    private var title: String {
        switch mode {
        case .day: return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            let d = CalendarMath.weekDays(date)
            return "\(d[0].formatted(.dateTime.day().month(.abbreviated))) – \(d[6].formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: return date.formatted(.dateTime.month(.wide).year())
        }
    }

    private func nextSlot() -> Int {
        let now = Date()
        guard Calendar.current.isDate(now, inSameDayAs: date) else { return 9 * 60 }
        return min(CalendarMath.snap(minutes: CalendarMath.minutes(of: now, in: now) + 30, step: 30), 23 * 60)
    }

    private func load() async {
        guard hasAccess || engine.status(.reminder) == .granted else { entries = []; return }
        let lists = [engine.settings.reminderListID].compactMap { $0 }
        entries = await engine.gateway.agenda(CalendarMath.interval(mode, around: date),
                                              calendarIDs: engine.settings.visibleCalendarIDs, reminderListIDs: lists)
    }

    // MARK: Действия

    private func create(day: Date, minutes: Int, allDay: Bool) {
        let start = CalendarMath.moment(day, minutes: minutes)
        let cal = engine.settings.eventCalendarID
            ?? engine.gateway.containers(.event).first(where: \.isEditable)?.id ?? ""
        draft = .init(externalID: nil, occurrenceStart: nil, isRecurring: false, calendarID: cal, title: "", notes: "",
                      start: start, end: start.addingTimeInterval(3600), isAllDay: allDay, recurrence: nil)
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
        let d = EventDraft(externalID: e.externalID, occurrenceStart: e.start, calendarID: e.calendarID, title: e.title,
                           notes: e.notes, start: m.start, end: m.end, isAllDay: e.isAllDay,
                           recurrence: nil, alarmMinutes: nil)
        do {
            // Серии передаётся её текущее правило: шлюз сравнит его с сохранённым и не тронет повтор.
            var keep = d
            if e.isRecurring { keep.recurrence = engine.gateway.lookup([e.externalID], kind: .event).first?.fields.recurrence }
            try engine.gateway.saveEvent(keep, span: span)
        } catch { self.error = "\(error)" }
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

// MARK: Месяц

struct MonthGridView: View {
    let date: Date
    let entries: [AgendaEntry]
    let openDay: (Date) -> Void
    let open: (AgendaEntry) -> Void
    let create: (Date) -> Void
    private let limit = 3

    var body: some View {
        let days = CalendarMath.monthGrid(date)
        let cal = Calendar.current
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
            }
            GeometryReader { geo in
                let h = geo.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(days[(row * 7)..<(row * 7 + 7)], id: \.self) { d in
                                cell(d, inMonth: cal.isDate(d, equalTo: date, toGranularity: .month)).frame(height: h)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, inMonth: Bool) -> some View {
        let cal = Calendar.current
        let items = entries.filter { e in
            e.isAllDay || e.kind == .reminder ? cal.isDate(e.start, inSameDayAs: day)
                : e.start < cal.date(byAdding: .day, value: 1, to: day)! && e.end > day
        }
        let today = cal.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(cal.component(.day, from: day))")
                    .font(.caption.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.white : (inMonth ? Color.primary : Color.secondary))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(today ? Color.red : Color.clear))
                Spacer()
            }
            ForEach(items.prefix(limit)) { e in
                Button { open(e) } label: {
                    HStack(spacing: 4) {
                        if e.kind == .reminder {
                            Image(systemName: e.isCompleted ? "checkmark.circle.fill" : "circle").font(.caption2)
                        } else {
                            Circle().fill(Color(rgb: e.color)).frame(width: 6, height: 6)
                        }
                        Text(e.isAllDay || e.kind == .reminder ? e.title : "\(e.start.formatted(date: .omitted, time: .shortened)) \(e.title)")
                            .font(.caption2).lineLimit(1).strikethrough(e.isCompleted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if items.count > limit {
                Button(L("ещё %d", items.count - limit)) { openDay(day) }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Color.clear : Color.secondary.opacity(0.06))
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { create(day) }
        .onTapGesture { openDay(day) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
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

    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 52
    @State private var drag: DragState?
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in grid(width: geo.size.width) }
                        .frame(height: hourHeight * 24)
                        .overlay(alignment: .topLeading) {
                            VStack(spacing: 0) { ForEach(0..<24, id: \.self) { Color.clear.frame(height: hourHeight).id($0) } }
                        }
                }
                .onAppear { proxy.scrollTo(max(Calendar.current.component(.hour, from: Date()) - 2, 0), anchor: .top) }
            }
        }
        .onReceive(timer) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days, id: \.self) { d in
                let today = Calendar.current.isDateInToday(d)
                HStack(spacing: 4) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).foregroundStyle(.secondary)
                    Text("\(Calendar.current.component(.day, from: d))")
                        .fontWeight(today ? .bold : .regular)
                        .foregroundStyle(today ? Color.white : Color.primary)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(today ? Color.red : Color.clear))
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    /// Полоса «весь день» и задачи со сроком.
    private var allDayStrip: some View {
        let cal = Calendar.current
        let lists = days.map { d in entries.filter { ($0.isAllDay || $0.kind == .reminder) && cal.isDate($0.start, inSameDayAs: d) } }
        return Group {
            if lists.contains(where: { !$0.isEmpty }) {
                HStack(alignment: .top, spacing: 0) {
                    Text(L("весь день")).font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
                    ForEach(days.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(lists[i]) { e in
                                Button { e.kind == .reminder ? toggle(e) : open(e) } label: {
                                    HStack(spacing: 4) {
                                        if e.kind == .reminder {
                                            Image(systemName: e.isCompleted ? "checkmark.circle.fill" : "circle")
                                        }
                                        Text(e.kind == .reminder && !e.isAllDay
                                             ? "\(e.start.formatted(date: .omitted, time: .shortened)) \(e.title)" : e.title)
                                            .lineLimit(1).strikethrough(e.isCompleted)
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(rgb: e.color).opacity(0.18)))
                                }
                                .buttonStyle(.plain)
                                .help(e.kind == .reminder ? L("Отметить выполненной") : e.title)
                            }
                        }
                        .padding(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func grid(width: CGFloat) -> some View {
        let colW = (width - gutter) / CGFloat(max(days.count, 1))
        let cal = Calendar.current
        return ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { h in
                HStack(alignment: .top, spacing: 4) {
                    Text(String(format: "%02d:00", h)).font(.caption2).foregroundStyle(.secondary)
                        .frame(width: gutter - 8, alignment: .trailing).offset(y: -6)
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5)
                }
                .offset(y: CGFloat(h) * hourHeight)
            }
            ForEach(days.indices, id: \.self) { i in
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 0.5, height: hourHeight * 24)
                    .offset(x: gutter + CGFloat(i) * colW)
                // Пустое место: щелчок создаёт событие на ближайшие 15 минут.
                Color.clear.contentShape(Rectangle())
                    .frame(width: colW, height: hourHeight * 24)
                    .offset(x: gutter + CGFloat(i) * colW)
                    .onTapGesture(count: 2, coordinateSpace: .local) { p in
                        create(days[i], CalendarMath.snap(minutes: Double(p.y / hourHeight * 60) - 30))
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
            if let i = days.firstIndex(where: { cal.isDate($0, inSameDayAs: now) }) {
                let y = CGFloat(CalendarMath.minutes(of: now, in: now) / 60) * hourHeight
                HStack(spacing: 0) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Rectangle().fill(.red).frame(width: colW - 7, height: 1)
                }
                .offset(x: gutter + CGFloat(i) * colW - 3.5, y: y - 3.5)
                .allowsHitTesting(false)
            }
        }
    }

    private func block(_ e: AgendaEntry, day: Date, dayIndex: Int, slot: DayLayout.Slot, colW: CGFloat) -> some View {
        let top = CGFloat(CalendarMath.minutes(of: e.start, in: day) / 60) * hourHeight
        let bottom = CGFloat(CalendarMath.minutes(of: e.end, in: day) / 60) * hourHeight
        let w = (colW - 4) / CGFloat(max(slot.columns, 1))
        let d = drag?.id == e.id ? drag : nil
        let height = max(bottom - top + (d?.resize == true ? d!.dy : 0), 18)
        let x = gutter + CGFloat(dayIndex) * colW + 2 + CGFloat(slot.column) * w + (d?.resize == false ? d!.dx : 0)
        let y = top + (d?.resize == false ? d!.dy : 0)

        return VStack(alignment: .leading, spacing: 1) {
            Text(e.title.isEmpty ? L("Без названия") : e.title).font(.caption.weight(.medium)).lineLimit(2)
            if height > 34 {
                Text("\(e.start.formatted(date: .omitted, time: .shortened))–\(e.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
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
        .padding(.horizontal, 5).padding(.top, 3)
        .frame(width: w - 2, height: height, alignment: .topLeading)
        .background(
            HStack(spacing: 0) {
                Rectangle().fill(Color(rgb: e.color)).frame(width: 3)
                Rectangle().fill(Color(rgb: e.color).opacity(d != nil ? 0.35 : 0.2))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        )
        .offset(x: x, y: y)
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
