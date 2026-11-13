import Foundation

// Самоперезапуск для тестов аварий: дочерний процесс выполняет сценарий и обрывается через _exit.
if await handleChildMode() { exit(0) }

await runDomainTests()
await runAllNotesTests()
await runCalendarSyncTests()
await runCalendarSafetyTests()
do { try await runAdapterTests() } catch { TestRun.failed.append("calendar adapter: \(error)") }
await runAICalendarTests()

print("passed=\(TestRun.passed) failed=\(TestRun.failed.count)")
if !TestRun.failed.isEmpty {
    for f in TestRun.failed { print("FAIL: \(f)") }
    exit(1)
}
