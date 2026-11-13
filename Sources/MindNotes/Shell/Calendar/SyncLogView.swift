import SwiftUI

/// Журнал синхронизации (нижняя часть макета 5).
struct SyncLogView: View {
    let engine: CalendarSyncEngine

    var body: some View {
        VStack(spacing: 0) {
            if engine.log.isEmpty {
                ContentUnavailableView(L("Журнал пуст"), systemImage: "list.bullet.rectangle",
                                       description: Text(L("Здесь появятся операции синхронизации.")))
            } else {
                List(engine.log) { e in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: icon(e.level)).foregroundStyle(color(e.level))
                        Text(e.message.text).foregroundStyle(CalStyle.ink)
                        Spacer()
                        Text(e.date.formatted(date: .omitted, time: .standard)).foregroundStyle(CalStyle.muted).font(.caption)
                    }
                    .listRowSeparatorTint(CalStyle.line)
                }
                .scrollContentBackground(.hidden)
            }
            HStack {
                Spacer()
                Button(L("Очистить")) { engine.clearLog() }.buttonStyle(CalButtonStyle(kind: .normal)).disabled(engine.log.isEmpty)
            }
            .padding(10)
        }
    }

    private func icon(_ l: SyncLogEntry.Level) -> String {
        switch l { case .info: return "info.circle"; case .warning: return "exclamationmark.triangle"; case .error: return "xmark.octagon" }
    }

    private func color(_ l: SyncLogEntry.Level) -> Color {
        switch l { case .info: return .secondary; case .warning: return .orange; case .error: return .red }
    }
}

extension SyncMessage {
    var text: String {
        switch self {
        case .noAccess(let k): return k == .event ? L("Нет доступа к Календарю") : L("Нет доступа к Напоминаниям")
        case .disabled(let k): return k == .event ? L("Синхронизация событий выключена") : L("Синхронизация задач выключена")
        case .createFailed(let e): return L("Не удалось создать календарь: %@", e)
        case .openFailed(let e): return L("Не удалось открыть календарь: %@", e)
        case .readFailed(let e): return L("Не удалось прочитать Календарь: %@", e)
        case .failed(let e): return L("Ошибка синхронизации: %@", e)
        case .recreated: return L("Календарь приложения пропал и создан заново")
        case .containerDeleted(let k): return k == .event
            ? L("Календарь синхронизации удалён: синхронизация событий выключена")
            : L("Список синхронизации удалён: синхронизация задач выключена")
        case .resolved(let app): return app ? L("Конфликт решён: оставлена версия приложения") : L("Конфликт решён: оставлена версия Календаря")
        case .text(let t): return t
        case .summary(let s):
            var parts: [String] = []
            if s.pushed > 0 { parts.append(L("отправлено: %d", s.pushed)) }
            if s.pulled > 0 { parts.append(L("получено: %d", s.pulled)) }
            if s.imported > 0 { parts.append(L("импортировано: %d", s.imported)) }
            if s.deletedThere > 0 { parts.append(L("удалено в Календаре: %d", s.deletedThere)) }
            if s.deletedHere > 0 { parts.append(L("удалено в приложении: %d", s.deletedHere)) }
            if s.conflicts > 0 { parts.append(L("конфликтов: %d", s.conflicts)) }
            if s.failures > 0 { parts.append(L("ошибок: %d", s.failures)) }
            return L("Синхронизация: %@", parts.joined(separator: ", "))
        }
    }
}
