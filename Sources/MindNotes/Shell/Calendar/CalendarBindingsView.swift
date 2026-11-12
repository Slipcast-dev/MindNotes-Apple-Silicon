import SwiftUI

/// «Какие базы синхронизировать»: раздел настроек синхронизации в MindNotes. При переносе: `Shell/Calendar/`.
struct CalendarBindingsView: View {
    let host: CalendarSyncHost
    @State private var databases: [CalendarDatabaseInfo] = []
    @State private var loading = true

    var body: some View {
        Section(L("Базы данных")) {
            if loading {
                ProgressView().controlSize(.small)
            } else if databases.isEmpty {
                Text(L("Нет баз со свойством «Дата». Добавьте его в «Свойствах» базы."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(databases) { info in row(info) }
                Text(L("Записи со свойством даты становятся событиями Календаря или задачами Напоминаний. Записи без даты синхронизируются только как задачи."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    private func load() async {
        databases = RecordCalendarMapping.candidates((try? await host.source.calendarDatabases()) ?? [])
        loading = false
    }

    @ViewBuilder private func row(_ info: CalendarDatabaseInfo) -> some View {
        let db = info.database
        let b = host.binding(for: db.id)
        DisclosureGroup {
            if let b {
                Picker(L("Куда"), selection: Binding(get: { b.kind }, set: { k in
                    var n = b; n.kind = k
                    if k == .event { n.doneProperty = nil }
                    host.setBinding(n)
                })) {
                    Text(L("События Календаря")).tag(SyncKind.event)
                    Text(L("Задачи Напоминаний")).tag(SyncKind.reminder)
                }
                Picker(L("Свойство даты"), selection: Binding(get: { b.dateProperty }, set: { p in
                    var n = b; n.dateProperty = p; host.setBinding(n)
                })) {
                    ForEach(db.properties.filter { $0.type == .date }) { Text($0.name).tag($0.id) }
                }
                if b.kind == .reminder {
                    Picker(L("Выполнено"), selection: Binding(get: { b.doneProperty }, set: { p in
                        var n = b; n.doneProperty = p; host.setBinding(n)
                    })) {
                        Text(L("Нет")).tag(UUID?.none)
                        ForEach(db.properties.filter { $0.type == .checkbox }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Picker(L("Заметки"), selection: Binding(get: { b.notesProperty }, set: { p in
                    var n = b; n.notesProperty = p; host.setBinding(n)
                })) {
                    Text(L("Нет")).tag(UUID?.none)
                    ForEach(db.properties.filter { $0.type == .text }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Button(L("Отвязать базу"), role: .destructive) { host.removeBinding(db.id) }
                    .help(L("Элементы в Календаре останутся, но больше не будут обновляться"))
            }
        } label: {
            Toggle(isOn: Binding(get: { b?.enabled ?? false }, set: { on in
                if var n = b { n.enabled = on; host.setBinding(n) }
                else if on, let n = RecordCalendarMapping.defaultBinding(db, kind: .reminder) { host.setBinding(n) }
            })) {
                VStack(alignment: .leading) {
                    Text(info.title.isEmpty ? L("Без названия") : info.title)
                    if let b {
                        Text(b.kind == .event ? L("События Календаря") : L("Задачи Напоминаний"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
