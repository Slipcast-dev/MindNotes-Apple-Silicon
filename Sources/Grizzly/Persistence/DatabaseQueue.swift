import Foundation

/// Соединение и его последовательная очередь. Соединение не покидает очередь.
/// Очередь, а не actor: `fsync` блокировал бы кооперативный пул потоков.
final class DatabaseQueue {
    private let queue: DispatchQueue
    private let connection: SQLiteConnection

    init(label: String, connection: SQLiteConnection) {
        queue = DispatchQueue(label: "notes.db.\(label)", qos: .userInitiated)
        self.connection = connection
    }

    func sync<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try queue.sync { try body(connection) }
    }

    func run<T>(_ body: @escaping (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [connection] in
                continuation.resume(with: Result { try body(connection) })
            }
        }
    }

    func close() {
        queue.sync { connection.close() }
    }
}
