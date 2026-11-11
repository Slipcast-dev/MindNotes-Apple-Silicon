import SwiftUI
import UniformTypeIdentifiers

extension TimelineScale {
    var title: String {
        switch self {
        case .hour: return L("Часы")
        case .day: return L("Дни")
        case .week: return L("Недели")
        case .month: return L("Месяцы")
        }
    }
}

/// Тянущаяся стрелка зависимости: от правого края полосы к курсору.
struct TimelineLinkDrag: Equatable {
    var from: UUID
    var start: CGPoint
    var end: CGPoint
}

/// Хронология (M11): полосы по свойству даты на шкале, которая растёт при прокрутке в обе стороны.
struct TimelineKindView: View {
    @ObservedObject var model: DatabaseModel

    static let headerHeight: CGFloat = 40

    @State private var position = ScrollPosition(edge: .leading)
    @State private var offsetX: Double = 0
    @State private var viewport: Double = 0
    /// Видимая часть по высоте: холсты стрелок и сетки рисуют только её, а не всю шкалу.
    @State private var offsetY: Double = 0
    @State private var viewportHeight: Double = 0
    @State private var lastGrow = Date.distantPast
    @State private var link: TimelineLinkDrag?

    private var dateProperty: PropertyDefinition? { model.database.flatMap { model.state.calendarProperty($0.properties) } }
    private var window: TimelineWindow { model.timelineWindow }
    private var today: LocalDate { LocalDate(date: Date(), in: .current) }
    /// День у левого края с отступом: по нему запоминается и восстанавливается положение.
    private var lead: Double { viewport * 0.15 }
    private var visibleDay: LocalDate { window.day(atX: offsetX + lead) }

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
        f.setLocalizedDateFormatFromTemplate(window.scale == .hour ? "EdMMMyyyy" : "LLLLyyyy")
        return f.string(from: visibleDay.date(in: .current))
    }

    /// Шаг стрелок — видимая ширина шкалы.
    private var pageDays: Int { max(1, Int(viewport / window.scale.dayWidth)) }

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
            Button { model.showTimeline(around: visibleDay.adding(days: -pageDays)) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .accessibilityLabel(Text("Раньше"))
            Button("Сегодня") { model.showTimeline(around: today) }.buttonStyle(NotesButtonStyle(kind: .plain))
            Button { model.showTimeline(around: visibleDay.adding(days: pageDays)) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .accessibilityLabel(Text("Позже"))
        }
    }

    // MARK: Шкала

    /// Строки, которые рисуются: запись с датой; у групп — заголовок.
    private func layout(_ property: PropertyDefinition) -> TimelineLayout {
        TimelineLayout(sections: model.sections.map { section in
            (section.id, section.group != nil, section.rows.compactMap { row in
                if case .date? = row.values[property.id] { return row.id }
                return nil
            })
        })
    }

    private func canvas(_ property: PropertyDefinition) -> some View {
        let layout = layout(property)
        let values = Dictionary(model.rows.compactMap { row -> (UUID, DateValue)? in
            if case .date(let v)? = row.values[property.id] { return (row.id, v) }
            return nil
        }, uniquingKeysWith: { a, _ in a })
        let arrows = TimelineDependency.arrows(values: values, links: model.dependencyLinks)
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                TimelineHeader(window: window)
                    .frame(width: window.width, height: Self.headerHeight, alignment: .topLeading)
                Rectangle().fill(Tokens.line).frame(width: window.width, height: 1)
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        TimelineArrows(window: window, layout: layout, values: values, arrows: arrows, link: link,
                                       visible: CGRect(x: offsetX, y: offsetY, width: viewport, height: viewportHeight))
                            .frame(width: max(1, viewport), height: max(1, viewportHeight))
                            .offset(x: offsetX, y: offsetY)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.sections) { section in
                                if let group = section.group {
                                    GroupHeader(group: group, count: section.total, property: model.database?.property(group.property))
                                        .padding(.leading, offsetX + 12)
                                        .frame(width: window.width, height: TimelineLayout.headerHeight, alignment: .leading)
                                }
                                ForEach(section.rows) { row in
                                    if case .date(let value)? = row.values[property.id] {
                                        TimelineBarRow(model: model, row: row, value: value, window: window,
                                                       y: layout.midY(row.id) ?? 0, link: $link,
                                                       onReorder: { dy in reorder(row.id, from: section, dy: dy, layout: layout) },
                                                       onLink: { target in linkEnded(from: row.id, toY: target, layout: layout) })
                                    }
                                }
                            }
                        }
                        .frame(width: window.width, alignment: .topLeading)
                        if layout.items.isEmpty {
                            Text("В этом промежутке записей нет")
                                .font(.system(size: 13))
                                .foregroundColor(Tokens.muted)
                                .padding(16)
                                .offset(x: offsetX)
                        }
                    }
                    .frame(width: window.width, height: layout.height + 40, alignment: .topLeading)
                }
                .onScrollGeometryChange(for: [Double].self) { [$0.contentOffset.y, $0.containerSize.height] } action: { _, geo in
                    offsetY = geo[0]
                    viewportHeight = geo[1]
                }
                .background(alignment: .topLeading) {
                    TimelineGrid(window: window, fromX: offsetX, width: viewport)
                        .frame(width: max(1, viewport))
                        .offset(x: offsetX)
                }
                .onDrop(of: [UTType.plainText], delegate: TimelineDrop(window: window) { id, day in model.setDay(record: id, day) })
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: [Double].self) { geo in
            [geo.contentOffset.x, geo.containerSize.width, geo.contentSize.width]
        } action: { _, geo in
            offsetX = geo[0]
            viewport = geo[1]
            grow(offset: geo[0], viewport: geo[1], content: geo[2])
        }
        .onScrollPhaseChange { _, phase in
            if phase == .idle, viewport > 0 { model.rememberTimelineDay(visibleDay) }
        }
        .onAppear { scrollToTarget() }
        .onChange(of: model.timelineScrollTarget) { _, _ in scrollToTarget() }
    }

    /// У края шкала дорастает порцией; начало, добавленное слева, компенсируется прокруткой, чтобы ничего не прыгнуло.
    private func grow(offset: Double, viewport: Double, content: Double) {
        guard viewport > 0, content > viewport, model.timelineScrollTarget == nil, Date().timeIntervalSince(lastGrow) > 0.3 else { return }
        let nearStart = offset < viewport * 0.5, nearEnd = offset + viewport > content - viewport * 0.5
        guard nearStart || nearEnd else { return }
        lastGrow = Date()
        if !window.canGrow {
            model.showTimeline(around: window.day(atX: offset + lead), rebuild: true)
        } else if nearStart, let shift = model.extendTimeline(before: true) {
            position.scrollTo(x: offset + shift)
        } else if nearEnd {
            model.extendTimeline(before: false)
        }
    }

    private func scrollToTarget() {
        guard let day = model.timelineScrollTarget else { return }
        // Шкала могла только что смениться: прокрутка — после того, как её ширина разложится.
        DispatchQueue.main.async {
            // В масштабе «Часы» сегодняшний день открывается на текущем часе, а не на полуночи.
            let now = DatePoint.moment(ms: Int64(Date().timeIntervalSince1970 * 1000), zone: TimeZone.current.identifier)
            let x = window.scale == .hour && day == today ? window.x(of: now) : window.x(of: day)
            position.scrollTo(x: max(0, x - lead))
            lastGrow = Date()
            model.timelineScrollTarget = nil
        }
    }

    private func reorder(_ id: UUID, from section: RecordSection, dy: Double, layout: TimelineLayout) {
        guard let y = layout.midY(id), let drop = layout.drop(id, atY: y + dy) else { return }
        let target = model.sections.first { $0.id == drop.section }
        model.reorder(record: id, before: drop.before, from: section, to: target)
    }

    private func linkEnded(from source: UUID, toY y: Double, layout: TimelineLayout) {
        guard let target = layout.record(atY: y), target != source else { return }
        model.addDependency(record: target, on: source)
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

/// Подписи шкалы: месяцы, годы или дни сверху, деления снизу.
private struct TimelineHeader: View {
    let window: TimelineWindow

    private static let formatters = NSCache<NSString, DateFormatter>()

    private func label(_ day: LocalDate, _ template: String) -> String {
        let f: DateFormatter
        if let cached = Self.formatters.object(forKey: template as NSString) { f = cached } else {
            f = DateFormatter()
            f.locale = Locale.current
            f.timeZone = .current
            f.setLocalizedDateFormatFromTemplate(template)
            Self.formatters.setObject(f, forKey: template as NSString)
        }
        return f.string(from: day.date(in: .current))
    }

    private var upper: [(day: LocalDate, text: String)] {
        window.days.enumerated().compactMap { i, day in
            switch window.scale {
            case .hour: return (day, label(day, "EEEEdMMMM"))
            case .day, .week: return (i == 0 || day.day == 1) ? (day, label(day, "LLLLyyyy")) : nil
            case .month: return (i == 0 || (day.day == 1 && day.month == 1)) ? (day, "\(day.year)") : nil
            }
        }
    }

    private func lower(_ tick: (day: LocalDate, hour: Int, major: Bool)) -> String {
        switch window.scale {
        case .hour: return String(format: "%02d", tick.hour)
        case .month: return label(tick.day, "LLL")
        case .day, .week: return "\(tick.day.day)"
        }
    }

    var body: some View {
        let hourWidth = window.scale.dayWidth / 24
        ZStack(alignment: .topLeading) {
            ForEach(upper, id: \.day) { item in
                Text(item.text).font(.system(size: 11, weight: .semibold)).foregroundColor(Tokens.ink)
                    .fixedSize().padding(.leading, 4).offset(x: window.x(of: item.day), y: 4)
            }
            ForEach(Array(window.ticks.enumerated()), id: \.offset) { _, tick in
                Text(lower(tick)).font(.system(size: 10)).foregroundColor(Tokens.muted)
                    .fixedSize()
                    .frame(width: window.scale == .day ? window.scale.dayWidth : nil)
                    .padding(.leading, window.scale == .day ? 0 : 3)
                    .offset(x: window.x(of: tick.day) + Double(tick.hour) * hourWidth, y: 22)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Шкала времени"))
    }
}

/// Деления, выходные и линия «сейчас» за полосами.
private struct TimelineGrid: View {
    let window: TimelineWindow
    /// Левый край видимой части в координатах шкалы и её ширина.
    let fromX: Double
    let width: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Canvas { gc, size in
                gc.translateBy(x: -fromX, y: 0)
                let w = window.scale.dayWidth
                let toX = fromX + width
                if window.scale != .month {
                    for (i, day) in window.days.enumerated() where day.weekdayFromMonday >= 5 {
                        let x = Double(i) * w
                        guard x + w >= fromX, x <= toX else { continue }
                        gc.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Tokens.soft.opacity(0.6)))
                    }
                }
                for tick in window.ticks {
                    let x = window.x(of: tick.day) + Double(tick.hour) * w / 24
                    guard x >= fromX - 1, x <= toX else { continue }
                    gc.fill(Path(CGRect(x: x, y: 0, width: tick.major ? 1 : 0.5, height: size.height)), with: .color(Tokens.line))
                }
                let now = DatePoint.moment(ms: Int64(context.date.timeIntervalSince1970 * 1000), zone: TimeZone.current.identifier)
                let x = window.x(of: now)
                if x >= fromX - 2, x <= toX + 2 {
                    gc.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Tokens.danger.opacity(0.8)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Стрелки «зависит от»: от правого края полосы к левому краю зависимой. Красная — зависимая начинается раньше.
private struct TimelineArrows: View {
    let window: TimelineWindow
    let layout: TimelineLayout
    let values: [UUID: DateValue]
    let arrows: [TimelineDependency]
    let link: TimelineLinkDrag?
    /// Видимая часть шкалы: холст размером с неё, стрелки рисуются со сдвигом.
    let visible: CGRect

    var body: some View {
        Canvas { gc, _ in
            gc.translateBy(x: -visible.minX, y: -visible.minY)
            for arrow in arrows {
                guard let a = values[arrow.from].flatMap({ window.bar($0) }), let b = values[arrow.to].flatMap({ window.bar($0) }),
                      let y1 = layout.midY(arrow.from), let y2 = layout.midY(arrow.to) else { continue }
                draw(&gc, from: CGPoint(x: a.x + a.width, y: y1), to: CGPoint(x: b.x, y: y2),
                     color: arrow.conflict ? Tokens.danger : Tokens.muted)
            }
            if let link { draw(&gc, from: link.start, to: link.end, color: Tokens.accent) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ gc: inout GraphicsContext, from p: CGPoint, to q: CGPoint, color: Color) {
        var path = Path()
        path.move(to: p)
        let bend = max(24, abs(q.x - p.x) / 2)
        path.addCurve(to: CGPoint(x: q.x - 4, y: q.y), control1: CGPoint(x: p.x + bend, y: p.y), control2: CGPoint(x: q.x - bend, y: q.y))
        gc.stroke(path, with: .color(color), lineWidth: 1.3)
        var head = Path()
        head.move(to: q)
        head.addLine(to: CGPoint(x: q.x - 7, y: q.y - 4))
        head.addLine(to: CGPoint(x: q.x - 7, y: q.y + 4))
        head.closeSubpath()
        gc.fill(head, with: .color(color))
    }
}

/// Строка одной записи: полоса переносится по горизонтали (даты) или по вертикали (порядок),
/// края растягивают начало и конец, точка справа тянет стрелку зависимости.
private struct TimelineBarRow: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel
    let row: RecordRow
    let value: DateValue
    let window: TimelineWindow
    /// Середина строки на всей шкале: от неё считается стрелка.
    let y: Double
    @Binding var link: TimelineLinkDrag?
    let onReorder: (Double) -> Void
    let onLink: (Double) -> Void

    private enum Mode { case move, reorder, start, end }
    @State private var mode: Mode?
    @State private var drag: CGSize = .zero
    @State private var hovering = false

    private var title: String { row.title.isEmpty ? L("Без названия") : row.title }
    private var perMinute: Double { window.scale.dayWidth / 1440 }
    private var snap: Int { window.scale.snapMinutes(moment: value.start.isMoment) }
    /// Сдвиг в целых шагах: полоса прилипает к делениям.
    private var minutes: Int { Int((drag.width / perMinute / Double(snap)).rounded()) * snap }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: window.width, height: TimelineLayout.rowHeight)
            if let bar = window.bar(value) {
                let shift = Double(minutes) * perMinute
                let x = bar.x + (mode == .move || mode == .start ? shift : 0)
                let width = max(6, bar.width + (mode == .start ? -shift : mode == .end ? shift : 0))
                barBody(width: width, bar: bar)
                    .offset(x: x, y: 4 + (mode == .reorder ? drag.height : 0))
            }
        }
        .frame(width: window.width, height: TimelineLayout.rowHeight, alignment: .topLeading)
        .zIndex(mode == nil ? 0 : 1)
    }

    private func barBody(width: Double, bar: (x: Double, width: Double, clippedStart: Bool, clippedEnd: Bool)) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return ZStack {
            shape.fill(Tokens.accent.opacity(mode == nil ? 0.18 : 0.3))
            shape.stroke(Tokens.accent.opacity(0.7), lineWidth: 1)
        }
        .frame(width: width, height: TimelineLayout.rowHeight - 8)
        // Подпись — наложением: она не меняет размер полосы. Узкая полоса — подпись за её правым краем.
        .overlay(alignment: .leading) {
            HStack(spacing: 4) {
                if let icon = row.icon { Text(icon).font(.system(size: 11)) }
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(Tokens.ink).lineLimit(1)
                if value.start.isMoment, window.scale == .hour || window.scale == .day {
                    Text(timeText).font(.system(size: 10)).foregroundColor(Tokens.muted).lineLimit(1)
                }
            }
            .fixedSize()
            .padding(.leading, 6)
            .offset(x: width < 70 ? width + 10 : 0)
            .allowsHitTesting(false)
        }
        .contentShape(shape)
        .onTapGesture { shell.openPage(row.id) }
        .gesture(dragGesture(.move))
        .overlay(alignment: .leading) { if !bar.clippedStart { handle(.start) } }
        .overlay(alignment: .trailing) {
            if !bar.clippedEnd {
                HStack(spacing: 0) {
                    handle(.end)
                    if model.dependencyProperty != nil { connector(barRight: bar.x + width) }
                }
            }
        }
        .onHover { hovering = $0 }
        .help(PropertyConversion.text(of: .date(value), options: []))
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(PropertyConversion.text(of: .date(value), options: []))"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { shell.openPage(row.id) }
        .accessibilityAction(named: Text("На день раньше")) { model.shiftDate(record: row.id, byDays: -1) }
        .accessibilityAction(named: Text("На день позже")) { model.shiftDate(record: row.id, byDays: 1) }
    }

    private var timeText: String {
        let start = value.start.localText.dropFirst(11)
        guard let end = value.end?.localText.dropFirst(11), end != start else { return String(start) }
        return "\(start)–\(end)"
    }

    @ViewBuilder private var menu: some View {
        Button("Открыть") { shell.openPage(row.id) }
        Button("На день раньше") { model.shiftDate(record: row.id, byDays: -1) }
        Button("На день позже") { model.shiftDate(record: row.id, byDays: 1) }
        if value.start.isMoment {
            Button("На час раньше") { model.shiftDate(record: row.id, byMinutes: -60) }
            Button("На час позже") { model.shiftDate(record: row.id, byMinutes: 60) }
        }
        if model.dependencyProperty != nil {
            let sources = model.dependencyLinks[row.id] ?? []
            let others = model.rows.filter { $0.id != row.id && !sources.contains($0.id) }.prefix(100)
            Menu("Зависит от") {
                ForEach(Array(others)) { other in
                    Button(other.title.isEmpty ? L("Без названия") : other.title) { model.addDependency(record: row.id, on: other.id) }
                }
            }
            if !sources.isEmpty {
                Menu("Убрать зависимость") {
                    ForEach(sources, id: \.self) { id in
                        let name = model.rows.first { $0.id == id }?.title ?? ""
                        Button(name.isEmpty ? L("Без названия") : name) { model.removeDependency(record: row.id, on: id) }
                    }
                }
            }
        }
    }

    private func handle(_ edge: Mode) -> some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .highPriorityGesture(dragGesture(edge))
    }

    /// Точка у правого края: тянется к другой полосе, та начинает зависеть от этой записи.
    private func connector(barRight: Double) -> some View {
        Circle()
            .fill(Tokens.accent)
            .frame(width: 9, height: 9)
            .opacity(hovering || link?.from == row.id ? 1 : 0)
            .padding(.leading, 3)
            .offset(x: 12)
            .contentShape(Rectangle().inset(by: -4))
            .help(L("Потяните к другой записи: она будет зависеть от этой"))
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { change in
                        let start = CGPoint(x: barRight + 6, y: y)
                        link = TimelineLinkDrag(from: row.id, start: start,
                                                end: CGPoint(x: start.x + change.translation.width, y: y + change.translation.height))
                    }
                    .onEnded { change in
                        link = nil
                        onLink(y + change.translation.height)
                    }
            )
    }

    private func dragGesture(_ kind: Mode) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { change in
                // Направление выбирается в начале жеста: по вертикали — порядок строк, если он доступен.
                if mode == nil {
                    let vertical = abs(change.translation.height) > abs(change.translation.width)
                    mode = kind == .move && vertical && model.canReorder ? .reorder : kind
                }
                drag = change.translation
            }
            .onEnded { _ in
                let moved = minutes, dy = drag.height, done = mode
                mode = nil
                drag = .zero
                switch done {
                case .reorder?: if abs(dy) > TimelineLayout.rowHeight / 2 { onReorder(dy) }
                case .move?: if moved != 0 { model.shiftDate(record: row.id, byMinutes: moved) }
                case .start?: if moved != 0 { model.resizeDate(record: row.id, start: true, byMinutes: moved) }
                case .end?: if moved != 0 { model.resizeDate(record: row.id, start: false, byMinutes: moved) }
                case nil: break
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
