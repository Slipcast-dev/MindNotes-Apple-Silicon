import Foundation

// Провайдеры ИИ (ADR-0018). Приложение ведёт историю и инструменты в формате Anthropic Messages;
// для провайдеров с OpenAI-совместимым API запрос переводится в Chat Completions, а поток ответа — обратно.
// Здесь нет сети: запросы отправляет только `Shell/Network/AIClient.swift`.

struct AIProvider: Identifiable, Equatable {
    enum API: Equatable { case anthropic, openAI }

    let id: String
    let name: String
    let api: API
    /// Адрес API без завершающей косой черты. У «Своего» задаёт пользователь.
    let baseURL: String
    let defaultModel: String
    /// Модели на выбор, пока список с сервера не загружен.
    let suggestedModels: [String]
    let needsKey: Bool
    /// Где взять ключ (показывается в настройках).
    let keyHint: String
    /// Предел длины ответа у провайдера.
    let maxOutput: Int
    /// Строгие схемы инструментов (`strict: true`).
    var strictTools = false
    /// Схема ответа `json_schema`; иначе — `json_object` с описанием в промпте.
    var jsonSchema = true
    /// `additionalProperties` в схемах: Gemini его не принимает.
    var additionalProperties = true
    /// Изображения и PDF во вложениях.
    var images = true
    var pdf = false
    /// Счётчики токенов в потоке (`stream_options.include_usage`).
    var streamUsage = true
    /// `max_completion_tokens` вместо устаревшего `max_tokens`.
    var completionTokensField = false

    static let anthropic = AIProvider(id: "anthropic", name: "Anthropic (Claude)", api: .anthropic, baseURL: "https://api.anthropic.com",
                                      defaultModel: AIDefaults.model, suggestedModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"],
                                      needsKey: true, keyHint: "platform.claude.com", maxOutput: AIDefaults.maxTokens, strictTools: true, pdf: true)
    static let openAI = AIProvider(id: "openai", name: "OpenAI", api: .openAI, baseURL: "https://api.openai.com/v1",
                                   defaultModel: "gpt-5", suggestedModels: ["gpt-5", "gpt-5-mini", "gpt-4.1"],
                                   needsKey: true, keyHint: "platform.openai.com", maxOutput: 32_000, strictTools: true, pdf: true, completionTokensField: true)
    static let openRouter = AIProvider(id: "openrouter", name: "OpenRouter", api: .openAI, baseURL: "https://openrouter.ai/api/v1",
                                       defaultModel: "openrouter/auto", suggestedModels: ["openrouter/auto"],
                                       needsKey: true, keyHint: "openrouter.ai/keys", maxOutput: 16_000, pdf: true)
    static let deepSeek = AIProvider(id: "deepseek", name: "DeepSeek", api: .openAI, baseURL: "https://api.deepseek.com/v1",
                                     defaultModel: "deepseek-chat", suggestedModels: ["deepseek-chat", "deepseek-reasoner"],
                                     needsKey: true, keyHint: "platform.deepseek.com", maxOutput: 8_000, jsonSchema: false, images: false)
    static let gemini = AIProvider(id: "gemini", name: "Google Gemini", api: .openAI, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                                   defaultModel: "gemini-2.5-pro", suggestedModels: ["gemini-2.5-pro", "gemini-2.5-flash"],
                                   needsKey: true, keyHint: "aistudio.google.com", maxOutput: 16_000, additionalProperties: false)
    static let mistral = AIProvider(id: "mistral", name: "Mistral", api: .openAI, baseURL: "https://api.mistral.ai/v1",
                                    defaultModel: "mistral-large-latest", suggestedModels: ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest"],
                                    needsKey: true, keyHint: "console.mistral.ai", maxOutput: 16_000)
    static let xAI = AIProvider(id: "xai", name: "xAI (Grok)", api: .openAI, baseURL: "https://api.x.ai/v1",
                                defaultModel: "grok-4", suggestedModels: ["grok-4"],
                                needsKey: true, keyHint: "console.x.ai", maxOutput: 16_000)
    static let groq = AIProvider(id: "groq", name: "Groq", api: .openAI, baseURL: "https://api.groq.com/openai/v1",
                                 defaultModel: "llama-3.3-70b-versatile", suggestedModels: ["llama-3.3-70b-versatile"],
                                 needsKey: true, keyHint: "console.groq.com", maxOutput: 8_000, jsonSchema: false, images: false)
    static let ollama = AIProvider(id: "ollama", name: "Ollama (на этом Mac)", api: .openAI, baseURL: "http://localhost:11434/v1",
                                   defaultModel: "llama3.2", suggestedModels: ["llama3.2", "qwen2.5", "mistral"],
                                   needsKey: false, keyHint: "ollama.com", maxOutput: 8_000, jsonSchema: false, streamUsage: false)
    static let lmStudio = AIProvider(id: "lmstudio", name: "LM Studio (на этом Mac)", api: .openAI, baseURL: "http://localhost:1234/v1",
                                     defaultModel: "local-model", suggestedModels: [],
                                     needsKey: false, keyHint: "lmstudio.ai", maxOutput: 8_000, streamUsage: false)

