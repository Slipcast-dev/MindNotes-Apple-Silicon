import AppKit
import SwiftUI

/// Свои сочетания клавиш поверх стандартных (`ShortcutCatalog`). Хранятся в `UserDefaults` этой копии приложения.
@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    private static let key = "keyboardShortcuts"

    @Published private(set) var overrides: [String: KeyShortcut]

    private init() {
        overrides = ShortcutCatalog.decode(UserDefaults.standard.data(forKey: Self.key))
    }

    func shortcut(_ id: String) -> KeyShortcut? { ShortcutCatalog.effective(id, overrides: overrides) }

    /// Подпись для подсказок и боковой панели: «⌘L»; пусто, если сочетания нет.
    func display(_ id: String) -> String { shortcut(id)?.display ?? "" }

    func isCustom(_ id: String) -> Bool { overrides[id] != nil && overrides[id] != ShortcutCatalog.find(id)?.standard }

    /// Новое сочетание; у команд с тем же сочетанием оно снимается.
    func set(_ id: String, _ shortcut: KeyShortcut) {
        var next = overrides
        if !shortcut.isNone {
            for other in ShortcutCatalog.conflicts(of: shortcut, for: id, overrides: next) { next[other.id] = .none }
        }
        next[id] = shortcut == ShortcutCatalog.find(id)?.standard ? nil : shortcut
        save(next)
    }

    func reset(_ id: String) {
        var next = overrides
        next[id] = nil
        // Стандартное сочетание могло достаться другой команде: у неё оно снимается.
        if let standard = ShortcutCatalog.find(id)?.standard, !standard.isNone {
            for other in ShortcutCatalog.conflicts(of: standard, for: id, overrides: next) { next[other.id] = .none }
        }
        save(next)
    }

    func resetAll() { save([:]) }

    private func save(_ map: [String: KeyShortcut]) {
        overrides = map
        UserDefaults.standard.set(ShortcutCatalog.encode(map), forKey: Self.key)
    }
}

extension KeyShortcut {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "return": return .return
        case "tab": return .tab
        case "space": return .space
        case "delete": return .delete
        default: return KeyEquivalent(Character(key))
        }
    }

    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// Сочетание из нажатия клавиши; nil — клавиша не подходит.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let special: [UInt16: String] = [126: "up", 125: "down", 123: "left", 124: "right", 36: "return", 76: "return", 48: "tab", 49: "space", 51: "delete"]
        let key: String
        if let name = special[event.keyCode] {
            key = name
        } else {
            // Без учёта ⇧ и ⌥: на клавише остаётся её собственный символ.
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1, let c = chars.first, !c.isWhitespace, c.isASCII else { return nil }
            key = String(c)
        }
        self.init(key: key, command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
    }
}

extension View {
    /// Сочетание команды из настроек; без сочетания — как обычная кнопка.
    @ViewBuilder
    func appShortcut(_ shortcut: KeyShortcut?) -> some View {
        if let shortcut { keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers) } else { self }
    }
}

/// «Настройки → Сочетания клавиш»: стандартное значение, своё, сброс одной команды и всех.
struct ShortcutsSettings: View {
    @ObservedObject private var settings = ShortcutSettings.shared
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button(L("Сбросить все")) {
                    guard PromptAlert.confirm(L("Вернуть стандартные сочетания клавиш?"), detail: L("Все свои сочетания будут заменены стандартными."), action: L("Сбросить")) else { return }
                    stopRecording()
                    settings.resetAll()
                    message = L("Восстановлены стандартные сочетания.")
                }
                .buttonStyle(NotesButtonStyle())
                .disabled(settings.overrides.isEmpty)
            }
            .padding(.bottom, 4)
            Text("Нажмите на сочетание, чтобы задать своё: зажмите ⌘ или ⌃ с нужной клавишей. Esc — отмена, ⌫ — убрать сочетание.")
                .font(.system(size: 13)).foregroundColor(Tokens.muted).padding(.bottom, 10)
            if let message {
                Label(message, systemImage: "info.circle").font(.system(size: 12)).foregroundColor(Tokens.muted).padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                ForEach(AppShortcut.Group.allCases, id: \.self) { group in
                    let items = ShortcutCatalog.all.filter { $0.group == group }
                    Text(L(group.title)).font(.system(size: 12, weight: .semibold)).foregroundColor(Tokens.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(.bottom, 4)
                    ForEach(items) { item in row(item) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
        }
        .onDisappear { stopRecording() }
    }

    private func row(_ item: AppShortcut) -> some View {
        HStack(spacing: 10) {
            Text(L(item.title)).font(.system(size: 13))
            Spacer()
            if settings.isCustom(item.id) {
                Text(item.standard.isNone ? L("Стандартно: нет") : String(format: L("Стандартно: %@"), item.standard.display))
                    .font(.system(size: 11)).foregroundColor(Tokens.muted)
                Button { settings.reset(item.id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).foregroundColor(Tokens.muted)
                    .help(L("Вернуть стандартное")).accessibilityLabel(Text("Вернуть стандартное"))
            }
            Button { toggleRecording(item.id) } label: {
                Text(recording == item.id ? L("Нажмите сочетание…") : (settings.shortcut(item.id)?.display ?? L("Нет")))
                    .font(.system(size: 12, design: recording == item.id ? .default : .monospaced))
                    .foregroundColor(recording == item.id ? Tokens.accent : Tokens.ink)
                    .frame(minWidth: 110)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.paper))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording == item.id ? Tokens.accent : Tokens.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(format: L("Сочетание для «%@»"), L(item.title))))
        }
        .padding(.vertical, 5)
    }

    private func toggleRecording(_ id: String) {
        if recording == id { return stopRecording() }
        stopRecording()
        recording = id
        message = nil
        // Перехват до меню: пока идёт запись, нажатие не выполняет команду, а задаёт сочетание.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let id = recording else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 { return stopRecording() } // Esc
        if event.keyCode == 51, flags.isEmpty { // ⌫ без модификаторов — убрать сочетание
            settings.set(id, .none)
            return stopRecording()
        }
        guard let shortcut = KeyShortcut(event: event), shortcut.isValid else {
            message = L("Нужна клавиша вместе с ⌘ или ⌃.")
            return
        }
        let taken = ShortcutCatalog.conflicts(of: shortcut, for: id, overrides: settings.overrides)
        settings.set(id, shortcut)
        message = taken.isEmpty ? nil : String(format: L("%@ было у «%@» — там сочетание снято."), shortcut.display, taken.map { L($0.title) }.joined(separator: "», «"))
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
