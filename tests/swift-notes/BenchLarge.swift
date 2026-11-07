import Foundation

/// Замер на данных AT-17: 10 000 страниц, 100 000 блоков, отдельная база на 10 000 записей.
/// Пространство создаётся один раз в указанной папке и переиспользуется, чтобы сравнивать сборки на одних данных.
/// Отрисовка в замер не входит.
@MainActor
func benchLarge(dir: URL) async throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir.appendingPathComponent("workspace.sqlite").path) {
        try await seedLarge(dir: dir)
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let ws = try SQLiteWorkspace.open(at: dir)
    print(String(format: "open workspace ms: %.1f", ms(since: t0)))

    func p95(_ name: String, runs: Int, _ body: (Int) async throws -> Void) async rethrows {
        var times: [Double] = []
        for i in 0..<runs {
            let t = DispatchTime.now().uptimeNanoseconds
            try await body(i)
            times.append(ms(since: t))
        }
        times.sort()
        print(String(format: "%@ ms: p50=%.1f p95=%.1f max=%.1f", name, times[runs / 2], times[runs * 95 / 100], times[runs - 1]))
    }

    let pages = try await ws.allPages()
    print("pages in memory: \(pages.count)")
    try await p95("all pages", runs: 20) { _ in _ = try! await ws.allPages() }

    let tree = pages.filter { $0.databaseID == nil && $0.title.hasPrefix("Страница") }
    try await p95("tree by filter (full walk)", runs: 3) { _ in
        // Прежний способ оболочки: отдельный проход по всему списку на каждую страницу.
        var total = 0
        for page in pages.prefix(2000) { total += pages.filter { $0.parentID == page.id }.count }
        precondition(total >= 0)
    }
    try await p95("tree index build", runs: 20) { _ in _ = PageTree(pages: pages) }
    let index = PageTree(pages: pages)
    try await p95("tree walk with index", runs: 20) { _ in
        var total = 0
        for page in pages { total += index.children(of: page.id).count }
        precondition(total >= 0)
    }

    let session = WorkspaceSession(store: ws, name: "bench")
    try await session.refreshPages()
    try await p95("open page", runs: 50) { i in
        _ = try await session.open(tree[(i * 197) % tree.count].id)
    }

    let words = ["контрольная", "контр", "документ", "план", "проверка", "архив", "ёлка", "страница", "задача", "сохранение"]
    try await p95("search", runs: 50) { i in _ = try await ws.search(words[i % words.count]) }

    let databaseID = try await ws.databaseIndex().values.first!
    let database = try await ws.database(databaseID)!
    let status = database.properties.first { $0.type == .status }!
    let date = database.properties.first { $0.type == .date }!
    try await p95("database first page", runs: 50) { _ in
        _ = try await ws.queryRecords(database: database, state: DatabaseViewState(), limit: 50, offset: 0)
    }
    var state = DatabaseViewState()
    state.filter.items = [.rule(FilterRule(property: status.id, op: .equals, value: status.options[0].id.uuidString))]
    state.sorts = [SortRule(property: date.id, descending: true)]
    try await p95("database filter+sort", runs: 50) { _ in
        _ = try await ws.queryRecords(database: database, state: state, limit: 50, offset: 0)
    }
    try await session.close()
    let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("workspace.sqlite").path)[.size] as? Int) ?? 0
    print("database MB: \(size / 1_000_000)")
}

private func ms(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

private func seedLarge(dir: URL) async throws {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let ws = try SQLiteWorkspace.create(at: dir, name: "Нагрузка AT-17")
    let words = ["контрольная", "документ", "план", "проверка", "архив", "ёлка", "задача", "сохранение", "заметка", "проект", "итог", "неделя"]
    var batch = SaveBatch()
    var roots: [UUID] = []
    for i in 0..<10_000 {
        let id = UUID()
        // Сто разделов по сто страниц: типичное дерево, а не плоский список.
        let parent: UUID? = i % 100 == 0 ? nil : roots.last
        _ = try await ws.createPage(parent: parent, title: "Страница \(i)", id: id, now: 1)
        if parent == nil { roots.append(id) }
        for j in 0..<10 {
            let block = UUID()
            let text = (0..<12).map { words[(i &* 31 &+ j &* 7 &+ $0 &* 3) % words.count] }.joined(separator: " ")
            batch.upserts[block] = Block(id: block, pageID: id, sortKey: "a\(j)", content: BlockContent(text: text), createdAt: 1)
        }
        batch.touchedPages.insert(id)
        if batch.upserts.count >= 2000 {
            try await ws.commit(batch)
            batch = SaveBatch()
        }
    }
    try await ws.commit(batch)
    let template = NewDatabase(title: "Записи", titleProperty: "Название", statusProperty: "Статус",
                               statusOptions: ["Запланировано", "В работе", "Готово"], dateProperty: "Срок", viewName: "Таблица")
    let database = try await ws.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
    let status = database.properties.first { $0.type == .status }!
    let date = database.properties.first { $0.type == .date }!
    var grouped: [Int: [UUID]] = [:]
    var dated: [Int: [UUID]] = [:]
    for i in 0..<10_000 {
        let id = UUID()
        try await ws.createRecord(database: database.id, title: "Запись \(i)", id: id, now: 2)
        grouped[i % status.options.count, default: []].append(id)
        dated[i % 28 + 1, default: []].append(id)
    }
    for (option, ids) in grouped {
        try await ws.setValue(pages: ids, property: status.id, value: .options([status.options[option].id]), now: 3)
    }
    for (day, ids) in dated {
        try await ws.setValue(pages: ids, property: date.id, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 3, day: day)!))), now: 3)
    }
    ws.close()
    print(String(format: "seed s: %.1f", ms(since: t0) / 1000))
}
