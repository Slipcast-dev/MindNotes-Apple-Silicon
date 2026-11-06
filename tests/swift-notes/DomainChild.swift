import Foundation

/// Дочерние режимы, общие для тестов аварий и вертикального сценария.
func handleExtraChild() async -> Bool {
    let args = CommandLine.arguments
    if args.contains("--bench") { try? await benchCommit(); exit(0) }
    if let i = args.firstIndex(of: "--seed-demo"), args.count > i + 1 {
        do { try await seedDemo(dir: URL(fileURLWithPath: args[i + 1])); _exit(0) }
        catch { print("seed error \(error)"); _exit(7) }
    }
    if let i = args.firstIndex(of: "--vertical-child"), args.count > i + 1 {
        do { try await verticalChild(dir: URL(fileURLWithPath: args[i + 1])) }
        catch { print("child error \(error)"); _exit(6) }
    }
    return false
}

/// Наполняет новое пространство вымышленными данными: для ручной проверки и контрольного пространства.
@MainActor
func seedDemo(dir: URL) async throws {
    let ws = try SQLiteWorkspace.create(at: dir, name: "Моё пространство")
    let session = WorkspaceSession(store: ws, name: "Моё пространство")
    let projects = try await session.createPage(parent: nil, title: "Проекты")
    let plan = try await session.createPage(parent: projects.id, title: "План запуска")
    let journal = try await session.createPage(parent: nil, title: "Дневник")
    _ = try await session.createPage(parent: nil, title: "База знаний")
    let e = try await session.open(plan.id)
    let first = e.document.blocks[0].id
    try e.perform(.setPlainText(block: first, text: "Собрать первую версию и проверить, что заметки можно перенести и восстановить."))
    func add(_ type: BlockType, _ text: String, checked: Bool = false) throws {
        let last = e.document.blocks.last?.id
        let r = try e.perform(.insertBlock(after: last, type: type))
        let id = r.selection!.anchor.blockID
        try e.perform(.setPlainText(block: id, text: text))
        if checked { try e.perform(.setChecked(block: id, checked: true)) }
    }
    try add(.heading3, "На этой неделе")
    try add(.task, "Подготовить техническое задание", checked: true)
    try add(.task, "Проверить сохранение после перезапуска")
    try add(.task, "Пройти импорт тестового архива")
    let j = try await session.open(journal.id)
    try j.perform(.setPlainText(block: j.document.blocks[0].id, text: "Что получилось сегодня?"))
    try await session.close()
}

/// Замер реальной записи на диск: пакет из 5 блоков, synchronous=FULL + fullfsync.
func benchCommit() async throws {
    try await withTempDir { dir in
        let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "bench")
        let page = UUID()
        _ = try await ws.createPage(parent: nil, title: "Замер", id: page, now: 1)
        var times: [Double] = []
        for i in 0..<200 {
            var b = SaveBatch()
            for j in 0..<5 {
                let id = UUID()
                b.upserts[id] = Block(id: id, pageID: page, sortKey: "a\(i)x\(j)", content: BlockContent(text: String(repeating: "текст ", count: 40)), createdAt: 1)
            }
            b.touchedPages = [page]
            let t = DispatchTime.now().uptimeNanoseconds
            try await ws.commit(b)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        times.sort()
        print(String(format: "commit ms: p50=%.1f p95=%.1f max=%.1f", times[100], times[190], times[199]))
        ws.close()
    }
}