    /// Любой сервер с OpenAI-совместимым API: адрес вводит пользователь.
    static func custom(baseURL: String) -> AIProvider {
        AIProvider(id: "custom", name: "Свой (OpenAI-совместимый)", api: .openAI, baseURL: baseURL, defaultModel: "", suggestedModels: [],
                   needsKey: true, keyHint: "", maxOutput: 8_000, jsonSchema: false, streamUsage: false)
    }

    static let builtIn: [AIProvider] = [.anthropic, .openAI, .openRouter, .gemini, .deepSeek, .mistral, .xAI, .groq, .ollama, .lmStudio]

    static func find(_ id: String, customURL: String) -> AIProvider {
        id == "custom" ? custom(baseURL: customURL) : (builtIn.first { $0.id == id } ?? .anthropic)
    }

    /// Пакеты (Message Batches) есть только у Anthropic.
    var batches: Bool { api == .anthropic }
    var isLocal: Bool { Self.isLocalHost(URL(string: baseURL)?.host) }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Адрес API, на который можно отправлять текст пользователя: https, либо http только на этот Mac.
    /// Без логина в адресе, параметров и фрагментов.
    static func isAllowedBaseURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return scheme == "https" || (scheme == "http" && isLocalHost(host))
    }

    static func normalizedBaseURL(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        for suffix in ["/chat/completions", "/models"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return t
    }
}

// MARK: Перевод запроса в OpenAI Chat Completions

