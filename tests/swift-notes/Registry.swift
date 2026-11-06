import Foundation

func runAllNotesTests() async {
    await runStorageTests()
    await runSaveTests()
    await runCrashTests()
}
