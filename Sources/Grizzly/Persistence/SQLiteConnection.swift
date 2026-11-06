import Foundation
import SQLite3

/// Макрос SQLITE_TRANSIENT не импортируется в Swift.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ i: Int64?) { self = i.map { .int($0) } ?? .null }
    init(_ u: UUID?) { self = u.map { .text($0.lowercasedString) } ?? .null }
}

extension UUID {
    /// Единая форма на диске: нижний регистр.
    var lowercasedString: String { uuidString.lowercased() }
}

/// Строка результата. Живёт только внутри замыкания `query`.
struct SQLRow {
    fileprivate let stmt: OpaquePointer

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    func text(_ i: Int32) -> String { optText(i) ?? "" }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func optText(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: c, count: Int(sqlite3_column_bytes(stmt, i))), as: UTF8.self)
    }
    func uuid(_ i: Int32) -> UUID? { optText(i).flatMap(UUID.init(uuidString:)) }
    func blob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// Соединение SQLite. Не потокобезопасно (THREADSAFE=2): используется только с очереди-владельца.
final class SQLiteConnection {
    private(set) var handle: OpaquePointer?
    let path: String

    init(path: String, readOnly: Bool = false, create: Bool = false) throws {
        self.path = path
        var flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if create { flags |= SQLITE_OPEN_CREATE }
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let error = Self.mapError(code: rc, detail: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open")
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    static func mapError(code: Int32, detail: String) -> WorkspaceError {
        switch code & 0xFF {
        case SQLITE_FULL: return .diskFull
        case SQLITE_CORRUPT, SQLITE_NOTADB: return .corrupted(detail)
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_CANTOPEN, SQLITE_AUTH: return .noPermission(detail)
        default: return .storage(code: code, detail: detail)
        }
    }

    private func lastError(_ code: Int32) -> WorkspaceError {
        Self.mapError(code: code, detail: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "закрыто")
    }

    /// Запрос без параметров; допускается несколько инструкций.
    func execute(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw lastError(rc) }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw lastError(rc) }
        for (i, value) in args.enumerated() {
            let at = Int32(i + 1)
            let bound: Int32
            switch value {
            case .null: bound = sqlite3_bind_null(stmt, at)
            case .int(let v): bound = sqlite3_bind_int64(stmt, at, v)
            case .real(let v): bound = sqlite3_bind_double(stmt, at, v)
            case .text(let v): bound = sqlite3_bind_text(stmt, at, v, -1, sqliteTransient)
            case .blob(let v):
                bound = v.withUnsafeBytes { sqlite3_bind_blob(stmt, at, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(v.count), sqliteTransient) }
            }
            guard bound == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw lastError(bound)
            }
        }
        return stmt
    }

    /// Выполняет инструкцию с параметрами; значения никогда не вставляются в текст SQL.
    func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw lastError(rc) }
    }

    func query<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(SQLRow(stmt: stmt))) }
            else if rc == SQLITE_DONE { return out }
            else { throw lastError(rc) }
        }
    }

    func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int64? {
        try query(sql, args) { $0.optInt(0) }.first ?? nil
    }

    func scalarText(_ sql: String, _ args: [SQLValue] = []) throws -> String? {
        try query(sql, args) { $0.optText(0) }.first ?? nil
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    enum TransactionKind: String { case immediate = "IMMEDIATE", exclusive = "EXCLUSIVE" }

    /// Транзакция: при ошибке откат, ошибка отката не скрывает исходную.
    func transaction<T>(_ kind: TransactionKind = .immediate, _ body: () throws -> T) throws -> T {
        try execute("BEGIN \(kind.rawValue)")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// Копия работающей базы средствами SQLite Backup API; копия получает журнал DELETE и становится одним файлом.
enum SQLiteSnapshot {
    static func copy(from source: SQLiteConnection, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let dest = try SQLiteConnection(path: url.path, create: true)
        guard let backup = sqlite3_backup_init(dest.handle, "main", source.handle, "main") else {
            throw SQLiteConnection.mapError(code: sqlite3_errcode(dest.handle), detail: String(cString: sqlite3_errmsg(dest.handle)))
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, 256)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(50) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        let finish = sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE, finish == SQLITE_OK else {
            throw SQLiteConnection.mapError(code: rc == SQLITE_DONE ? finish : rc, detail: "backup")
        }
        _ = try dest.query("PRAGMA journal_mode=DELETE") { $0.text(0) }
        dest.close()
    }
}
