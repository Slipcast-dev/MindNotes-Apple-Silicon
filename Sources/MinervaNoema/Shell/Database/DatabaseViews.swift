import SwiftUI
import UniformTypeIdentifiers

enum ViewKindTitle {
    static func title(_ kind: String) -> String {
        switch kind {
        case DatabaseView.tableKind: return L("Таблица")
        case DatabaseView.boardKind: return L("Доска")
        case DatabaseView.listKind: return L("Список")
        case DatabaseView.calendarKind: return L("Календарь")
        case DatabaseView.galleryKind: return L("Галерея")
        case DatabaseView.timelineKind: return L("Хронология")
        default: return kind
        }
    }
}

/// Двумерная прокрутка, которая начинается сверху слева. Сама по себе она центрирует содержимое меньше себя,
/// а шире себя открывает не с начала, и левая колонка оказывается обрезана.
struct TopLeadingScroll<Content: View>: View {
    /// Смена значения возвращает к началу: появились данные, ширина стала другой.
    let resetKey: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { area in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    content()
                        .frame(minWidth: area.size.width, minHeight: area.size.height, alignment: .topLeading)
                        .background(alignment: .topLeading) { Color.clear.frame(width: 1, height: 1).id("start") }
                }
                .onAppear { proxy.scrollTo("start", anchor: .topLeading) }
                .onChange(of: resetKey) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("start", anchor: .topLeading) }
                }
            }
        }
    }
}

/// Заголовок группы: цвет варианта, имя и число записей.
struct GroupHeader: View {
    let group: RecordGroup
    let count: Int
    let property: PropertyDefinition?

    var body: some View {
        HStack(spacing: 8) {
            if let option = group.option {
                Chip(text: option.name, colors: Tokens.swatch(option.color) ?? (Tokens.soft, Tokens.ink))
            } else if let person = group.person {
                Chip(text: person.label, colors: Tokens.swatch(person.color) ?? (Tokens.soft, Tokens.ink))
            } else if let checked = group.checked {
                Chip(text: checked ? L("Отмечено") : L("Не отмечено"))
            } else {
                Chip(text: L("Без значения: %@", property?.name ?? ""))
            }
            Text("\(count)").font(.system(size: 12)).foregroundColor(Tokens.muted)
        }
    }
}

/// Карточка записи: заголовок и значения видимых столбцов. Нажатие открывает запись как страницу.
struct RecordCard: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel
    let row: RecordRow
    var dragTag = ""
    var cover = false
    var compact = false

    /// Обложка карточки: своя обложка записи, иначе первая картинка из «Файлов и медиа».
    private var preview: UUID? {
        if let cover = row.cover { return cover }
        for property in model.database?.properties ?? [] where property.type == .files {
            if case .files(let list)? = row.values[property.id], let image = list.first(where: \.isImage) { return image.id }
        }
        return nil
    }

    private var lines: [String] {
        model.visibleColumns.filter { $0.type != .title }.compactMap { PropertyDisplay.text(row.values[$0.id], property: $0) }
    }

    var body: some View {
        Button { shell.openPage(row.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if cover {
                    Group {
                        if let image = shell.image(for: preview) {
                            Color.clear.overlay(Image(nsImage: image).resizable().scaledToFill()).clipped()
                        } else {
                            Tokens.soft
                        }
                    }
                    .frame(height: 110)
                    .onAppear { if let asset = preview { shell.loadImage(asset: asset) } }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if let icon = row.icon { Text(icon).font(.system(size: 13)) }
                        Text(row.title.isEmpty ? L("Без названия") : row.title)
                            .font(.system(size: compact ? 12 : 14, weight: .semibold))
                            .lineLimit(compact ? 1 : 2)
                    }
                    if !compact {
                        ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1)
                        }
                    }
                }
                .padding(compact ? 6 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: compact ? 6 : 10).fill(Tokens.card))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10))
            .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 10).stroke(Tokens.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: "\(row.id.uuidString)|\(dragTag)" as NSString) }
    }
}

/// Принимает карточку этого экрана: чужой текст не считается записью.
private struct RecordDrop: ViewModifier {
    let accept: (UUID, String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Tokens.accent : .clear, lineWidth: 2))
            .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return }
                    DispatchQueue.main.async { accept(id, parts[1]) }
                }
                return true
            }
    }
}

