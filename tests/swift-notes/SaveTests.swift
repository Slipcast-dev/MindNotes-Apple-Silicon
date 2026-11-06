import Foundation

final class FakeClock: WallClock {
    var now: Int64 = 1000
    func nowMillis() -> Int64 { now }
}

/// Время двигается вручную, поэтому тесты автосохранения не зависят от реальных пауз.
@MainActor
final class ManualScheduler: SaveScheduler {
    final class Item: ScheduledTask {
        var due: Int64
        var action: (@MainActor () -> Void)?
        init(due: Int64, action: @escaping @MainActor () -> Void) { self.due = due; self.action = action }
        func cancel() { action = nil }
    }
    let clock: FakeClock
    var items: [Item] = []
    init(clock: FakeClock) { self.clock = clock }

    nonisolated func schedule(afterMillis: Int64, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let item = Item(due: clock.now + afterMillis, action: action)
        MainActor.assumeIsolated_unsafe { self.items.append(item) }
        return item
    }

    func advance(_ ms: Int64) async {
        clock.now += ms
        for item in items where item.action != nil && item.due <= clock.now {
            let a = item.action
            item.action = nil
            a?()
        }
        await settle()
    }
}

extension MainActor {
    /// Тесты выполняются на главном потоке, а координатор вызывает планировщик с главного актора.
    static func assumeIsolated_unsafe(_ body: @MainActor () -> Void) {
        withoutActuallyEscaping(body) { b in
            unsafeBitCast(b, to: (() -> Void).self)()
        }
    }
}

/// Даёт фоновым задачам завершиться.
func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 2_000_000)
    for _ in 0..<5 { await Task.yield() }
}

final class FakeSink: BlockSink {
    var commits: [SaveBatch] = []
    var failNext = 0
    var gate: CheckedContinuation<Void, Never>?
    var holdNext = false
    func commit(_ batch: SaveBatch) async throws {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        if failNext > 0 { failNext -= 1; throw WorkspaceError.diskFull }
        commits.append(batch)
    }
}

func oneEdit(_ id: UUID = UUID(), text: String = "т", page: UUID = UUID()) -> SaveBatch {
    var b = SaveBatch()
    b.upserts[id] = Block(id: id, pageID: page, sortKey: "a0", content: BlockContent(text: text), createdAt: 0)
    return b
}

@MainActor
func runSaveTests() async {
    await test("Автосохранение: пауза 500 мс, «Сохранено» только после записи") {
        let clock = FakeClock(), scheduler = ManualScheduler(clock: clock), sink = FakeSink()
        let c = SaveCoordinator(sink: sink, scheduler: scheduler, clock: clock)
        checkEqual(c.status, .saved)
        c.submit(oneEdit())
        checkEqual(c.status, .saving, "статус сразу после правки")
        await scheduler.advance(499)
        checkEqual(sink.commits.count, 0, "пауза ещё не прошла")
        checkEqual(c.status, .saving)
        await scheduler.advance(1)
        checkEqual(sink.commits.count, 1)
        checkEqual(c.status, .saved)
    }

    await test("Автосохранение: непрерывный ввод записывается не позже чем через 2 с") {
        let clock = FakeClock(), scheduler = ManualScheduler(clock: clock), sink = FakeSink()
        let c = SaveCoordinator(sink: sink, scheduler: scheduler, clock: clock)
        let id = UUID()
        for i in 0..<9 {
            c.submit(oneEdit(id, text: "\(i)"))
            await scheduler.advance(250)
        }
        checkEqual(sink.commits.count, 1, "запись при непрерывном вводе")
        checkEqual(sink.commits[0].upserts.count, 1, "правки одного блока слиты")
    }

    await test("Статус честен: правка во время записи не даёт ложного «Сохранено»") {
        let clock = FakeClock(), scheduler = ManualScheduler(clock: clock), sink = FakeSink()
        let c = SaveCoordinator(sink: sink, scheduler: scheduler, clock: clock)
        sink.holdNext = true
        c.submit(oneEdit())
        await scheduler.advance(500)
        check(sink.gate != nil, "запись идёт")
        c.submit(oneEdit())
        sink.gate?.resume(); sink.gate = nil
        await settle()
        checkEqual(sink.commits.count, 1)
        checkEqual(c.status, .saving, "вторая правка ещё не записана")
        await scheduler.advance(500)
        checkEqual(sink.commits.count, 2)
        checkEqual(c.status, .saved)
    }

    await test("AT-10: отказ записи, правки сохраняются, статус «Ошибка», повтор") {
        let clock = FakeClock(), scheduler = ManualScheduler(clock: clock), sink = FakeSink()
        let c = SaveCoordinator(sink: sink, scheduler: scheduler, clock: clock)
        sink.failNext = 2
        var statuses: [SaveStatus] = []
        c.onStatusChange = { statuses.append($0) }
        let a = UUID(), b = UUID()
        c.submit(oneEdit(a, text: "старое"))
        await scheduler.advance(500)
        if case .failed = c.status { check(true) } else { check(false, "ожидалась ошибка, статус \(c.status)") }
        check(!statuses.contains(.saved), "нет ложного «Сохранено»")
        c.submit(oneEdit(a, text: "новое"))
        c.submit(oneEdit(b))
        await scheduler.advance(1000)
        if case .failed = c.status { check(true) } else { check(false, "второй отказ") }
        await scheduler.advance(2000)
        checkEqual(c.status, .saved, "повтор успешен")
        checkEqual(sink.commits.count, 1)
        checkEqual(sink.commits[0].upserts[a]?.plainText, "новое", "новая правка не затёрта старой")
        check(sink.commits[0].upserts[b] != nil, "ничего не потеряно")
    }

    await test("flush: дожидается записи, при отказе бросает ошибку") {
        let clock = FakeClock(), scheduler = ManualScheduler(clock: clock), sink = FakeSink()
        let c = SaveCoordinator(sink: sink, scheduler: scheduler, clock: clock)
        c.submit(oneEdit())
        try await c.flush()
        checkEqual(c.status, .saved)
        checkEqual(sink.commits.count, 1)
        sink.failNext = 1
        c.submit(oneEdit())
        await checkThrows("flush сообщает об отказе") { try await c.flush() }
        check(c.hasUnsavedChanges, "правка сохранена в памяти")
        try await c.flush()
        checkEqual(c.status, .saved)
    }
}

/// Режимы дочернего процесса для тестов аварий.
func handleCrashChild() async -> Bool {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--crash-child"), args.count > i + 2 else { return false }
    let dir = URL(fileURLWithPath: args[i + 1])
    let point = args[i + 2]
    do {
        let ws = try SQLiteWorkspace.open(at: dir)
        let pages = try await ws.allPages()
        guard let page = pages.first else { exit(3) }
        ws.faultHook = { p in if p == point { _exit(42) } }
        var b = SaveBatch()
        let id = UUID()
        b.upserts[id] = Block(id: id, pageID: page.id, sortKey: "b0", content: BlockContent(text: "после аварии: \(point)"), createdAt: 1)
        b.touchedPages = [page.id]
        try await ws.commit(b)
        _exit(0)
    } catch {
        print("child error \(error)")
        _exit(4)
    }
}

func runCrashChild(dir: URL, point: String) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    p.arguments = ["--crash-child", dir.path, point]
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}
