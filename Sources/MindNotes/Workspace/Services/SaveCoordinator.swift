import Foundation

enum SaveStatus: Equatable {
    case saved
    case saving
    case failed(String)
}

/// Планировщик на главной очереди.
final class DispatchSaveScheduler: SaveScheduler {
    private final class Item: ScheduledTask {
        let work: DispatchWorkItem
        init(_ work: DispatchWorkItem) { self.work = work }
        func cancel() { work.cancel() }
    }

    func schedule(afterMillis: Int64, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let work = DispatchWorkItem { MainActor.assumeIsolated(action) }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, afterMillis))), execute: work)
        return Item(work)
    }
}

/// Последовательное автосохранение: один пакет в записи, правки на это время копятся в следующий.
///
/// Статус вычисляется, а не присваивается: «Сохранено» возможно только когда каждая правка
/// подтверждена возвратом из зафиксированной транзакции.
@MainActor
final class SaveCoordinator {
    static let idleDelay: Int64 = 500
    static let maxDelay: Int64 = 2000
    static let retryDelays: [Int64] = [1000, 2000, 5000, 15000]

    private let sink: BlockSink
    private let scheduler: SaveScheduler
    private let clock: WallClock

    private(set) var editSeq: Int64 = 0
    private(set) var committedSeq: Int64 = 0
    private var pending = SaveBatch()
    private var inFlight = false
    private var firstDirty: Int64?
    private var lastEdit: Int64 = 0
    private var timer: ScheduledTask?
    private var lastError: Error?
    private var retryAttempt = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var onStatusChange: ((SaveStatus) -> Void)?

    init(sink: BlockSink, scheduler: SaveScheduler, clock: WallClock) {
        self.sink = sink
        self.scheduler = scheduler
        self.clock = clock
    }

    var status: SaveStatus {
        if editSeq == committedSeq { return .saved }
        if let lastError { return .failed((lastError as? LocalizedError)?.errorDescription ?? "\(lastError)") }
        return .saving
    }

    var hasUnsavedChanges: Bool { editSeq != committedSeq }

    /// Правка уже применена к модели в памяти; здесь она только ставится в очередь записи.
    func submit(_ batch: SaveBatch) {
        guard !batch.isEmpty else { return }
        editSeq += 1
        pending.merge(batch)
        let now = clock.nowMillis()
        lastEdit = now
        if firstDirty == nil { firstDirty = now }
        if lastError == nil { arm() }
        notify()
    }

    private func arm() {
        timer?.cancel()
        guard !inFlight, let first = firstDirty else { return }
        let due = min(lastEdit + Self.idleDelay, first + Self.maxDelay)
        timer = scheduler.schedule(afterMillis: max(0, due - clock.nowMillis())) { [weak self] in self?.startCommit() }
    }

    private func startCommit() {
        timer?.cancel()
        timer = nil
        guard !inFlight, !pending.isEmpty else { return }
        let batch = pending
        let seq = editSeq
        pending = SaveBatch()
        firstDirty = nil
        inFlight = true
        let sink = self.sink
        Task { [weak self] in
            do {
                try await sink.commit(batch)
                self?.finish(seq: seq)
            } catch {
                self?.fail(batch: batch, error: error)
            }
        }
    }

    private func finish(seq: Int64) {
        inFlight = false
        committedSeq = seq
        lastError = nil
        retryAttempt = 0
        if !pending.isEmpty { arm() }
        notify()
        resumeWaiters()
    }

    private func fail(batch: SaveBatch, error: Error) {
        inFlight = false
        lastError = error
        // Новые правки важнее: неудавшийся пакет ложится под них.
        var merged = batch
        merged.merge(pending)
        pending = merged
        if firstDirty == nil { firstDirty = clock.nowMillis() }
        let delay = Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
        retryAttempt += 1
        timer?.cancel()
        timer = scheduler.schedule(afterMillis: delay) { [weak self] in self?.startCommit() }
        notify()
        resumeWaiters()
    }

    /// Ручной повтор из интерфейса.
    func retryNow() {
        retryAttempt = 0
        startCommit()
    }

    /// Дожидается записи всех правок. Бросает ошибку, если очередная попытка не удалась; правки остаются в памяти.
    func flush() async throws {
        while editSeq != committedSeq {
            let attempts = retryAttempt
            if !inFlight { startCommit() }
            await withCheckedContinuation { waiters.append($0) }
            if let lastError, retryAttempt > attempts { throw lastError }
        }
    }

    private func resumeWaiters() {
        let list = waiters
        waiters = []
        for waiter in list { waiter.resume() }
    }

    private func notify() { onStatusChange?(status) }
}
