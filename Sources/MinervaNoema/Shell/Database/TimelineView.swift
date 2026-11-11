import SwiftUI
import UniformTypeIdentifiers

extension TimelineScale {
    var title: String {
        switch self {
        case .day: return L("Дни")
        case .week: return L("Недели")
        case .month: return L("Месяцы")
        }
    }
}

/// Timeline (M11): полосы по свойству даты на шкале дней, недель или месяцев.
struct TimelineKindView: View {
    @ObservedObject var model: DatabaseModel

    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 40

    private var dateProperty: PropertyDefinition? { model.database.flatMap { model.state.calendarProperty($0.properties) } }
    private var window: TimelineWindow { model.timelineWindow }
    private var today: LocalDate { LocalDate(date: Date(), in: .current) }

    var body: some View {
        if let property = dateProperty {
            VStack(alignment: .leading, spacing: 0) {
                toolbar.padding(.horizontal, Tokens.contentPadding).padding(.vertical, 10)
                if model.calendarTotal > DatabaseModel.calendarLimit {
                    Text(L("Показаны не все записи: %d из %d. Сузьте фильтр.", DatabaseModel.calendarLimit, model.calendarTotal))
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.danger)
                        .padding(.horizontal, Tokens.contentPadding)
                        .padding(.bottom, 6)
                }
                Rectangle().fill(Tokens.line).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    canvas(property)
                    Rectangle().fill(Tokens.line).frame(width: 1)
                    undatedPanel
                }
            }
        } else {
            EmptyKindNote(text: L("Для хронологии нужно свойство с датой. Добавьте его в «Свойствах»."))
        }
    }

    private var rangeTitle: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return "\(f.string(from: window.start.date(in: .current))) – \(f.string(from: window.end.date(in: .current)))"
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(rangeTitle).font(.system(size: 14, weight: .semibold))
            Spacer()
            Picker("Масштаб", selection: Binding(get: { model.state.timelineScale }, set: { model.setTimelineScale($0) })) {
                ForEach(TimelineScale.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { model.showTimeline(around: window.scale.step(model.timelineAnchor, forward: false)) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .accessibilityLabel(Text("Раньше"))
            Button("Сегодня") { model.showTimeline(around: today) }.buttonStyle(NotesButtonStyle(kind: .plain))
            Button { model.showTimeline(around: window.scale.step(model.timelineAnchor, forward: true)) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .accessibilityLabel(Text("Позже"))
        }
    }

    // MARK: Шкала

    private func canvas(_ property: PropertyDefinition) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineHeader(window: window)
                        .frame(width: window.width, height: Self.headerHeight, alignment: .topLeading)
                        .id("start")
                    Rectangle().fill(Tokens.line).frame(width: window.width, height: 1)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.sections) { section in
                                if let group = section.group {
                                    GroupHeader(group: group, count: section.total, property: model.database?.property(group.property))
                                        .padding(.leading, 12)
                                        .frame(width: window.width, height: Self.rowHeight + 6, alignment: .leading)
                                }
                                ForEach(section.rows) { row in
                                    if case .date(let value)? = row.values[property.id] {
                                        TimelineBarRow(model: model, row: row, value: value, window: window)
                                    }
                                }
                            }
                            if model.sections.allSatisfy({ $0.rows.isEmpty }) {
                                Text("В этом промежутке записей нет")
                                    .font(.system(size: 13))
                                    .foregroundColor(Tokens.muted)
                                    .padding(16)
                            }
                        }
                        .frame(width: window.width, alignment: .topLeading)
                        .padding(.bottom, 40)
                    }
                    .background(TimelineGrid(window: window, today: today))
                    .onDrop(of: [UTType.plainText], delegate: TimelineDrop(window: window) { id, day in model.setDay(record: id, day) })
                }
            }
            .onChange(of: window) { _, _ in DispatchQueue.main.async { proxy.scrollTo("start", anchor: .leading) } }
        }
    }

    /// Записи без даты отдельным списком; карточку можно бросить на шкалу — запись получит этот день.
    private var undatedPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Без даты: %d", model.undated.total)).font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
                ForEach(model.undated.rows) { RecordCard(model: model, row: $0, compact: true) }
                if model.undated.rows.count < model.undated.total {
                    Button(L("Показать ещё (осталось %d)", model.undated.total - model.undated.rows.count)) { model.showMore("undated") }
                        .buttonStyle(NotesButtonStyle(kind: .plain))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 210)
    }
}

/// Подписи шкалы: месяцы и годы сверху, деления снизу.
private struct TimelineHeader: View {
    let window: TimelineWindow