extension View {
    func acceptsRecord(_ accept: @escaping (UUID, String) -> Void) -> some View { modifier(RecordDrop(accept: accept)) }
}

// MARK: Доска

struct BoardView: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        if model.sections.first?.group == nil {
            EmptyKindNote(text: L("Для доски нужно свойство статуса, выбора или флажок. Добавьте его в «Свойствах»."))
        } else {
            TopLeadingScroll(resetKey: model.sections.count) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.sections) { column($0) }
                }
                .padding(.horizontal, Tokens.contentPadding)
                .padding(.vertical, 14)
            }
        }
    }

    private func column(_ section: RecordSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let group = section.group {
                GroupHeader(group: group, count: section.total, property: model.database?.property(group.property))
            }
            ForEach(section.rows) { row in
                // Карточка, брошенная на другую, встаёт перед ней — в этой же или в соседней колонке.
                RecordCard(model: model, row: row, dragTag: section.id)
                    .acceptsRecord { id, from in
                        model.reorder(record: id, before: row.id, from: model.sections.first { $0.id == from }, to: section)
                    }
            }
            if section.rows.count < section.total {
                Button(L("Показать ещё (осталось %d)", section.total - section.rows.count)) { model.showMore(section.id) }
                    .buttonStyle(NotesButtonStyle(kind: .plain))
            }
        }
        .padding(11)
        .frame(width: 280, alignment: .topLeading)
        .frame(minHeight: 160, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.side))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tokens.line))
        .acceptsRecord { id, from in
            let source = model.sections.first { $0.id == from }
            if model.canReorder { model.reorder(record: id, before: nil, from: source, to: section) } else { model.move(record: id, from: source, to: section) }
        }
    }
}

struct EmptyKindNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Tokens.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.vertical, 18)
    }
}

// MARK: Список и галерея

/// Разделы вида: группа, её карточки и подгрузка. Список и галерея отличаются только раскладкой карточек.
private struct SectionsScroll<Cards: View>: View {
    @ObservedObject var model: DatabaseModel
    @ViewBuilder let cards: (RecordSection) -> Cards

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.sections) { section in
                    if let group = section.group {
                        GroupHeader(group: group, count: section.total, property: model.database?.property(group.property)).padding(.top, 8)
                    }
                    cards(section)
                    if section.rows.count < section.total {
                        Button(L("Показать ещё (осталось %d)", section.total - section.rows.count)) { model.showMore(section.id) }
                            .buttonStyle(NotesButtonStyle(kind: .plain))
                    }
                }
                if model.rows.isEmpty {
                    Text(model.state.filter.ruleCount > 0 ? "Под фильтр не подходит ни одна запись." : "Записей пока нет. Нажмите «Запись».")
                        .font(.system(size: 13))
                        .foregroundColor(Tokens.muted)
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ListKindView: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel

    var body: some View {
        SectionsScroll(model: model) { section in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.rows) { row in
                    Button { shell.openPage(row.id) } label: {
                        HStack(spacing: 12) {
                            if let icon = row.icon { Text(icon) }
                            Text(row.title.isEmpty ? L("Без названия") : row.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 12)
                            ForEach(model.visibleColumns.filter { $0.type != .title }) { property in
                                if let text = PropertyDisplay.text(row.values[property.id], property: property) {
                                    Text(text).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(Rectangle().fill(Tokens.line).frame(height: 1), alignment: .bottom)
                    .onDrag { NSItemProvider(object: "\(row.id.uuidString)|\(section.id)" as NSString) }
                    .acceptsRecord { id, _ in model.reorder(record: id, before: row.id) }
                }
            }
        }
    }
}

struct GalleryView: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        SectionsScroll(model: model) { section in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(section.rows) { row in
                    RecordCard(model: model, row: row, dragTag: section.id, cover: model.state.showCover)
                        .acceptsRecord { id, _ in model.reorder(record: id, before: row.id) }
                }
            }
        }
    }
}

// MARK: Календарь

