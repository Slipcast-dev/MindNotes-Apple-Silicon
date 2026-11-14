import Foundation

/// Дочерние режимы, общие для тестов аварий и вертикального сценария.
func handleExtraChild() async -> Bool {
    let args = CommandLine.arguments
    if args.contains("--bench") { try? await benchCommit(); exit(0) }
    if let i = args.firstIndex(of: "--seed-types"), args.count > i + 1 {
        do { try await seedTypes(dir: URL(fileURLWithPath: args[i + 1])); exit(0) }
        catch { print("seed error \(error)"); exit(7) }
    }
    if args.contains("--bench-editor") { try? await benchEditor(); exit(0) }
    if let i = args.firstIndex(of: "--bench-large"), args.count > i + 1 {
        do { try await benchLarge(dir: URL(fileURLWithPath: args[i + 1])); exit(0) }
        catch { print("bench error \(error)"); exit(7) }
    }
    if let i = args.firstIndex(of: "--demo-archive"), args.count > i + 2 {
        do {
            let dir = URL(fileURLWithPath: args[i + 1])
            try await seedDemo(dir: dir)
            let ws = try SQLiteWorkspace.open(at: dir)
            let result = try BackupService.create(workspaceRoot: dir, snapshotter: ws, inspector: SQLiteSnapshotInspector(),
                                                  destination: URL(fileURLWithPath: args[i + 2]), appVersion: "demo", now: SystemClock().nowMillis())
            ws.close()
            FileHandle.standardError.write(Data((result.isComplete ? "demo ok\n" : "demo incomplete\n").utf8))
            _exit(result.isComplete ? 0 : 8)
        } catch { FileHandle.standardError.write(Data("demo error \(error)\n".utf8)); _exit(7) }
    }
    // Демо-пространство и все шаблоны каталога: для ручной проверки досок, итогов и хронологии.
    if let i = args.firstIndex(of: "--seed-catalog"), args.count > i + 1 {
        do {
            let dir = URL(fileURLWithPath: args[i + 1])
            try await seedDemo(dir: dir)
            let ws = try SQLiteWorkspace.open(at: dir)
            for template in TemplateCatalog.all {
                _ = try await ws.install(template, today: LocalDate(date: Date(), in: .current), now: SystemClock().nowMillis())
            }
            ws.close()
            _exit(0)
        } catch { print("seed error \(error)"); _exit(7) }
    }
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

    // База «Задачи» как на макете доски: статусы и сроки. Данные вымышленные.
    let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                               statusOptions: ["Запланировано", "В работе", "Готово"], dateProperty: "Срок", viewName: "Таблица",
                               extraViews: [("Доска", DatabaseView.boardKind), ("Календарь", DatabaseView.calendarKind)])
    let tasks = try await ws.createDatabase(parent: projects.id, template: template, ids: RandomIDs(), now: 1)
    let status = tasks.properties.first { $0.type == .status }!, due = tasks.properties.first { $0.type == .date }!
    let items: [(String, Int, Int)] = [("Проверить сохранение", 0, 9), ("Проверить восстановление", 0, 24), ("Собрать макеты", 1, 6),
                                       ("Подготовить демо", 1, 17), ("Описать формат импорта", 2, 11)]
    for (title, state, day) in items {
        let id = UUID()
        try await ws.createRecord(database: tasks.id, title: title, id: id, now: 2)
        try await ws.setValue(pages: [id], property: status.id, value: .options([status.options[state].id]), now: 2)
        try await ws.setValue(pages: [id], property: due.id, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 11, day: day)!))), now: 2)
    }
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

/// Страница со всеми типами блоков для проверки вида.
@MainActor
func seedTypes(dir: URL) async throws {
    let ws = try SQLiteWorkspace.create(at: dir, name: "Моё пространство")
    let session = WorkspaceSession(store: ws, name: "Моё пространство")
    let page = try await session.createPage(parent: nil, title: "Все блоки")
    let e = try await session.open(page.id)
    let md = """
    Обычный абзац с **жирным**, *курсивом*, ~~зачёркнутым~~ и `кодом`.
    # Заголовок 1
    ## Заголовок 2
    ### Заголовок 3
    - Маркированный пункт
    - Ещё пункт
    1. Первый
    2. Второй
    - [ ] Задача
    - [x] Сделанная задача
    > Цитата: перед переносом заметок сделайте пробное восстановление.
    ---
    ```
    let значение = 42
    print(значение)
    ```
    """
    try e.perform(.replaceRange(BlockSelection(block: e.document.blocks[0].id, offset: 0), MarkdownImport.fragments(from: md)))
    let last = e.document.blocks.last!.id
    let c = try e.perform(.insertBlock(after: last, type: .callout))
    try e.perform(.setPlainText(block: c.selection!.anchor.blockID, text: "Выноска с важной мыслью."))
    let t = try e.perform(.insertBlock(after: c.selection!.anchor.blockID, type: .toggle))
    try e.perform(.setPlainText(block: t.selection!.anchor.blockID, text: "Сворачиваемый блок"))
    let inner = try e.perform(.insertBlock(after: t.selection!.anchor.blockID, type: .paragraph))
    try e.perform(.setPlainText(block: inner.selection!.anchor.blockID, text: "Вложенный текст"))
    try e.perform(.indent(inner.selection!.anchor.blockID))
    let b = e.document.blocks[4].id
    try e.perform(.indent(e.document.blocks[5].id))
    _ = b
    try await session.close()
}
