import Foundation
import Network

/// Слушатель локального API плагинов (ADR-0019): только 127.0.0.1, одно соединение — один запрос.
/// Разбор и ответы — `LocalAPI` (Domain); решения принимает `PluginHost` на главном потоке.
final class LocalAPIServer: @unchecked Sendable {
    typealias Handler = @MainActor (LocalAPI.Request) async -> LocalAPI.Response

    private let queue = DispatchQueue(label: "MindNotes.LocalAPI")
    private var listener: NWListener?
    private let handler: Handler
    private let onState: @MainActor (String?) -> Void

    /// `onState` получает nil, когда слушатель работает, или текст ошибки (порт занят и т. п.).
    init(handler: @escaping Handler, onState: @escaping @MainActor (String?) -> Void) {
        self.handler = handler
        self.onState = onState
    }

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(LocalAPI.host), port: NWEndpoint.Port(rawValue: LocalAPI.port)!)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: Task { @MainActor in self.onState(nil) }
                case .failed(let error):
                    Task { @MainActor in self.onState(error.localizedDescription) }
                    self.stop()
                default: break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            Task { @MainActor in self.onState(error.localizedDescription) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Соединение, которое молчит, не держит ресурсы дольше минуты.
        queue.asyncAfter(deadline: .now() + 60) { [weak connection] in connection?.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalAPI.parse(buffer) {
            case .incomplete:
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            case .invalid(let status):
                self.send(.error(status, "bad_request", "Запрос не разобран"), origin: nil, on: connection)
            case .request(let request):
                Task { @MainActor in
                    let response = await self.handler(request)
                    self.send(response, origin: request.origin, on: connection)
                }
            }
        }
    }

    private func send(_ response: LocalAPI.Response, origin: String?, on connection: NWConnection) {
        connection.send(content: response.serialized(origin: origin), completion: .contentProcessed { _ in connection.cancel() })
    }
}
