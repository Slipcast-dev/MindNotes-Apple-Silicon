import Foundation

/// Открытое пространство. Создаётся на каждое открытие; единственный владелец сохранения.
@MainActor
final class WorkspaceSession {
    let store: WorkspaceStore
    let coordinator: SaveCoordinator
    let name: String
    private let clock: WallClock
    private let ids: IDGenerator

    private(set) var pages: [Page] = []
    private(set) var editor: EditorSession?
    private var pendingTitles: [UUID: String] = [:]

    init(store: WorkspaceStore, name: String, scheduler: SaveScheduler = DispatchSaveScheduler(),
         clock: WallClock = SystemClock(), ids: IDGenerator = RandomIDs()) {
        self.store = store
        self.name = name
        self.clock = clock
        self.ids = ids
        coordinator = SaveCoordinator(sink: store, scheduler: scheduler, clock: clock)
    }

    func refreshPages() async throws {
        pages = try await store.allPages()
        for (id, title) in pendingTitles {
            if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].title = title }
        }
    }

    /// Создание без диалога имени файла (FR-03).
    @discardableResult
    func createPage(parent: UUID?, title: String) async throws -> Page {
        let page = try await store.createPage(parent: parent, title: title, id: ids.next(), now: clock.nowMillis())
        try await refreshPages()
        return page
    }

    /// Переименование: в модели сразу, запись той же очередью, что и текст блоков.
    func rename(_ id: UUID, title: String) {
        if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].title = title }
        pendingTitles[id] = title
        var batch = SaveBatch()
        batch.titles[id] = title
        coordinator.submit(batch)
    }

    func move(_ id: UUID, toParent parent: UUID?, afterSibling: UUID?) async throws {
        try await coordinator.flush()
        try await store.movePage(id, toParent: parent, afterSibling: afterSibling, now: clock.nowMillis())
        try await refreshPages()
    }

    /// Открывает страницу. Предыдущая сначала записывается, чтобы новая не прочитала устаревшие данные.
    func open(_ id: UUID) async throws -> EditorSession {
        try await editor?.close()
        try await coordinator.flush() // Чтение ниже должно видеть все подтверждённые правки.
        let session = try await EditorSession.open(pageID: id, store: store, coordinator: coordinator, clock: clock, ids: ids)
        // Пустой абзац новой страницы — не правка пользователя и не входит в отмену.
        if session.document.blocks.isEmpty { try session.perform(.insertBlock(after: nil, type: .paragraph), recordUndo: false) }
        try await store.markOpened(id, now: clock.nowMillis())
        editor = session
        try await refreshPages()
        return session
    }

    func closeEditor() async throws {
        let closing = editor
        try await closing?.close()
        // За время записи могла открыться другая страница; её сессию не затираем.
        if editor === closing { editor = nil }
    }

    /// Закрытие пространства: всё записано, затем освобождается блокировка.
    func close() async throws {
        try await closeEditor()
        try await coordinator.flush()
        store.close()
    }
}
