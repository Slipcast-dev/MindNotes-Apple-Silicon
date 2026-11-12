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
    @State private var urlDraft = ""
    @State private var modelDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(AIStyle.tint)
                Text("ИИ").font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 24).padding(.bottom, 4)
            Text("Необязательный помощник: Claude, OpenAI, Gemini, DeepSeek и другие провайдеры или модель на этом Mac. Пока он выключен, приложение не отправляет никаких запросов.")
                .font(.system(size: 13)).foregroundColor(Tokens.muted).padding(.bottom, 10)
            VStack(spacing: 0) {
                row(L("Включить ИИ"), settings.enabled
                    ? (settings.provider.isLocal ? L("Текст обрабатывает модель на этом Mac") : String(format: L("Текст, к которому вы обращаетесь к ИИ, отправляется в %@"), settings.provider.name))
                    : L("Выключено")) {
                    Toggle("", isOn: Binding(get: { settings.enabled }, set: setEnabled)).labelsHidden().toggleStyle(.switch)
                }
                if settings.enabled {
                    divider
                    row(L("Провайдер"), settings.provider.isLocal ? L("Без интернета: сервер должен быть запущен на этом Mac") : L("У каждого провайдера свой ключ и своя модель")) {
                        Picker("", selection: Binding(get: { settings.providerID }, set: { id in changeProvider(to: id) })) {
                            ForEach(AIProvider.builtIn) { Text(L($0.name)).tag($0.id) }
                            Text(L("Свой (OpenAI-совместимый)")).tag("custom")
                        }
                        .labelsHidden().frame(width: 260)
                    }
                    if settings.providerID == "custom" || settings.provider.isLocal {
                        divider
                        row(L("Адрес API"), AIProvider.isAllowedBaseURL(settings.provider.baseURL) ? settings.provider.baseURL : L("Нужен адрес https:// или http://localhost")) {
                            TextField(settings.provider.baseURL.isEmpty ? "https://example.com/v1" : settings.provider.baseURL, text: $urlDraft)
                                .textFieldStyle(.roundedBorder).frame(width: 260)
                                .onSubmit(saveURL)
                            Button(L("Сохранить")) { saveURL() }.buttonStyle(NotesButtonStyle())
                                .disabled(!AIProvider.isAllowedBaseURL(AIProvider.normalizedBaseURL(urlDraft)))
                        }
                    }
                    divider
                    row(L("Ключ API"), settings.storedKey ? L("Сохранён в связке ключей macOS")
                        : (settings.provider.needsKey ? String(format: L("Ключ можно получить здесь: %@"), settings.provider.keyHint) : L("Не нужен для сервера на этом Mac"))) {
                        if settings.storedKey || !settings.provider.needsKey {
                            Button(L("Проверить")) { check() }.buttonStyle(NotesButtonStyle()).disabled(checking)
                        }
                        if settings.storedKey {
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
                    row(L("Модель"), settings.availableModels.isEmpty ? L("Нажмите «Проверить», чтобы загрузить список моделей провайдера") : L("Можно ввести название модели вручную")) {
                        Picker("", selection: $settings.model) {
                            ForEach(models, id: \.self) { Text($0 == settings.provider.defaultModel ? L("Авто") + " (\($0))" : $0).tag($0) }
                        }
                        .labelsHidden().frame(width: 220)
                        TextField(L("Поиск модели…"), text: $modelDraft).textFieldStyle(.roundedBorder).frame(width: 180)
                            .onSubmit {
                                // Enter: первая найденная модель, иначе введённое название как есть.
                                let name = modelDraft.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                settings.model = modelMatches.first ?? name
                                modelDraft = ""
                            }
                            .accessibilityLabel(Text("Поиск модели"))
                    }
                    if !modelDraft.trimmingCharacters(in: .whitespaces).isEmpty { modelSearchResults }
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
        let provider = settings.provider
        var list = settings.availableModels.isEmpty ? provider.suggestedModels : settings.availableModels
        if !provider.defaultModel.isEmpty, !list.contains(provider.defaultModel) { list.insert(provider.defaultModel, at: 0) }
        if !settings.model.isEmpty, !list.contains(settings.model) { list.append(settings.model) }
        return list
    }

    private var usageText: String {
        let today = settings.today, month = settings.thisMonth
        let t = today.input + today.output + today.cacheRead + today.cacheWrite
        let m = month.input + month.output + month.cacheRead + month.cacheWrite
        // Цены известны только для Claude; у остальных — по тарифу провайдера.
        guard settings.provider.api == .anthropic else { return String(format: L("Сегодня: %d токенов, месяц: %d токенов; цена — по тарифу провайдера"), t, m) }
        return String(format: L("Сегодня: %d токенов, месяц: %d токенов, около $%.2f"), t, m, AIPricing.dollars(month, model: settings.model))
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
            alert.informativeText = String(format: L("Когда вы обращаетесь к ИИ, выделенный текст, открытая страница или найденные фрагменты отправляются выбранному провайдеру (сейчас — %@) по вашему ключу. Без вашего действия ничего не отправляется. Ключи хранятся в связке ключей macOS. Провайдера можно сменить, а ИИ — выключить здесь же в любой момент."), settings.provider.name)
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
                let list = try await AIClient.models(provider: settings.provider)
                // У Anthropic — только модели Claude; у остальных — весь список провайдера.
                settings.availableModels = (settings.provider.api == .anthropic ? list.filter { $0.hasPrefix("claude-") } : list).sorted()
                checkFailed = false
                checkResult = String(format: L("Подключение работает. Моделей: %d."), settings.availableModels.count)
            } catch {
                checkFailed = true
                checkResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Модели провайдера по части названия: регистр, «-», «_», «/», «.» и пробелы не важны.
    private var modelMatches: [String] {
        func key(_ text: String) -> String {
            SearchText.normalize(text).filter { !"-_/. :".contains($0) }
        }
        let query = key(modelDraft)
        guard !query.isEmpty else { return [] }
        // Сначала начинающиеся с запроса, затем содержащие его.
        let all = models.filter { key($0).contains(query) }
        return all.filter { key($0).hasPrefix(query) || key($0.split(separator: "/").last.map(String.init) ?? $0).hasPrefix(query) }
            + all.filter { !(key($0).hasPrefix(query) || key($0.split(separator: "/").last.map(String.init) ?? $0).hasPrefix(query)) }
    }

    private var modelSearchResults: some View {
        let matches = modelMatches
        let name = modelDraft.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text(settings.availableModels.isEmpty
                     ? L("Ничего не найдено. Нажмите «Проверить», чтобы загрузить все модели провайдера, или Enter — взять это название как есть.")
                     : L("Ничего не найдено. Enter — взять это название как есть."))
                    .font(.system(size: 12)).foregroundColor(Tokens.muted)
                    .padding(.vertical, 6)
            } else {
                Text(String(format: L("Найдено моделей: %d"), matches.count)).font(.system(size: 11)).foregroundColor(Tokens.muted).padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { model in
                            MenuRow(symbol: model == settings.model ? "checkmark" : "cpu", title: model) {
                                settings.model = model
                                modelDraft = ""
                            }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(matches.count) * 28, 224))
            }
            if !name.isEmpty, !matches.contains(name) {
                MenuRow(symbol: "plus", title: String(format: L("Использовать «%@»"), name)) {
                    settings.model = name
                    modelDraft = ""
                }
            }
        }
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeProvider(to id: String) {
        AIChatModel.shared.stop()
        AIAssist.shared.close()
        settings.providerID = id
        urlDraft = ""
        checkResult = nil
    }

    private func saveURL() {
        let url = AIProvider.normalizedBaseURL(urlDraft)
        guard AIProvider.isAllowedBaseURL(url) else { return }
        if settings.providerID == "custom" {
            settings.customBaseURL = url
        } else {
            checkFailed = true
            checkResult = L("Адрес встроенного провайдера не меняется; для своего адреса выберите «Свой (OpenAI-совместимый)».")
        }
        urlDraft = ""
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
