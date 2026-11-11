import Foundation

/// Первая часть сценария в отдельном процессе: без штатного закрытия и с реальным автосохранением.
@MainActor
func verticalChild(dir: URL) async throws -> Never {
    let ws = try SQLiteWorkspace.create(at: dir, name: "Моё пространство")
    let session = WorkspaceSession(store: ws, name: "Моё пространство")
    let page = try await session.createPage(parent: nil, title: "Мой проект")
    let sub = try await session.createPage(parent: page.id, title: "Подстраница")
    let editor = try await session.open(sub.id)
    let first = editor.document.blocks[0].id
    try editor.perform(.setPlainText(block: first, text: "Русский текст: ёж 🦔 и 👨‍👩‍👧"))
    let split = try editor.perform(.splitBlock(BlockPoint(blockID: first, offset: "Русский текст: ёж 🦔 и 👨‍👩‍👧".utf16.count)))
    let second = split.selection!.anchor.blockID
    try editor.perform(.changeType(block: second, type: .task))
    try editor.perform(.setPlainText(block: second, text: "Проверить сохранение"))
    try editor.perform(.setChecked(block: second, checked: true))
    // Настоящий таймер автосохранения: ждём статус, а не вызываем flush.
    var waited = 0
    while session.coordinator.status != .saved && waited < 5000 {
        try await Task.sleep(nanoseconds: 20_000_000)
        waited += 20
    }
    guard session.coordinator.status == .saved else { print("нет статуса Сохранено"); _exit(5) }
    print("waited=\(waited)")
    _exit(0) // Принудительное завершение: ни close, ни flush.
}

func runVerticalChild(dir: URL) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    p.arguments = ["--vertical-child", dir.path]
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

@MainActor
func dumpWorkspace(_ store: WorkspaceStore) async throws -> [String] {
    var out: [String] = []
    for page in try await store.allPages().sorted(by: { $0.title < $1.title }) {
        out.append("page \(page.id) parent=\(String(describing: page.parentID)) key=\(page.sortKey) title=\(page.title)")
        for b in try await store.blocks(ofPage: page.id) {
            out.append("block \(b.id) \(b.type.rawValue) \(b.sortKey) \(try b.contentJSON())")
        }
    }
    return out
}

@MainActor
func runVerticalScenario() async {
    await test("Вертикальный сценарий: страницы → сохранение → аварийный перезапуск → копия → восстановление") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("Моё пространство")
            checkEqual(try runVerticalChild(dir: w), 0, "первый процесс дождался «Сохранено»")

            let reopened = try SQLiteWorkspace.open(at: w)
            let session = WorkspaceSession(store: reopened, name: "Моё пространство")
            try await session.refreshPages()
            let pages = session.pages
            checkEqual(Set(pages.map(\.title)), ["Мой проект", "Подстраница"])
            let root = pages.first { $0.title == "Мой проект" }!, sub = pages.first { $0.title == "Подстраница" }!
            checkEqual(sub.parentID, root.id, "вложенность сохранилась")
            let editor = try await session.open(sub.id)
            checkEqual(editor.document.blocks.map(\.plainText), ["Русский текст: ёж 🦔 и 👨‍👩‍👧", "Проверить сохранение"])
            checkEqual(editor.document.blocks[1].type, .task)
            checkEqual(editor.document.blocks[1].content?.checked, true)
            try await session.closeEditor()

            let expected = try await dumpWorkspace(reopened)
            let archive = dir.appendingPathComponent("Копия.mindnotesbackup")
            let result = try BackupService.create(workspaceRoot: w, snapshotter: reopened, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "тест", now: 1)
            check(result.isComplete, "полная копия")
            try await session.close()

            let target = dir.appendingPathComponent("Восстановленное")
            try RestoreService.restore(archive: archive, to: target, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 2)
            let restored = try SQLiteWorkspace.open(at: target)
            checkEqual(try await dumpWorkspace(restored), expected, "страницы и блоки совпали")
            restored.close()

            let original = try SQLiteWorkspace.open(at: w)
            checkEqual(try await dumpWorkspace(original), expected, "исходное пространство не изменено")
            original.close()
        }
    }
}