enum AIOpenAI {
    /// Тело Chat Completions из тела Anthropic Messages, которое строит приложение.
    static func body(from anthropic: JSONValue, provider: AIProvider) -> JSONValue {
        var out: [String: JSONValue] = [:]
        out["model"] = anthropic["model"] ?? .string(provider.defaultModel)
        var messages: [JSONValue] = []
        let system = (anthropic["system"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
        if !system.isEmpty { messages.append(.object(["role": "system", "content": .string(system)])) }
        for message in anthropic["messages"]?.arrayValue ?? [] { messages += convert(message, provider: provider) }
        out["messages"] = .array(messages)
        let requested = anthropic["max_tokens"]?.intValue ?? provider.maxOutput
        out[provider.completionTokensField ? "max_completion_tokens" : "max_tokens"] = .int(Int64(min(requested, provider.maxOutput)))
        if anthropic["stream"] == .bool(true) {
            out["stream"] = .bool(true)
            if provider.streamUsage { out["stream_options"] = .object(["include_usage": .bool(true)]) }
        }
        if let tools = anthropic["tools"]?.arrayValue, !tools.isEmpty {
            out["tools"] = .array(tools.map { tool in
                var function: [String: JSONValue] = [
                    "name": tool["name"] ?? "",
                    "description": tool["description"] ?? "",
                    "parameters": sanitize(tool["input_schema"] ?? .object([:]), provider: provider),
                ]
                if provider.strictTools, tool["strict"] == .bool(true) { function["strict"] = .bool(true) }
                return .object(["type": "function", "function": .object(function)])
            })
            out["tool_choice"] = "auto"
        }
        if let format = anthropic["output_config"]?["format"], let schema = format["schema"] {
            out["response_format"] = provider.jsonSchema
                ? .object(["type": "json_schema", "json_schema": .object(["name": "value", "strict": .bool(true), "schema": sanitize(schema, provider: provider)])])
                : .object(["type": "json_object"])
        }
        return .object(out)
    }

    /// Убирает то, чего провайдер не принимает в JSON Schema.
    static func sanitize(_ schema: JSONValue, provider: AIProvider) -> JSONValue {
        guard !provider.additionalProperties else { return schema }
        switch schema {
        case .object(var o):
            o["additionalProperties"] = nil
            for (k, v) in o { o[k] = sanitize(v, provider: provider) }
            return .object(o)
        case .array(let list):
            return .array(list.map { sanitize($0, provider: provider) })
        default:
            return schema
        }
    }

    /// Одно сообщение Anthropic → одно или несколько сообщений OpenAI (результаты инструментов — отдельными `tool`).
    static func convert(_ message: JSONValue, provider: AIProvider) -> [JSONValue] {
        let role = message["role"]?.stringValue ?? "user"
        let content = message["content"]?.arrayValue ?? (message["content"]?.stringValue.map { [.object(["type": "text", "text": .string($0)])] } ?? [])
        if role == "system" {
            let text = content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            return text.isEmpty ? [] : [.object(["role": "system", "content": .string(text)])]
        }
        if role == "assistant" {
            // Блоки размышлений у других провайдеров не читаются: остаётся текст и вызовы инструментов.
            let text = content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
            let calls: [JSONValue] = content.compactMap { block in
                guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
                let arguments = String(decoding: (block["input"] ?? .object([:])).encoded(), as: UTF8.self)
                return .object(["id": .string(id), "type": "function", "function": .object(["name": .string(name), "arguments": .string(arguments)])])
            }
            var o: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty && !calls.isEmpty ? .null : .string(text)]
            if !calls.isEmpty { o["tool_calls"] = .array(calls) }
            return [.object(o)]
        }
        var out: [JSONValue] = []
        var parts: [JSONValue] = []
        for block in content {
            switch block["type"]?.stringValue {
            case "tool_result":
                let text: String
                if let s = block["content"]?.stringValue { text = s } else {
                    text = (block["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                }
                let marked = block["is_error"] == .bool(true) ? "Ошибка: " + text : text
                out.append(.object(["role": "tool", "tool_call_id": block["tool_use_id"] ?? "", "content": .string(marked)]))
            case "text":
                parts.append(.object(["type": "text", "text": block["text"] ?? ""]))
            case "image":
                let media = block["source"]?["media_type"]?.stringValue ?? "image/png"
                if provider.images, let data = block["source"]?["data"]?.stringValue {
                    parts.append(.object(["type": "image_url", "image_url": .object(["url": .string("data:\(media);base64,\(data)")])]))
                } else {
                    parts.append(.object(["type": "text", "text": "[Изображение приложено, но эта модель не принимает изображения.]"]))
                }
            case "document":
                let title = block["title"]?.stringValue ?? "документ"
                if block["source"]?["type"]?.stringValue == "text", let text = block["source"]?["data"]?.stringValue {
                    parts.append(.object(["type": "text", "text": .string("Файл «\(title)»:\n" + text)]))
                } else if provider.pdf, let data = block["source"]?["data"]?.stringValue {
                    parts.append(.object(["type": "file", "file": .object(["filename": .string(title), "file_data": .string("data:application/pdf;base64,\(data)")])]))
                } else {
                    parts.append(.object(["type": "text", "text": .string("[PDF «\(title)» приложен, но этот провайдер не принимает PDF.]")]))
                }
            default:
                break
            }
        }
        if !parts.isEmpty {
            // Только текст — строкой: так понимают все совместимые серверы.
            let onlyText = parts.allSatisfy { $0["type"]?.stringValue == "text" }
            let value: JSONValue = onlyText ? .string(parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")) : .array(parts)
            out.append(.object(["role": "user", "content": value]))
        }
        return out
    }
}

// MARK: Поток ответа OpenAI → ответ в формате приложения

/// Собирает поток Chat Completions в `AIAssistantTurn`: текст, вызовы инструментов, причина остановки, токены.
struct AIOpenAIAccumulator {
    private(set) var turn = AIAssistantTurn()
    private var text = ""
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private(set) var streamError: String?

    /// Строка потока; true — поток закончен (`[DONE]`).
    @discardableResult
    mutating func apply(line raw: String) -> Bool {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            finish()
            return true
        }
        guard let json = JSONValue.parse(payload) else { return false }
        apply(chunk: json)
        return false
    }

    mutating func apply(chunk json: JSONValue) {
        if let message = json["error"]?["message"]?.stringValue { streamError = message }
        if let usage = json["usage"], usage != .null {
            turn.usage.input = AIUsage.tokens(usage["prompt_tokens"]) ?? turn.usage.input
            turn.usage.output = AIUsage.tokens(usage["completion_tokens"]) ?? turn.usage.output
            turn.usage.cacheRead = AIUsage.tokens(usage["prompt_tokens_details"]?["cached_tokens"]) ?? turn.usage.cacheRead
        }
        guard let choice = json["choices"]?.arrayValue?.first else { return }
        let delta = choice["delta"] ?? choice["message"]
        if let piece = delta?["content"]?.stringValue { text += piece }
        for call in delta?["tool_calls"]?.arrayValue ?? [] {
            // Недопустимый номер вызова (дробный, огромный, отрицательный) — вызов пропускается.
            let index: Int
            if let raw = call["index"] {
                guard let valid = raw.int(in: 0...AIStreamParser.maxIndex) else { continue }
                index = valid
            } else { index = calls.count }
            var current = calls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"]?.stringValue, !id.isEmpty { current.id = id }
            if let name = call["function"]?["name"]?.stringValue { current.name += name }
            if let args = call["function"]?["arguments"]?.stringValue { current.arguments += args }
            calls[index] = current
        }
        if let reason = choice["finish_reason"]?.stringValue {
            switch reason {
            case "stop": turn.stopReason = "end_turn"
            case "tool_calls", "function_call": turn.stopReason = "tool_use"
            case "length": turn.stopReason = "max_tokens"
            case "content_filter": turn.stopReason = "refusal"
            default: turn.stopReason = "end_turn"
            }
        }
        rebuild()
    }

    /// Ответ без потока (`message` вместо `delta`) разбирается тем же путём.
    mutating func apply(response json: JSONValue) {
        apply(chunk: json)
        finish()
    }

    private mutating func finish() {
        if turn.stopReason == nil { turn.stopReason = calls.isEmpty ? "end_turn" : "tool_use" }
        // Некоторые серверы пишут «stop» даже при вызове инструментов.
        if !calls.isEmpty, turn.stopReason == "end_turn" { turn.stopReason = "tool_use" }
        rebuild()
        turn.finished = true
    }

    private mutating func rebuild() {
        var content: [JSONValue] = []
        if !text.isEmpty { content.append(.object(["type": "text", "text": .string(text)])) }
        turn.invalidToolInputs = []
        for index in calls.keys.sorted() {
            guard let call = calls[index] else { continue }
            let id = call.id.isEmpty ? "call_\(index)" : call.id
            var input: JSONValue = .object([:])
            let raw = call.arguments.trimmingCharacters(in: .whitespaces)
            if !raw.isEmpty {
                if let parsed = JSONValue.parse(raw), parsed.objectValue != nil { input = parsed } else { turn.invalidToolInputs.insert(id) }
            }
            content.append(.object(["type": "tool_use", "id": .string(id), "name": .string(call.name), "input": input]))
        }
        turn.content = content
    }
}
