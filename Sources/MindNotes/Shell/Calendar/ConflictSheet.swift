import SwiftUI

/// Макет 4: элемент изменён и в приложении, и в Календаре.
struct ConflictSheet: View {
    let engine: CalendarSyncEngine
    let conflict: SyncConflict
    @State private var keepApp = true

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.merge").font(.largeTitle).foregroundStyle(.orange)
            Text(conflict.local.kind == .event ? L("Событие изменено в двух местах") : L("Задача изменена в двух местах"))
                .font(.headline)
            Text(L("Выберите, какую версию оставить")).foregroundStyle(.secondary)

            version(title: L("Приложение"), icon: "macwindow", fields: conflict.local.fields,
                    date: conflict.local.updatedAt, chosen: keepApp) { keepApp = true }
            version(title: conflict.local.kind == .event ? L("Календарь") : L("Напоминания"),
                    icon: conflict.local.kind == .event ? "calendar" : "checklist",
                    fields: conflict.remote.fields, date: conflict.remote.modifiedAt, chosen: !keepApp) { keepApp = false }

            HStack {
                Button(L("Всегда выбирать новее")) { Task { await engine.resolveAllByNewer() } }
                Spacer()
                Button(L("Оставить выбранную")) { Task { await engine.resolve(conflict, keepApp: keepApp) } }
                    .buttonStyle(CalButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(CalStyle.paper)
    }

    private func version(title: String, icon: String, fields: SyncFields, date: Date, chosen: Bool,
                         pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary).font(.caption)
                }
                Text(fields.title)
                if let s = fields.start {
                    Text(s.formatted(date: .abbreviated, time: fields.isAllDay ? .omitted : .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if fields.isCompleted { Text(L("Выполнено")).font(.caption).foregroundStyle(.green) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(chosen ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