    private func label(_ day: LocalDate, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: day.date(in: .current))
    }

    private var upper: [(day: LocalDate, text: String)] {
        window.days.enumerated().compactMap { i, day in
            switch window.scale {
            case .day, .week: return (i == 0 || day.day == 1) ? (day, label(day, "LLLLyyyy")) : nil
            case .month: return (i == 0 || (day.day == 1 && day.month == 1)) ? (day, "\(day.year)") : nil
            }
        }
    }

    private func lower(_ day: LocalDate) -> String {
        window.scale == .month ? label(day, "LLL") : "\(day.day)"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(upper, id: \.day) { item in
                Text(item.text).font(.system(size: 11, weight: .semibold)).foregroundColor(Tokens.ink)
                    .fixedSize().padding(.leading, 4).offset(x: window.x(of: item.day), y: 4)
            }
            ForEach(window.ticks, id: \.day) { tick in
                Text(lower(tick.day)).font(.system(size: 10)).foregroundColor(Tokens.muted)
                    .fixedSize().frame(width: window.scale == .day ? window.scale.dayWidth : nil)
                    .padding(.leading, window.scale == .day ? 0 : 3)
                    .offset(x: window.x(of: tick.day), y: 22)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Шкала времени"))
    }
}

/// Деления, выходные и линия «сегодня» за полосами.
private struct TimelineGrid: View {
    let window: TimelineWindow
    let today: LocalDate

    var body: some View {
        Canvas { context, size in
            let w = window.scale.dayWidth
            for (i, day) in window.days.enumerated() {
                let x = Double(i) * w
                if window.scale != .month, day.weekdayFromMonday >= 5 {
                    context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Tokens.soft.opacity(0.6)))
                }
            }
            for tick in window.ticks {
                let x = window.x(of: tick.day)
                context.fill(Path(CGRect(x: x, y: 0, width: tick.major ? 1 : 0.5, height: size.height)), with: .color(Tokens.line))
            }
            if today >= window.start, today <= window.end {
                let x = window.x(of: today) + w / 2
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Tokens.danger.opacity(0.8)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Строка одной записи: полоса переносится целиком, края растягивают начало и конец.
private struct TimelineBarRow: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel
    let row: RecordRow
    let value: DateValue
    let window: TimelineWindow

    private enum Mode { case move, start, end }
    @State private var mode: Mode?
    @State private var drag: Double = 0

    private var title: String { row.title.isEmpty ? L("Без названия") : row.title }
    private var step: Double { window.scale.dayWidth }
    /// Сдвиг в целых днях: полоса прилипает к делениям.
    private var days: Int { Int((drag / step).rounded()) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: window.width, height: TimelineKindView.rowHeight)
            if let bar = window.bar(value) {
                let shift = Double(days) * step
                let x = bar.x + (mode == .move || mode == .start ? shift : 0)
                let width = max(step, bar.width + (mode == .start ? -shift : mode == .end ? shift : 0))
                barBody(width: width, bar: bar)
                    .offset(x: x, y: 4)
            }
        }
        .frame(width: window.width, height: TimelineKindView.rowHeight, alignment: .topLeading)
    }

    private func barBody(width: Double, bar: (x: Double, width: Double, clippedStart: Bool, clippedEnd: Bool)) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return ZStack(alignment: .leading) {
            shape.fill(Tokens.accent.opacity(mode == nil ? 0.18 : 0.3))
            shape.stroke(Tokens.accent.opacity(0.7), lineWidth: 1)
            HStack(spacing: 4) {
                if let icon = row.icon { Text(icon).font(.system(size: 11)) }
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(Tokens.ink).lineLimit(1)
            }
            .fixedSize()
            .padding(.leading, 6)
            // Узкая полоса: подпись идёт за её правым краем.
            .offset(x: width < 70 ? width : 0)
        }
        .frame(width: width, height: TimelineKindView.rowHeight - 8)
        .contentShape(shape)
        .onTapGesture { shell.openPage(row.id) }
        .gesture(dragGesture(.move))
        .overlay(alignment: .leading) { if !bar.clippedStart { handle(.start) } }
        .overlay(alignment: .trailing) { if !bar.clippedEnd { handle(.end) } }
        .help(PropertyConversion.text(of: .date(value), options: []))
        .contextMenu {
            Button("Открыть") { shell.openPage(row.id) }
            Button("На день раньше") { model.shiftDate(record: row.id, byDays: -1) }
            Button("На день позже") { model.shiftDate(record: row.id, byDays: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(PropertyConversion.text(of: .date(value), options: []))"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { shell.openPage(row.id) }
        .accessibilityAction(named: Text("На день раньше")) { model.shiftDate(record: row.id, byDays: -1) }
        .accessibilityAction(named: Text("На день позже")) { model.shiftDate(record: row.id, byDays: 1) }
    }

    private func handle(_ edge: Mode) -> some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .highPriorityGesture(dragGesture(edge))
    }

    private func dragGesture(_ kind: Mode) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { change in
                mode = kind
                drag = change.translation.width
            }
            .onEnded { _ in
                let moved = days
                mode = nil
                drag = 0
                guard moved != 0 else { return }
                switch kind {
                case .move: model.shiftDate(record: row.id, byDays: moved)
                case .start: model.resizeDate(record: row.id, start: true, byDays: moved)
                case .end: model.resizeDate(record: row.id, start: false, byDays: moved)
                }
            }
    }
}

/// Карточка из «Без даты», брошенная на шкалу, получает день под курсором.
private struct TimelineDrop: DropDelegate {
    let window: TimelineWindow
    let accept: (UUID, LocalDate) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.plainText]) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        let day = window.day(atX: info.location.x)
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return }
            DispatchQueue.main.async { accept(id, day) }
        }
        return true
    }
}
