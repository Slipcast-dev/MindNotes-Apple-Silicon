import Foundation

/// Открытая страница: модель в памяти, отмена и передача правок на сохранение.
/// Запись никогда не возвращает данные в открытый редактор, поэтому выделение и прокрутка не сбрасываются.
@MainActor
final class EditorSession {
    private let store: WorkspaceStore
    private let coordinator: SaveCoordinator
    private let clock: WallClock
    private let ids: IDGenerator
    private let policy = RevisionPolicy()

    private(set) var document: BlockDocument
    private(set) var selection: BlockSelection?
    private var undo = UndoStack()
    private var dirtySinceSnapshot = false
    private var lastSnapshotAt: Int64?
    /// Автоматический снимок в работе: уход со страницы его дожидается.
    private var snapshotTask: Task<Void, Never>?

    /// Срабатывает после каждой правки, отмены и повтора.
    var onChange: (() -> Void)?

    var pageID: UUID { document.pageID }
    var canUndo: Bool { undo.canUndo }
    var canRedo: Bool { undo.canRedo }

    static func open(pageID: UUID, store: WorkspaceStore, coordinator: SaveCoordinator, clock: WallClock, ids: IDGenerator) async throws -> EditorSession {
        let blocks = try await store.blocks(ofPage: pageID)
        let session = EditorSession(document: BlockDocument(pageID: pageID, blocks: blocks), store: store, coordinator: coordinator, clock: clock, ids: ids)
        session.lastSnapshotAt = try await store.revisions(ofPage: pageID).first?.createdAt
        return session
    }

    private init(document: BlockDocument, store: WorkspaceStore, coordinator: SaveCoordinator, clock: WallClock, ids: IDGenerator) {
        self.document = document
        self.store = store
        self.coordinator = coordinator
        self.clock = clock
        self.ids = ids
    }

    /// Выделение из интерфейса: отмена возвращает его вместе с текстом.
    func updateSelection(_ selection: BlockSelection?) { self.selection = selection }

    @discardableResult
    func perform(_ command: EditCommand, recordUndo: Bool = true) throws -> EditResult {
        let now = clock.nowMillis()
        let result = try BlockEditing.apply(command, to: document, ids: ids, now: now)
        guard !result.changes.isEmpty else { return result }
        if recordUndo { undo.record(result, selectionBefore: selection, now: now) }
        document = result.document
        if let s = result.selection { selection = s }
        submit(result.changes)
        onChange?()
        scheduleSnapshotIfDue()
        return result
    }

    func undoStep() {
        guard let e = undo.popUndo() else { return }
        applyHistory(e.inverse, selection: e.selectionBefore)
    }

    func redoStep() {
        guard let e = undo.popRedo() else { return }
        applyHistory(e.forward, selection: e.selectionAfter)
    }

    private func applyHistory(_ changes: [BlockChange], selection s: BlockSelection?) {
        document.apply(changes)
        selection = s
        submit(changes)
        onChange?()
    }

    private func submit(_ changes: [BlockChange]) {
        var batch = SaveBatch()
        for change in changes {
            var one = SaveBatch()
            switch change {
            case .upsert(let b): one.upserts[b.id] = b
            case .delete(let id): one.deletes = [id]
            }
            batch.merge(one)
        }
        batch.touchedPages = [document.pageID]
        coordinator.submit(batch)
        dirtySinceSnapshot = true
    }

    private func scheduleSnapshotIfDue() {
        guard policy.isDue(dirty: dirtySinceSnapshot, lastSnapshotAt: lastSnapshotAt, now: clock.nowMillis()) else { return }
        lastSnapshotAt = clock.nowMillis()
        snapshotTask = Task { try? await self.snapshot(reason: "Автоматический снимок") }
    }

    /// Снимок подтверждённого состояния: сначала запись правок.
    func snapshot(reason: String) async throws {
        try await coordinator.flush()
        let now = clock.nowMillis()
        // Флаг снимается до записи: правка во время снимка снова его поднимет.
        dirtySinceSnapshot = false
        do {
            _ = try await store.saveRevision(pageID: document.pageID, reason: reason, blocks: document.blocks, id: ids.next(), now: now)
        } catch {
            dirtySinceSnapshot = true
            throw error
        }
        lastSnapshotAt = now
    }

    /// Восстановление версии (FR-07.9). Текущее состояние сначала уходит в историю, восстановленное становится
    /// новой версией. Это одна правка: ⌘Z возвращает текст, бывший до восстановления.
    func restore(revisionBlocks: [Block], label: String) async throws {
        try await snapshot(reason: "Перед восстановлением")
        let now = clock.nowMillis()
        let current = Dictionary(uniqueKeysWithValues: document.blocks.map { ($0.id, $0) })
        let target = Set(revisionBlocks.map(\.id))
        var forward: [BlockChange] = []
        var inverse: [BlockChange] = []
        for block in document.blocks where !target.contains(block.id) {
            forward.append(.delete(block.id))
            inverse.append(.upsert(block))
        }
        for var block in revisionBlocks {
            block.pageID = document.pageID
            if var same = current[block.id] {
                same.updatedAt = block.updatedAt
                if same == block { continue }
            }
            block.updatedAt = now
            forward.append(.upsert(block))
            inverse.append(current[block.id].map(BlockChange.upsert) ?? .delete(block.id))
        }
        guard !forward.isEmpty else { return }
        var next = document
        next.apply(forward)
        undo.record(EditResult(document: next, changes: forward, inverse: inverse, selection: nil, coalesceKey: nil),
                    selectionBefore: selection, now: now)
        applyHistory(forward, selection: nil)
        // Пустой версии нужен абзац, как новой странице; он не входит в отмену.
        if document.blocks.isEmpty { try perform(.insertBlock(after: nil, type: .paragraph), recordUndo: false) }
        try await snapshot(reason: label)
    }

    /// Уход со страницы: правки записаны, снимок сделан, если страница менялась.
    func close() async throws {
        await snapshotTask?.value
        try await coordinator.flush()
        if dirtySinceSnapshot { try await snapshot(reason: "Уход со страницы") }
    }

    /// Текст текущей модели в памяти: аварийный экспорт при отказе записи.
    func emergencyText(title: String) -> String {
        var lines = ["# \(title)", ""]
        for b in document.blocks {
            switch b.type {
            case .heading1: lines.append("# \(b.plainText)")
            case .heading2: lines.append("## \(b.plainText)")
            case .heading3: lines.append("### \(b.plainText)")
            case .task: lines.append("- [\(b.content?.checked == true ? "x" : " ")] \(b.plainText)")
            case .bullet: lines.append("- \(b.plainText)")
            case .numbered: lines.append("1. \(b.plainText)")
            case .quote, .callout: lines.append("> \(b.plainText)")
            case .code: lines.append("```\n\(b.plainText)\n```")
            case .divider: lines.append("---")
            default: lines.append(b.plainText)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
