import AppKit
import SwiftUI

/// Настройки синхронизации в оформлении MindNotes: карточки со строками «название — элемент управления».
/// В MindNotes встраивается в `SettingsScreen` внутри `CollapsibleSettingsSection`.
struct CalendarSyncSettingsView: View {
    @Bindable var engine: CalendarSyncEngine
    /// Дополнительные разделы: в MindNotes — выбор баз данных (`CalendarBindingsView`).
    var extra: AnyView? = nil
    @State private var showPicker = false
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !engine.settings.eventsEnabled && !engine.settings.remindersEnabled {
                CalCard { CalendarConnectCard(engine: engine) }.padding(.bottom, 8)
            }
            ForEach(SyncKind.allCases, id: \.self) { kind in
                if engine.settings.isEnabled(kind) && engine.status(kind) != .granted && engine.status(kind) != .notDetermined {
                    AccessDeniedBanner(kind: kind).padding(.bottom, 8)
                }
            }
            kindSection(.event)
            kindSection(.reminder)
            if let extra { extra }
            CalSectionTitle(L("Общие"))
            CalCard {
                CalRow(L("При конфликте"), L("Что делать, если элемент изменили и здесь, и в Календаре")) {
                    Picker("", selection: Binding(get: { engine.settings.conflictPolicy }, set: { engine.setPolicy($0) })) {
                        ForEach(ConflictPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                CalDivider()
                CalRow(L("Синхронизировать"), lastSyncText) {
                    HStack(spacing: 8) {
                        if engine.isSyncing { ProgressView().controlSize(.small) }
                        Button { Task { await engine.syncNow() } } label: {
                            Label(L("Синхронизировать"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(CalButtonStyle(kind: .normal))
                        .disabled(engine.isSyncing)
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) { CalendarPickerView(engine: engine) }
        .id(refresh)
        .onAppear { engine.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            engine.refreshAccess()   // доступ могли выдать или отозвать в Системных настройках
            refresh += 1
        }
    }

    @ViewBuilder private func kindSection(_ kind: SyncKind) -> some View {
        let isEvent = kind == .event
        CalSectionTitle(isEvent ? L("Календарь") : L("Напоминания"))
        CalCard {
            CalRow(isEvent ? L("Синхронизировать события") : L("Синхронизировать задачи"),
                   isEvent ? L("События появятся в Календаре на всех устройствах Apple")
                           : L("Задачи появятся в Напоминаниях на всех устройствах Apple")) {
                Toggle("", isOn: Binding(get: { engine.settings.isEnabled(kind) },
                                         set: { on in Task { if on { await engine.enable(kind) } else { engine.disable(kind) } } }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if engine.settings.isEnabled(kind) && engine.status(kind) == .granted {
                let editable = engine.gateway.containers(kind).filter(\.isEditable)
                CalDivider()
                CalRow(isEvent ? L("Календарь приложения") : L("Список"),
                       isEvent ? L("Куда записываются события приложения") : L("Куда записываются задачи приложения")) {
                    Picker("", selection: Binding(get: { engine.settings.containerID(kind) ?? "" },
                                                  set: { id in Task { await engine.setContainer(kind, id: id) } })) {
                        ForEach(editable) { c in Text("\(c.title) · \(c.source)").tag(c.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                if isEvent {
                    CalDivider()
                    CalRow(L("Показывать календари"), L("Какие календари видны в разделе «Календарь»")) {
                        Button(visibleText) { showPicker = true }.buttonStyle(CalButtonStyle(kind: .normal))
                    }
                    CalDivider()
                    CalRow(L("Оповещение"), L("Для новых событий")) {
                        Picker("", selection: Binding(get: { engine.settings.defaultAlarmMinutes ?? -1 },
                                                      set: { engine.setDefaultAlarm($0 < 0 ? nil : $0) })) {
                            Text(L("Нет")).tag(-1)
                            Text(L("В момент начала")).tag(0)
                            ForEach([5, 15, 30, 60, 1440], id: \.self) { Text(alarmTitle($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                } else {
                    CalDivider()
                    CalRow(L("Выполненные"), L("За какой срок показывать выполненные задачи")) {
                        Picker("", selection: Binding(get: { engine.settings.completedDays }, set: { engine.setCompletedDays($0) })) {
                            ForEach([7, 30, 90, 365], id: \.self) { Text(L("%d дн.", $0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
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

// MARK: Карточки в стиле настроек MindNotes

struct CalSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 17, weight: .semibold)).foregroundStyle(CalStyle.ink)
            .padding(.top, 22).padding(.bottom, 10)
    }
}

struct CalCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 12).fill(CalStyle.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(CalStyle.line))
    }
}

struct CalRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control

    init(_ title: String, _ subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(CalStyle.ink)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(CalStyle.muted) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 13)
    }
}

struct CalDivider: View {
    var body: some View { Rectangle().fill(CalStyle.line).frame(height: 1) }
}

/// Приглашение подключить Календарь и Напоминания.
struct CalendarConnectCard: View {
    let engine: CalendarSyncEngine
    @State private var events = true
    @State private var reminders = true
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(CalStyle.muted).font(.title3)
                Image(systemName: "checklist")
            }
            .font(.system(size: 30))
            .foregroundStyle(CalStyle.accent)
            Text(L("Подключите Календарь и Напоминания")).font(CalStyle.titleFont(22)).foregroundStyle(CalStyle.ink)
            Text(L("События и задачи будут видны на всех ваших устройствах Apple."))
                .font(.system(size: 13)).foregroundStyle(CalStyle.muted).multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Toggle(L("Календарь"), isOn: $events)
                Toggle(L("Напоминания"), isOn: $reminders)
            }
            .toggleStyle(.checkbox)
            Button {
                busy = true
                Task {
                    if events { await engine.enable(.event) }
                    if reminders { await engine.enable(.reminder) }
                    busy = false
                }
            } label: { Text(L("Разрешить доступ")) }
            .buttonStyle(CalButtonStyle(kind: .primary))
            .disabled(busy || (!events && !reminders))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

/// Доступ запрещён или отозван. Отдельно объясняет случай, когда в Системных настройках доступ уже включён:
/// macOS запомнила разрешение для прежней сборки, и его нужно сбросить.
struct AccessDeniedBanner: View {
    let kind: SyncKind
    @State private var copied = false

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "local.personal.MindNotes" }
    private var command: String { "tccutil reset Calendar \(bundleID); tccutil reset Reminders \(bundleID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CalStyle.danger)
                Text(kind == .event ? L("Нет доступа к Календарю") : L("Нет доступа к Напоминаниям"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(CalStyle.ink)
            }
            Text(L("Элементы хранятся только в приложении и не видны на других устройствах."))
                .font(.system(size: 13)).foregroundStyle(CalStyle.muted)
            Button(L("Открыть Системные настройки")) { NSWorkspace.shared.open(EventKitGateway.privacySettingsURL(kind)) }
                .buttonStyle(CalButtonStyle(kind: .primary))
            CalDivider()
            Text(L("Доступ уже включён, а приложение его не видит?"))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(CalStyle.ink)
            Text(L("macOS запомнила разрешение для прежней сборки. Закройте приложение, выполните команду в Терминале, откройте приложение снова и нажмите «Разрешить доступ»."))
                .font(.system(size: 12)).foregroundStyle(CalStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(CalStyle.ink)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(CalStyle.soft))
                Button(copied ? L("Скопировано") : L("Скопировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .buttonStyle(CalButtonStyle(kind: .normal))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(CalStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CalStyle.danger.opacity(0.5)))
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
