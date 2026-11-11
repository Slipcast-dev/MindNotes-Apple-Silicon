import AppKit
import SwiftUI

/// «Настройки → ИИ» (FR-AI-1): выключатель с согласием, ключ в Keychain, модель, глубина, подтверждения, расход.
struct AISettingsSection: View {
    @ObservedObject private var settings = AISettings.shared
    @ObservedObject private var data = AIWorkspace.shared
    @EnvironmentObject private var shell: ShellModel
    @State private var keyDraft = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(AIStyle.tint)
                Text("ИИ").font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 24).padding(.bottom, 4)
            Text("Необязательный помощник на модели Claude. Пока он выключен, приложение не отправляет никаких запросов.")
                .font(.system(size: 13)).foregroundColor(Tokens.muted).padding(.bottom, 10)
            VStack(spacing: 0) {
                row(L("Включить ИИ"), settings.enabled ? L("Текст, к которому вы обращаетесь к ИИ, отправляется в Anthropic") : L("Выключено")) {
                    Toggle("", isOn: Binding(get: { settings.enabled }, set: setEnabled)).labelsHidden().toggleStyle(.switch)
                }
                if settings.enabled {
                    divider
                    row(L("Ключ API"), settings.hasKey ? L("Сохранён в связке ключей macOS") : L("Ключ можно получить в консоли Claude: platform.claude.com")) {
                        if settings.hasKey {
                            Button(L("Проверить")) { check() }.buttonStyle(NotesButtonStyle()).disabled(checking)
                            Button(L("Удалить ключ")) { settings.deleteKey(); checkResult = nil }.buttonStyle(NotesButtonStyle(kind: .plain))
                        } else {
                            SecureField(L("Вставьте ключ"), text: $keyDraft).textFieldStyle(.roundedBorder).frame(width: 220)
                            Button(L("Сохранить")) {
                                settings.saveKey(keyDraft)
                                keyDraft = ""
                                check()
                            }
                            .buttonStyle(NotesButtonStyle())
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let checkResult {
                        Label(checkResult, systemImage: checkFailed ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.system(size: 12)).foregroundColor(checkFailed ? Tokens.danger : Tokens.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
                    }
                    divider
                    row(L("Модель"), L("«Авто» — Claude Opus 5.5")) {
                        Picker("", selection: $settings.model) {
                            ForEach(models, id: \.self) { Text($0 == AIDefaults.model ? L("Авто") + " (\($0))" : $0).tag($0) }
                        }
                        .labelsHidden().frame(width: 260)
                    }
                    divider
                    row(L("Глубина ответов в чате"), L("Тщательнее — дольше и дороже")) {
                        Picker("", selection: $settings.chatEffort) {
                            Text("Быстро").tag(AIEffort.low)
                            Text("Обычно").tag(AIEffort.medium)
                            Text("Тщательно").tag(AIEffort.high)
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    divider
                    row(L("Спрашивать перед созданием страниц"), L("Изменение и удаление существующего ИИ всегда сначала предлагает")) {
                        Toggle("", isOn: $settings.confirmCreation).labelsHidden().toggleStyle(.switch)
                    }
                    if shell.isOpen {
                        divider
                        row(L("Инструкции для ИИ"), L("Страница со стилем и правилами: ИИ читает её перед каждым ответом")) {
                            Button(data.instructionsPage == nil ? L("Создать") : L("Открыть")) { data.openInstructions(shell: shell) }
                                .buttonStyle(NotesButtonStyle())
                        }
                        divider
                        row(L("История чатов"), String(format: L("Сохранено чатов: %d. Хранится в пространстве и входит в резервную копию."), data.chats.count)) {
                            Button(L("Удалить историю")) {
                                guard PromptAlert.confirm(L("Удалить историю чатов?"), detail: L("Это действие нельзя отменить."), action: L("Удалить")) else { return }
                                data.deleteAllChats()
                                AIChatModel.shared.reset()
                            }
                            .buttonStyle(NotesButtonStyle(kind: .plain))
                            .disabled(data.chats.isEmpty)
                        }
                    }
                    divider
                    row(L("Расход"), usageText) { EmptyView() }
                }
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
        }
    }

    private var models: [String] {
        var list = settings.availableModels.isEmpty ? AISettings.fallbackModels : settings.availableModels
        if !list.contains(AIDefaults.model) { list.insert(AIDefaults.model, at: 0) }
        if !list.contains(settings.model) { list.append(settings.model) }
        return list
    }

    private var usageText: String {
        let today = settings.today, month = settings.thisMonth
        return String(format: L("Сегодня: %d токенов, месяц: %d токенов, около $%.2f"),
                      today.input + today.output + today.cacheRead + today.cacheWrite,
                      month.input + month.output + month.cacheRead + month.cacheWrite,
                      AIPricing.dollars(month, model: settings.model))
    }

    private func setEnabled(_ on: Bool) {
        guard on else {
            settings.enabled = false
            AIAssist.shared.close()
            AIChatModel.shared.stop()
            return
        }
        if !settings.consentGiven {
            let alert = NSAlert()
            alert.messageText = L("Включить ИИ?")
            alert.informativeText = L("Когда вы обращаетесь к ИИ, выделенный текст, открытая страница или найденные фрагменты отправляются в Anthropic (Claude API) по вашему ключу. Без вашего действия ничего не отправляется. Ключ хранится в связке ключей macOS. Выключить ИИ можно здесь же в любой момент.")
            alert.addButton(withTitle: L("Включить"))
            alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            settings.consentGiven = true
        }
        settings.enabled = true
        settings.refreshKey()
    }

    private func check() {
        checking = true
        checkResult = nil
        Task { @MainActor in
            defer { checking = false }
            do {
                let list = try await AIClient.models()
                settings.availableModels = list.filter { $0.hasPrefix("claude-") }
                checkFailed = false
                checkResult = L("Ключ работает.")
            } catch {
                checkFailed = true
                checkResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var divider: some View { Rectangle().fill(Tokens.line).frame(height: 1) }

    private func row<Control: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(2)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 15)
    }
}
