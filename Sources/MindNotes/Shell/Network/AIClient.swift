import Foundation

/// Сеть ИИ-ассистента (ADR-0016): единственный адрес — Anthropic Messages API, только при включённом ИИ,
/// данном согласии и ключе в Keychain. Проверка AT-15 в `tests/edition.test.cjs` следит за этими условиями.
enum AIClient {
    static let host = "https://api.anthropic.com"
    static let apiVersion = "2026-10-21"
    /// Сервер сам повторяет запрос на другой модели, если первая отказалась (`fallbacks: "default"`).
    static let betas = "server-side-fallback-2026-07-01"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        // Между байтами ответа модель может думать: ожидание дольше обычного.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3_600
        return URLSession(configuration: config)
    }()

    private static func request(path: String, method: String, body: Data?, beta: Bool = true) throws -> URLRequest {
        guard AISettings.isEnabled else { throw AIFailure.disabled }
        guard let key = AIKeychain.read(), !key.isEmpty else { throw AIFailure.noKey }
        guard let url = URL(string: host + path) else { throw AIFailure.invalidRequest(path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if beta { request.setValue(betas, forHTTPHeaderField: "anthropic-beta") }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        return request
    }

    /// Потоковый запрос `POST /v1/messages`. События передаются по мере прихода; итог — ответ целиком.
    /// Временные сбои до начала ответа повторяются не больше двух раз; 400, 401, 404 — сразу ошибка.
    static func stream(_ body: JSONValue, onEvent: @escaping @MainActor (AIStreamEvent, AIAssistantTurn) -> Void) async throws -> AIAssistantTurn {
        var attempt = 0
        while true {
            do {
                return try await streamOnce(body, onEvent: onEvent)
            } catch let failure as AIFailure where failure.isRetryable && attempt < 2 {
                attempt += 1
                let wait: Int
                if case .rateLimited(let seconds?) = failure { wait = min(seconds, 30) } else { wait = attempt * 2 }
                try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            }
        }
    }

    private static func streamOnce(_ body: JSONValue, onEvent: @escaping @MainActor (AIStreamEvent, AIAssistantTurn) -> Void) async throws -> AIAssistantTurn {
        let request = try request(path: "/v1/messages", method: "POST", body: body.encoded())
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw mapped(error)
        }
        guard let http = response as? HTTPURLResponse else { throw AIFailure.stream("нет ответа") }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 65_536 { break }
            }
            throw AIFailure.from(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "retry-after"))
        }
        var accumulator = AIResponseAccumulator()
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let event = AIStreamParser.parse(line: line) else { continue }
                accumulator.apply(event)
                // Ошибка посреди ответа не повторяется: часть ответа уже показана.
                if let error = accumulator.streamError { throw AIFailure.stream(error.message) }
                let snapshot = accumulator.turn
                await onEvent(event, snapshot)
                if snapshot.finished { break }
            }
        } catch let failure as AIFailure {
            throw failure
        } catch {
            throw mapped(error)
        }
        let turn = accumulator.turn
        guard turn.finished || turn.stopReason != nil else { throw AIFailure.stream("ответ оборвался") }
        return turn
    }

    /// Проверка ключа: список моделей (`GET /v1/models`). Без расхода токенов.
    static func models() async throws -> [String] {
        let request = try request(path: "/v1/models?limit=100", method: "GET", body: nil)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapped(error)
        }
        guard let http = response as? HTTPURLResponse else { throw AIFailure.stream("нет ответа") }
        guard http.statusCode == 200 else { throw AIFailure.from(status: http.statusCode, body: data, retryAfter: nil) }
        let list = JSONValue.parse(String(decoding: data, as: UTF8.self))?["data"]?.arrayValue ?? []
        return list.compactMap { $0["id"]?.stringValue }
    }

    // MARK: Message Batches (ИИ-свойства на много записей: дешевле вдвое, результат до 24 ч)

    /// Пакет запросов: `custom_id` → тело запроса без `stream`. Возвращает ID пакета.
    static func createBatch(_ requests: [(id: String, params: JSONValue)]) async throws -> String {
        let body = JSONValue.object(["requests": .array(requests.map { .object(["custom_id": .string($0.id), "params": $0.params]) })])
        let json = try await send(path: "/v1/messages/batches", method: "POST", body: body.encoded())
        guard let id = json["id"]?.stringValue else { throw AIFailure.stream("нет ID пакета") }
        return id
    }

    struct BatchStatus: Equatable {
        var ended: Bool
        var resultsPath: String?
    }

    static func batchStatus(_ id: String) async throws -> BatchStatus {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw AIFailure.invalidRequest(id) }
        let json = try await send(path: "/v1/messages/batches/" + id, method: "GET", body: nil)
        // Результаты отдаются только с того же адреса API.
        let path = json["results_url"]?.stringValue.flatMap { $0.hasPrefix(host + "/") ? String($0.dropFirst(host.count)) : nil }
        return BatchStatus(ended: json["processing_status"]?.stringValue == "ended", resultsPath: path)
    }

    /// Результаты пакета (JSONL): `custom_id` и итог; у неудачных — nil.
    static func batchResults(_ path: String) async throws -> [(id: String, turn: AIAssistantTurn?)] {
        let request = try request(path: path, method: "GET", body: nil, beta: false)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw mapped(error) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIFailure.from(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, retryAfter: nil)
        }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            guard let json = JSONValue.parse(String(line)), let id = json["custom_id"]?.stringValue else { return nil }
            guard json["result"]?["type"]?.stringValue == "succeeded", let message = json["result"]?["message"] else { return (id, nil) }
            return (id, AIAssistantTurn(message: message))
        }
    }

    private static func send(path: String, method: String, body: Data?) async throws -> JSONValue {
        let request = try request(path: path, method: method, body: body, beta: false)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw mapped(error) }
        guard let http = response as? HTTPURLResponse else { throw AIFailure.stream("нет ответа") }
        guard (200..<300).contains(http.statusCode) else { throw AIFailure.from(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "retry-after")) }
        return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .object([:])
    }

    private static func mapped(_ error: Error) -> AIFailure {
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed, .dataNotAllowed:
                return .offline
            default: return .stream(url.localizedDescription)
            }
        }
        return .stream("\(error)")
    }
}
