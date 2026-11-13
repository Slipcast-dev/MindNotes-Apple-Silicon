import Foundation

/// Тест на главном акторе: движок и шлюз календаря живут на нём. Работает с раннером MindNotes (`TestRun`, `check`).
@MainActor
func atest(_ name: String, _ body: @MainActor () async throws -> Void) async {
    if let f = TestRun.filter, !name.contains(f) { return }
    TestRun.current = name
    do { try await body(); print("ok: \(name)") }
    catch {
        TestRun.failed.append("\(name): \(error)")
        print("FAIL: \(name): \(error)")
    }
}

/// Все тесты синхронизации с Календарём.
@MainActor
func runCalendarSyncTests() async {
    await runPlannerTests()
    await runLayoutTests()
    await runEngineTests()
    await runFixTests()
    await runCalendarMathTests()
}