struct CalendarKindView: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var model: DatabaseModel

    private var dateProperty: PropertyDefinition? { model.database.flatMap { model.state.calendarProperty($0.properties) } }

    /// Диапазон показывается в каждом своём дне.
    private func rows(on day: LocalDate) -> [RecordRow] {
        guard let property = dateProperty else { return [] }
        return model.calendarRows.filter { row in
            guard case .date(let value)? = row.values[property.id] else { return false }
            return value.start.localDay <= day && day <= (value.end ?? value.start).localDay
        }
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        return f.string(from: model.month.date(in: .current))
    }

    private var weekdays: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale.current
        let names = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).map { names[($0 + 1) % 7] }
    }

    var body: some View {
        if dateProperty == nil {
            EmptyKindNote(text: L("Для календаря нужно свойство с датой. Добавьте его в «Свойствах»."))
        } else {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        header
                        if model.calendarTotal > DatabaseModel.calendarLimit {
                            Text(L("Показаны не все записи: %d из %d. Сузьте фильтр.", DatabaseModel.calendarLimit, model.calendarTotal))
                                .font(.system(size: 12))
                                .foregroundColor(Tokens.danger)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 90), spacing: 0), count: 7), spacing: 0) {
                            ForEach(weekdays, id: \.self) { name in
                                Text(name).font(.system(size: 11, weight: .semibold)).foregroundColor(Tokens.muted).frame(maxWidth: .infinity).padding(.bottom, 4)
                            }
                            ForEach(model.calendarDays, id: \.self) { dayCell($0) }
                        }
                    }
                    .padding(.horizontal, Tokens.contentPadding)
                    .padding(.vertical, 14)
                }
                Rectangle().fill(Tokens.line).frame(width: 1)
                undatedPanel
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(monthTitle).font(.system(size: 16, weight: .semibold))
            Spacer()
            Button { model.showMonth(model.month.addingMonths(-1)) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .accessibilityLabel(Text("Предыдущий месяц"))
            Button("Сегодня") { model.showMonth(LocalDate(date: Date(), in: .current)) }.buttonStyle(NotesButtonStyle(kind: .plain))
            Button { model.showMonth(model.month.addingMonths(1)) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .accessibilityLabel(Text("Следующий месяц"))
        }
    }

    private func dayCell(_ day: LocalDate) -> some View {
        let inMonth = day.month == model.month.month
        let today = day == LocalDate(date: Date(), in: .current)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(day.day)")
                .font(.system(size: 11, weight: today ? .bold : .regular))
                .foregroundColor(today ? Tokens.accent : (inMonth ? Tokens.ink : Tokens.muted.opacity(0.5)))
            ForEach(rows(on: day)) { RecordCard(model: model, row: $0, dragTag: day.iso, compact: true) }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .overlay(Rectangle().stroke(Tokens.line, lineWidth: 0.5))
        .contentShape(Rectangle())
        .acceptsRecord { id, from in model.move(record: id, grabbedOn: LocalDate(iso: from), toDay: day) }
    }

    /// Записи без даты отдельным списком (FR-11); перетаскивание в день назначает дату.
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

// MARK: Настройки вида

struct ViewSettingsPopover: View {
    @ObservedObject var model: DatabaseModel

    private var properties: [PropertyDefinition] { model.database?.properties ?? [] }
    private var kind: String { model.activeView?.kind ?? DatabaseView.tableKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isEmbedded {
                Picker("Вид", selection: Binding(get: { kind }, set: { model.setEmbeddedKind($0) })) {
                    ForEach(DatabaseView.knownKinds, id: \.self) { Text(ViewKindTitle.title($0)).tag($0) }
                }
            }
            if DatabaseView.usesDate(kind) {
                Picker("Свойство даты", selection: Binding(get: { model.state.calendarProperty(properties)?.id }, set: { id in
                    model.updateState { $0.dateProperty = id }
                })) {
                    ForEach(properties.filter { $0.type == .date }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if kind != DatabaseView.calendarKind {
                Picker("Группировка", selection: Binding(get: { model.state.groupProperty(properties, kind: kind)?.id }, set: { id in
                    model.updateState { $0.groupBy = id }
                })) {
                    if kind != DatabaseView.boardKind { Text("Без группировки").tag(UUID?.none) }
                    ForEach(properties.filter { RecordGroup.isGroupable($0.type) }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if kind == DatabaseView.galleryKind {
                Toggle("Показывать обложку страницы", isOn: Binding(get: { model.state.showCover }, set: { value in
                    model.updateState { $0.showCover = value }
                }))
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
