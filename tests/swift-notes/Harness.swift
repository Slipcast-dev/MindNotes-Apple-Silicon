import Foundation

/// Простейший раннер: XCTest недоступен без Xcode.
enum TestRun {
    static var passed = 0
    static var failed: [String] = []
    static var current = ""
    static var filter: String? {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        return args.first
    }
}

func check(_ ok: @autoclosure () -> Bool, _ what: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if ok() { TestRun.passed += 1 } else {
        let message = "\(TestRun.current): \(what) (\(file):\(line))"
        TestRun.failed.append(message)
        print("FAIL: \(message)")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String = "", file: StaticString = #fileID, line: UInt = #line) {
    check(a == b, "\(what) [\(a)] != [\(b)]", file: file, line: line)
}

/// Проверяет, что выражение бросает ошибку; возвращает её для уточнения.
@discardableResult
func checkThrows<T>(_ what: String = "", file: StaticString = #fileID, line: UInt = #line, _ body: () async throws -> T) async -> Error? {
    do { _ = try await body(); check(false, "ожидалась ошибка: \(what)", file: file, line: line); return nil }
    catch { TestRun.passed += 1; return error }
}

func test(_ name: String, _ body: () async throws -> Void) async {
    if let f = TestRun.filter, !name.contains(f) { return }
    TestRun.current = name
    do { try await body(); print("ok: \(name)") }
    catch {
        TestRun.failed.append("\(name): \(error)")
        print("FAIL: \(name): \(error)")
    }
}

/// Отдельный временный каталог на тест; реальные пользовательские данные тесты не используют.
func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gn-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    return try await body(dir)
}
