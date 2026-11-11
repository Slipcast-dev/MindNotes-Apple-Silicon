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
    /// Все редакторы этой страницы (основной и поля колонок) узнают о правке любого из них.
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    func observe(_ owner: AnyObject, _ body: @escaping () -> Void) { observers[ObjectIdentifier(owner)] = body }
    func stopObserving(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
        selectionObservers[ObjectIdentifier(owner)] = nil
    }

    /// Выделенные целиком блоки через поля (колонки и основной текст), в порядке документа.
    private(set) var blockSelection: [UUID] = []
    private var selectionObservers: [ObjectIdentifier: () -> Void] = [:]

    func observeSelection(_ owner: AnyObject, _ body: @escaping () -> Void) { selectionObservers[ObjectIdentifier(owner)] = body }

    func setBlockSelection(_ ids: [UUID]) {
        guard ids != blockSelection else { return }
        blockSelection = ids
        for body in selectionObservers.values { body() }
    }
    private func notifyObservers() { for body in observers.values { body() } }

    var pageID: UUID { document.pageID }
    var canUndo: Bool { undo.canUndo }
    var canRedo: Bool { undo.canRedo }

    /// Копия синхронизированного блока на этой странице (ADR-0012).
    struct SyncedRef: Equatable {
        var source: UUID
        var page: UUID
        var title: String
        /// Содержимое оригинала показано в копии; иначе — подпись о причине.
        var shown: Bool
        var reason: Reason
        enum Reason { case shown, unavailable, samePage, repeated }
    }

    /// Копии на странице: ID копии → оригинал.
    private(set) var syncedRefs: [UUID: SyncedRef] = [:]
    /// Блок чужой страницы, показанный в копии → копия, в которой он показан.
    private var foreignRef: [UUID: UUID] = [:]
    /// Последняя записанная страница каждого блока: перенос между рамкой и страницей меняет её.
    private var savedPage: [UUID: UUID] = [:]

    static func open(pageID: UUID, store: WorkspaceStore, coordinator: SaveCoordinator, clock: WallClock, ids: IDGenerator) async throws -> EditorSession {
        let blocks = try await store.blocks(ofPage: pageID)
        let session = EditorSession(document: BlockDocument(pageID: pageID, blocks: blocks), store: store, coordinator: coordinator, clock: clock, ids: ids)
        for b in blocks { session.savedPage[b.id] = b.pageID }
        try await session.loadSyncedSources()
        session.lastSnapshotAt = try await store.revisions(ofPage: pageID).first?.createdAt
        return session
    }

    /// Подгружает содержимое оригиналов для копий, у которых его ещё нет: дети оригинала становятся детьми копии в памяти.
    func loadSyncedSources() async throws {
        let shownSources = Set(syncedRefs.values.filter(\.shown).map(\.source))
        var used = shownSources
        var added: [BlockChange] = []
        for ref in document.blocks where ref.type == .syncedRef && syncedRefs[ref.id] == nil {
            guard let source = AtomData.syncedSource(of: ref) else { continue }
            let found = try await store.syncedSource(source)
            var info = SyncedRef(source: source, page: found?.block.pageID ?? pageID, title: found?.pageTitle ?? "", shown: false, reason: .unavailable)
            if let found, !found.trashed {
                if found.block.pageID == pageID || document.block(source) != nil {
                    info.reason = .samePage
                } else if used.contains(source) {
                    info.reason = .repeated
                } else {
                    used.insert(source)
                    info.shown = true
                    info.reason = .shown
                    for var b in found.descendants {
                        savedPage[b.id] = b.pageID
                        if b.parentID == source { b.parentID = ref.id }
                        foreignRef[b.id] = ref.id
                        added.append(.upsert(b))
                    }
                }
            }
            syncedRefs[ref.id] = info
        }
        if !added.isEmpty { document.apply(added) }
    }

    /// Страница, которой принадлежит блок: внутри показанной копии — страница оригинала.
    func ownerPage(of id: UUID) -> UUID {
        var current = document.block(id)?.parentID
        var guardSteps = 0
        while let parent = current, guardSteps < 10_000 {
            if let ref = syncedRefs[parent], ref.shown { return ref.page }
            current = document.block(parent)?.parentID
            guardSteps += 1
        }
        return pageID
    }

    /// Копия, внутри которой показан блок, или nil.
    private func containingRef(of id: UUID) -> UUID? {
        var current = document.block(id)?.parentID
        while let parent = current {
            if let ref = syncedRefs[parent], ref.shown { return parent }
            current = document.block(parent)?.parentID
        }
        return nil
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
    /// `quiet` — служебная правка, не правка пользователя: время изменения страницы не меняется.
    func perform(_ command: EditCommand, recordUndo: Bool = true, quiet: Bool = false) throws -> EditResult {
        let now = clock.nowMillis()
        let result = try BlockEditing.apply(command, to: document, ids: ids, now: now)
        guard !result.changes.isEmpty else { return result }
        if recordUndo { undo.record(result, selectionBefore: selection, now: now) }
        document = result.document
        if let s = result.selection { selection = s }
        submit(result.changes, quiet: quiet)
        onChange?()
        notifyObservers()
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
        notifyObservers()
    }

    /// Слой перевода (ADR-0012): родитель-копия становится оригиналом, страница блока — по цепочке родителей,
    /// удаление копии не трогает блоки оригинала.
    private func stored(_ block: Block) -> Block {
        var b = block
        b.pageID = ownerPage(of: block.id)
        if let parent = b.parentID, let ref = syncedRefs[parent], ref.shown { b.parentID = ref.source }
        return b
    }

    private func submit(_ changes: [BlockChange], quiet: Bool = false) {
        var batch = SaveBatch()
        var pages: Set<UUID> = [document.pageID]
        for change in changes {
            var one = SaveBatch()
            switch change {
            case .upsert(let b):
                guard document.block(b.id) != nil else { continue }
                let s = stored(b)
                one.upserts[s.id] = s
                savedPage[s.id] = s.pageID
                pages.insert(s.pageID)
                if let ref = containingRef(of: s.id) { foreignRef[s.id] = ref } else { foreignRef[s.id] = nil }
            case .delete(let id):
                // Блок оригинала исчезает из вида вместе с копией, но в хранилище остаётся.
                if let ref = foreignRef[id], document.block(ref) == nil { continue }
                one.deletes = [id]
                savedPage[id] = nil
                foreignRef[id] = nil
            }
            batch.merge(one)
        }
        // Перенос через границу рамки: потомки переезжают на страницу родителя.
        for b in document.blocks where batch.upserts[b.id] == nil {
            let owner = ownerPage(of: b.id)
            if let saved = savedPage[b.id], saved != owner {
                let s = stored(b)
                batch.upserts[s.id] = s
                savedPage[s.id] = owner
                pages.insert(owner)
            }
        }
        if quiet { batch.quietPages = pages } else { batch.touchedPages = pages }
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
            // Снимок — только собственные блоки страницы: содержимое оригинала принадлежит его странице.
            let own = document.blocks.filter { ownerPage(of: $0.id) == document.pageID }
            _ = try await store.saveRevision(pageID: document.pageID, reason: reason, blocks: own, id: ids.next(), now: now)
        } catch {
            dirtySinceSnapshot = true
            throw error
        }
        lastSnapshotAt = now
        // Прореживание — уборка: его сбой не должен мешать сохранению.
        if let all = try? await store.revisions(ofPage: document.pageID) {
            try? await store.pruneRevisions(pageID: document.pageID, keeping: RevisionRetention.keep(all, now: now))
        }
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
        for block in document.blocks where !target.contains(block.id) && ownerPage(of: block.id) == document.pageID {
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
