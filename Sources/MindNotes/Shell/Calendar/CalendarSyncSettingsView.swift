import AppKit
import SwiftUI

/// Экран «Синхронизация» (макет 2) и его состояния: подключение (макет 1) и нет доступа (макет 5).
/// При переносе в MindNotes встраивается в `SettingsScreen` как `CollapsibleSettingsSection`.
struct CalendarSyncSettingsView: View {
    @Bindable var engine: CalendarSyncEngine
    /// Дополнительные разделы формы: в MindNotes — выбор баз данных (`CalendarBindingsView`).
    var extra: AnyView? = nil
    @State private var showPicker = false
    @State private var refresh = 0

    var body: some View {
        Form {
            if !engine.settings.eventsEnabled && !engine.settings.remindersEnabled {
                Section { CalendarConnectCard(engine: engine) }
            }
            accessWarnings
            kindSection(.event)
            kindSection(.reminder)
            if let extra { extra }
            Section(L("Общие")) {
                Picker(L("При конфликте"), selection: Binding(get: { engine.settings.conflictPolicy },
                                                               set: { engine.setPolicy($0) })) {
                    ForEach(ConflictPolicy.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Button {
                        Task { await engine.syncNow() }
                    } label: {
                        Label(L("Синхронизировать"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(engine.isSyncing)
                    if engine.isSyncing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(lastSyncText).foregroundStyle(.secondary).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPicker) { CalendarPickerView(engine: engine) }
        .id(refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh += 1   // доступ могли выдать или отозвать в Системных настройках
        }
    }

    @ViewBuilder private var accessWarnings: some View {
        ForEach(SyncKind.allCases, id: \.self) { kind in
            if engine.settings.isEnabled(kind) && engine.status(kind) != .granted {
                Section { AccessDeniedBanner(kind: kind) }
            }
        }
    }

    @ViewBuilder private func kindSection(_ kind: SyncKind) -> some View {
        let isEvent = kind == .event
        Section(isEvent ? L("Календарь") : L("Напоминания")) {
            Toggle(isEvent ? L("Синхронизировать события") : L("Синхронизировать задачи"), isOn: Binding(
                get: { engine.settings.isEnabled(kind) },
                set: { on in Task { if on { await engine.enable(kind) } else { engine.disable(kind) } } }))

            if engine.settings.isEnabled(kind) && engine.status(kind) == .granted {
                let editable = engine.gateway.containers(kind).filter(\.isEditable)
                Picker(isEvent ? L("Календарь приложения") : L("Список"), selection: Binding(
                    get: { engine.settings.containerID(kind) ?? "" },
                    set: { id in Task { await engine.setContainer(kind, id: id) } })) {
                    ForEach(editable) { c in
                        Label { Text("\(c.title) · \(c.source)") } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(rgb: c.color)) }
                            .tag(c.id)
                    }
                }
                if isEvent {
                    LabeledContent(L("Показывать календари")) {
                        Button(visibleText) { showPicker = true }
                    }
                    Picker(L("Оповещение"), selection: Binding(get: { engine.settings.defaultAlarmMinutes ?? -1 },
                                                               set: { engine.setDefaultAlarm($0 < 0 ? nil : $0) })) {
                        Text(L("Нет")).tag(-1)
                        Text(L("В момент начала")).tag(0)
                        ForEach([5, 15, 30, 60, 1440], id: \.self) { Text(alarmTitle($0)).tag($0) }
                    }
                } else {
                    Picker(L("Выполненные"), selection: Binding(get: { engine.settings.completedDays },
                                                                set: { engine.setCompletedDays($0) })) {
                        ForEach([7, 30, 90, 365], id: \.self) { Text(L("%d дн.", $0)).tag($0) }
                    }
                }
            }
        }
    }

    private var visibleText: String {
        let all = engine.gateway.containers(.event)
        guard let ids = engine.settings.visibleCalendarIDs else { return L("Все") }
        return L("%d из %d", all.filter { ids.contains($0.id) }.count, all.count)
    }

    private var lastSyncText: String {
        guard let d = engine.settings.lastSyncAt else { return L("Ещё не синхронизировалось") }
        return d.formatted(.relative(presentation: .named))
    }

    private func alarmTitle(_ m: Int) -> String {
        m < 60 ? L("За %d мин", m) : m < 1440 ? L("За %d ч", m / 60) : L("За %d дн.", m / 1440)
    }
}

/// Макет 1: приглашение подключить Календарь и Напоминания.
struct CalendarConnectCard: View {
    let engine: CalendarSyncEngine
    @State private var events = true
    @State private var reminders = true
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary).font(.title3)
                Image(systemName: "checklist")
            }
            .font(.largeTitle)
            .foregroundStyle(.tint)
            Text(L("Подключите Календарь и Напоминания")).font(.headline)
            Text(L("События и задачи будут видны на всех ваших устройствах Apple."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Toggle(L("Календарь"), isOn: $events)
            Toggle(L("Напоминания"), isOn: $reminders)
            Button {
                busy = true
                Task {
                    if events { await engine.enable(.event) }
                    if reminders { await engine.enable(.reminder) }
                    busy = false
                }
            } label: {
                Text(L("Разрешить доступ")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || (!events && !reminders))
        }
        .padding(.vertical, 8)
    }
}

/// Макет 5: доступ запрещён или отозван.
struct AccessDeniedBanner: View {
    let kind: SyncKind

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind == .event ? L("Нет доступа к Календарю") : L("Нет доступа к Напоминаниям")).font(.headline)
                Text(L("Элементы хранятся только в приложении и не видны на других устройствах."))
                    .foregroundStyle(.secondary)
                Button(L("Открыть Системные настройки")) {
                    NSWorkspace.shared.open(EventKitGateway.privacySettingsURL(kind))
                }
            }
        }
    }
}

extension ConflictPolicy {
    var title: String {
        switch self {
        case .ask: return L("Спросить")
        case .newerWins: return L("Новее побеждает")
        case .appWins: return L("Приложение главнее")
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
