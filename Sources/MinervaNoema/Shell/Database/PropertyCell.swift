import AppKit
import SwiftUI

/// В форме с общей кнопкой «Применить» значение передаётся сразу: кнопка не должна видеть устаревшее.
private struct LiveCommitKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var liveCommit: Bool {
        get { self[LiveCommitKey.self] }
        set { self[LiveCommitKey.self] = newValue }
    }
}

/// Поле с подтверждением: значение записывается по Return, при уходе фокуса или исчезновении поля, а не на каждую букву.
struct CommitField: View {
    @Environment(\.liveCommit) private var live
    let value: String
    var placeholder = ""
    var bold = false
    let onCommit: (String) -> Void
    @State private var draft = ""
    /// Return и последующая потеря фокуса — одна правка.
    @State private var committed: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: bold ? .semibold : .regular))
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in
                draft = new
                committed = nil
            }
            .onChange(of: draft) { _, new in if live, new != value { onCommit(new) } }
            .onSubmit(commit)
            .onChange(of: focused) { _, new in if !new { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard !live, draft != value, draft != committed else { return }
        committed = draft
        onCommit(draft)
    }
}

/// Значение свойства: одинаково в таблице, карточке записи и массовом изменении.
struct PropertyCell: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.liveCommit) private var live
    let property: PropertyDefinition
    let value: PropertyValue?
    let onChange: (PropertyValue?) -> Void

    var body: some View {
        if case .unconverted(let raw)? = value {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundColor(Tokens.danger).font(.system(size: 11))
                Text(raw).font(.system(size: 13)).foregroundColor(Tokens.danger).lineLimit(1)
                if property.type.isKnown {
                    Button { onChange(nil) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain)
                        .foregroundColor(Tokens.muted)
                        .help(L("Очистить значение"))
                        .accessibilityLabel(Text("Очистить значение"))
                }
            }
            .help(L("Значение не удалось преобразовать при смене типа. Оно сохранено как есть."))
        } else {
            editor
        }
    }

    @ViewBuilder private var editor: some View {
        switch property.type {
        case .text:
            CommitField(value: textValue, placeholder: L("Пусто")) { onChange($0.isEmpty ? nil : .text($0)) }
        case .number:
            CommitField(value: numberValue, placeholder: L("Пусто")) { text in
                if text.trimmingCharacters(in: .whitespaces).isEmpty { return onChange(nil) }
                if let n = PropertyParse.number(text) { onChange(.number(n)) } else if live { onChange(nil) } else { shell.notice = L("Введите число.") }
            }
        case .url:
            HStack(spacing: 6) {
                CommitField(value: textValue, placeholder: L("Пусто")) { text in
                    if text.trimmingCharacters(in: .whitespaces).isEmpty { return onChange(nil) }
                    if let url = PropertyParse.url(text) { onChange(.url(url)) } else if live { onChange(nil) } else { shell.notice = L("Некорректный адрес. Допустимы http, https и mailto.") }
                }
                if let link = PropertyParse.openable(textValue), !textValue.isEmpty {
                    Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain)
                        .foregroundColor(Tokens.accent)
                        .help(L("Открыть ссылку"))
                        .accessibilityLabel(Text("Открыть ссылку"))
                }
            }
        case .checkbox:
            Toggle("", isOn: Binding(get: { if case .checkbox(true)? = value { return true } else { return false } }, set: { onChange(.checkbox($0)) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(property.name))
        case .status, .select: singleMenu
        case .multiSelect: multiMenu
        case .date: DateCell(value: dateValue, onChange: onChange)
        case .relation: RelationCell(property: property, value: value, onChange: onChange)
        case .createdTime, .editedTime:
            // Время берётся из записи и вручную не меняется.
            Text(PropertyDisplay.text(value, property: property) ?? L("Пусто"))
                .font(.system(size: 13))
                .foregroundColor(Tokens.muted)
                .lineLimit(1)
                .help(L("Заполняется автоматически"))
        default:
            Text(L("Неизвестный тип: %@", property.type.rawValue)).font(.system(size: 12)).foregroundColor(Tokens.muted)
        }
    }

    private var textValue: String {
        switch value {
        case .text(let s)?, .url(let s)?: return s
        default: return ""
        }
    }

    private var numberValue: String {
        if case .number(let n)? = value { return PropertyParse.numberText(n) }
        return ""
    }

    private var dateValue: DateValue? {
        if case .date(let d)? = value { return d }
        return nil
    }

    private var chosen: [UUID] {
        if case .options(let ids)? = value { return ids }
        return []
    }

    private func chip(_ option: PropertyOption) -> some View {
        Chip(text: option.name, colors: Tokens.swatch(option.color) ?? (Tokens.soft, Tokens.ink))
    }

    /// Меню стирает оформление подписи, поэтому прозрачное меню лежит поверх видимых значков.
    private func menuBody<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        let selected = property.options.filter { chosen.contains($0.id) }
        return HStack(spacing: 4) {
            if selected.isEmpty { Text("Пусто").font(.system(size: 13)).foregroundColor(Tokens.muted) }
            ForEach(selected) { chip($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .contentShape(Rectangle())
        .overlay {
            Menu(content: items) { Color.clear }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .opacity(0.02)
                .accessibilityLabel(Text(property.name))
        }
    }

    private var singleMenu: some View {
        menuBody {
            ForEach(property.options) { option in
                Button(option.name) { onChange(.options([option.id])) }
            }
            if property.options.isEmpty { Text("Нет вариантов: добавьте их в «Свойствах»") }
            if !chosen.isEmpty {
                Divider()
                Button("Очистить") { onChange(nil) }
            }
        }
    }

    private var multiMenu: some View {
        menuBody {
            ForEach(property.options) { option in
                Button {
                    let next = chosen.contains(option.id) ? chosen.filter { $0 != option.id } : chosen + [option.id]
                    onChange(next.isEmpty ? nil : .options(next))
                } label: {
                    if chosen.contains(option.id) { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
            if property.options.isEmpty { Text("Нет вариантов: добавьте их в «Свойствах»") }
        }
    }
}

/// Дата или диапазон, с временем или без. День без времени никогда не проходит через момент: он остаётся `LocalDate`.
struct DateCell: View {
    let value: DateValue?
    let onChange: (PropertyValue?) -> Void
    @State private var open = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var hasEnd = false
    @State private var hasTime = false
    @State private var zone = TimeZone.current

    var body: some View {
        Button { prepare(); open = true } label: {
            Text(value.map(PropertyDisplay.date) ?? L("Пусто"))
                .font(.system(size: 13))
                .foregroundColor(value == nil ? Tokens.muted : Tokens.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { form }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Начало", selection: $start, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
            if hasEnd {
                DatePicker("Конец", selection: $end, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                if !isOrdered { Text("Конец раньше начала.").font(.system(size: 12)).foregroundColor(Tokens.danger) }
            }
            Toggle("Диапазон", isOn: $hasEnd)
            Toggle("Со временем", isOn: $hasTime)
            HStack {
                if value != nil {
                    Button("Очистить") { open = false; onChange(nil) }.buttonStyle(NotesButtonStyle(kind: .plain))
                }
                Spacer()
                Button("Готово") { open = false; onChange(.date(built)) }
                    .buttonStyle(NotesButtonStyle(kind: .primary))
                    .disabled(!isOrdered)
            }
        }
        .environment(\.timeZone, zone)
        .padding(14)
        .frame(width: 280)
    }

    private var isOrdered: Bool { built.isValid }

    private var built: DateValue {
        func point(_ date: Date) -> DatePoint {
            hasTime ? .moment(ms: Int64(date.timeIntervalSince1970 * 1000), zone: zone.identifier) : .day(LocalDate(date: date, in: zone))
        }
        return DateValue(start: point(start), end: hasEnd ? point(end) : nil)
    }

    private func prepare() {
        zone = .current
        func date(_ point: DatePoint) -> Date {
            switch point {
            case .day(let d): return d.date(in: zone)
            case .moment(let ms, _): return Date(timeIntervalSince1970: Double(ms) / 1000)
            }
        }
        guard let value else {
            start = LocalDate(date: Date(), in: zone).date(in: zone)
            end = start
            hasEnd = false
            hasTime = false
            return
        }
        if case .moment(_, let id) = value.start {
            zone = TimeZone(identifier: id) ?? .current
            hasTime = true
        } else {
            hasTime = false
        }
        start = date(value.start)
        end = value.end.map(date) ?? start
        hasEnd = value.end != nil
    }
}

/// Карточка записи: свойства над текстом обычной страницы.
struct RecordPropertiesPanel: View {
    @EnvironmentObject private var shell: ShellModel
    let page: UUID
    let databaseID: UUID
    @State private var database: Database?
    @State private var values: [UUID: PropertyValue] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(database?.properties.filter { $0.type != .title } ?? []) { property in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(property.name).font(.system(size: 13)).foregroundColor(Tokens.muted).lineLimit(1).frame(width: 140, alignment: .leading)
                    PropertyCell(property: property, value: values[property.id]) { new in
                        save(property.id, new)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.bottom, 16)
        .task(id: page) { await load() }
    }

    private func load() async {
        guard let store = shell.store else { return }
        do {
            database = try await store.database(databaseID)
            if let database { values = try await store.recordValues(page: page, database: database) }
        } catch { shell.errorMessage = error.localizedDescription }
    }

    private func save(_ property: UUID, _ value: PropertyValue?) {
        guard let store = shell.store else { return }
        Task {
            do { try await store.setValue(pages: [page], property: property, value: value, now: SystemClock().nowMillis()) }
            catch { shell.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            await load() // Экран показывает то, что записано, а не то, что хотели записать.
        }
    }
}
