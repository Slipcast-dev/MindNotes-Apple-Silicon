import SwiftUI

/// «Какие базы синхронизировать»: раздел настроек синхронизации в MindNotes. При переносе: `Shell/Calendar/`.
struct CalendarBindingsView: View {
    let host: CalendarSyncHost
    @State private var databases: [CalendarDatabaseInfo] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalSectionTitle(L("Базы данных"))
            CalCard {
                if loading {
                    ProgressView().controlSize(.small).padding(.vertical, 13)
                } else if databases.isEmpty {
                    Text(L("Нет баз со свойством «Дата». Добавьте его в «Свойствах» базы."))
                        .font(.system(size: 13)).foregroundStyle(CalStyle.muted).padding(.vertical, 13)
                } else {
                    ForEach(Array(databases.enumerated()), id: \.element.id) { i, info in
                        if i > 0 { CalDivider() }
                        row(info)
                    }
                }
            }
            Text(L("Записи со свойством даты становятся событиями Календаря или задачами Напоминаний. Записи без даты синхронизируются только как задачи."))
                .font(.system(size: 12)).foregroundStyle(CalStyle.muted).padding(.top, 8)
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
        CalRow(info.title.isEmpty ? L("Без названия") : info.title,
               b.map { $0.kind == .event ? L("События Календаря") : L("Задачи Напоминаний") } ?? L("Не синхронизируется")) {
            Toggle("", isOn: Binding(get: { b?.enabled ?? false }, set: { on in
                if var n = b { n.enabled = on; host.setBinding(n) }
                else if on, let n = RecordCalendarMapping.defaultBinding(db, kind: .reminder) { host.setBinding(n) }
            }))
            .toggleStyle(.switch).labelsHidden()
        }
        if let b, b.enabled {
            VStack(alignment: .leading, spacing: 0) {
                CalRow(L("Куда")) {
                    Picker("", selection: Binding(get: { b.kind }, set: { k in
                        var n = b; n.kind = k
                        if k == .event { n.doneProperty = nil }
                        host.setBinding(n)
                    })) {
                        Text(L("События Календаря")).tag(SyncKind.event)
                        Text(L("Задачи Напоминаний")).tag(SyncKind.reminder)
                    }
                    .labelsHidden().fixedSize()
                }
                CalRow(L("Свойство даты")) {
                    Picker("", selection: Binding(get: { b.dateProperty }, set: { p in var n = b; n.dateProperty = p; host.setBinding(n) })) {
                        ForEach(db.properties.filter { $0.type == .date }) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                if b.kind == .reminder {
                    CalRow(L("Выполнено")) {
                        Picker("", selection: Binding(get: { b.doneProperty }, set: { p in var n = b; n.doneProperty = p; host.setBinding(n) })) {
                            Text(L("Нет")).tag(UUID?.none)
                            ForEach(db.properties.filter { $0.type == .checkbox }) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                CalRow(L("Заметки")) {
                    Picker("", selection: Binding(get: { b.notesProperty }, set: { p in var n = b; n.notesProperty = p; host.setBinding(n) })) {
                        Text(L("Нет")).tag(UUID?.none)
                        ForEach(db.properties.filter { $0.type == .text }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
                HStack {
                    Spacer()
                    Button(L("Отвязать базу"), role: .destructive) { host.removeBinding(db.id) }
                        .buttonStyle(CalButtonStyle(kind: .plain))
                        .help(L("Элементы в Календаре останутся, но больше не будут обновляться"))
                }
                .padding(.bottom, 8)
            }
            .padding(.leading, 18)
        }
    }
}
