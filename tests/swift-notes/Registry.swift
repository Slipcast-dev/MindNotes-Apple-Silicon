import Foundation

func runAllNotesTests() async {
    await runStorageTests()
    await runSaveTests()
    await runCrashTests()
    await runEditorTests()
    await runReviewFixTests()
    await runTrashTests()
    await runFolderTests()
    await runRangeTests()
    await runImportTests()
    await runNativeEditorTests()
    await runNativeEditorReviewTests()
    await runNotionEditorTests()
    await runBackupTests()
    await runVerticalScenario()
    await runGapTests()
}
