import Foundation

func runAllNotesTests() async {
    await runStorageTests()
    await runSaveTests()
    await runCrashTests()
    await runEditorTests()
    await runReviewFixTests()
    await runTrashTests()
    await runBackupTests()
    await runVerticalScenario()
    await runGapTests()
}
