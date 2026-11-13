import Foundation

/// Привязка нового клиента к плагину (ADR-0019). Постоянный ключ выдаётся только после явного согласия пользователя:
/// ни Origin расширения, ни идентификатор плагина, ни открытое окно автоподключения аутентификацией не являются —
/// их может назвать любое расширение или локальная программа.
///
/// Окно автоподключения теперь лишь разрешает фоновому запросу (`silent`) показать вопрос, чтобы пользователю
/// не нужно было нажимать «Подключить» в браузере. Число таких вопросов ограничено: не больше одного на источник
/// и `maxPromptsPerWindow` за окно; после отказа окно закрывается, а новые вопросы по плагину на время откладываются.
@MainActor
final class PluginPairing {
    static let maxPromptsPerWindow = 3
    /// Пауза после отказа: поток запросов не превращается в череду окон.
    static let cooldownAfterDenial: TimeInterval = 30

    private var asked: [String: Set<String>] = [:]
    private var deniedAt: [String: Date] = [:]
    private var busy = false

    /// Новое окно автоподключения, открытое самим пользователем: счётчик фоновых вопросов начинается заново.
    func windowOpened(_ plugin: String) {
        asked[plugin] = []
        deniedAt[plugin] = nil
    }

    /// `isActive` — nil, если плагин не установлен. `ask` показывает вопрос пользователю и возвращает его согласие.
    /// `issue` создаёт и сохраняет ключ; вызывается только после согласия.
    func pair(_ request: LocalAPI.Request, now: Date,
              isActive: (String) -> Bool?, isWindowOpen: (String) -> Bool, closeWindow: (String) -> Void,
              ask: (String) async -> Bool, issue: (String) -> LocalAPI.Response) async -> LocalAPI.Response {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], let id = body["plugin"] as? String else {
            return .error(400, "bad_request", NSLocalizedString("Нужно поле plugin.", comment: ""))
        }
        guard let active = isActive(id) else { return .error(404, "no_plugin", NSLocalizedString("Плагин не установлен в MindNotes.", comment: "")) }
        guard active else { return .error(403, "plugin_disabled", NSLocalizedString("Плагин выключен в MindNotes.", comment: "")) }
        let closed = LocalAPI.Response.error(403, "pairing_closed", NSLocalizedString("Подключите расширение кнопкой «Подключить».", comment: ""))
        if let denied = deniedAt[id], now.timeIntervalSince(denied) < Self.cooldownAfterDenial {
            return .error(429, "cooldown", NSLocalizedString("Подключение недавно отклонено. Повторите позже.", comment: ""))
        }
        let silent = body["silent"] as? Bool == true
        let source = request.origin ?? ""
        if silent {
            // Фоновая попытка: вопрос только в открытом окне, один на источник и не больше предела за окно.
            let seen = asked[id] ?? []
            guard isWindowOpen(id), !seen.contains(source), seen.count < Self.maxPromptsPerWindow else { return closed }
        }
        guard !busy else { return .error(429, "busy", NSLocalizedString("MindNotes уже ждёт ответа на другой запрос подключения.", comment: "")) }
        if silent { asked[id, default: []].insert(source) }
        busy = true
        defer { busy = false }
        guard await ask(id) else {
            deniedAt[id] = now
            closeWindow(id)
            return .error(403, "denied", NSLocalizedString("Подключение отклонено в MindNotes.", comment: ""))
        }
        return issue(id)
    }
}
