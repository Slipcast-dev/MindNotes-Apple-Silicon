import Foundation

/// Источник времени; в тестах подменяется, бизнес-логика не зависит от реальных часов.
protocol WallClock {
    func nowMillis() -> Int64
}

struct SystemClock: WallClock {
    func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

protocol IDGenerator {
    func next() -> UUID
}

struct RandomIDs: IDGenerator {
    func next() -> UUID { UUID() }
}

/// Отмена запланированной записи.
protocol ScheduledTask {
    func cancel()
}

/// Планировщик автосохранения; в тестах время двигается вручную.
protocol SaveScheduler {
    @discardableResult
    func schedule(afterMillis: Int64, _ action: @escaping @MainActor () -> Void) -> ScheduledTask
}

/// Пакет изменений одной транзакции: последняя правка каждого блока и заголовки страниц.
struct SaveBatch: Equatable {
    var upserts: [UUID: Block] = [:]
    var deletes: Set<UUID> = []
    var touchedPages: Set<UUID> = []
    /// Страницы со служебной правкой (пустой абзац новой страницы): содержимое изменилось, а время изменения — нет.
    var quietPages: Set<UUID> = []
    /// Новые заголовки страниц: переименование подтверждается той же транзакцией, что и текст.
    var titles: [UUID: String] = [:]

    var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty && touchedPages.isEmpty && quietPages.isEmpty && titles.isEmpty }

    /// Новое важнее: повторная правка заменяет старую, удаление отменяет запись.
    mutating func merge(_ newer: SaveBatch) {
        for id in newer.deletes { upserts[id] = nil; deletes.insert(id) }
        for (id, block) in newer.upserts { upserts[id] = block; deletes.remove(id) }
        touchedPages.formUnion(newer.touchedPages)
        quietPages.formUnion(newer.quietPages)
        titles.merge(newer.titles) { _, new in new }
    }
}

/// Приёмник пакетов. Возврат без ошибки означает, что транзакция зафиксирована.
protocol BlockSink: AnyObject {
    func commit(_ batch: SaveBatch) async throws
}

/// Удаление одним действием: страница с её подстраницами.
struct TrashItem: Equatable, Identifiable {
    var page: Page
    var batchID: UUID
    var descendants: Int
    var id: UUID { batchID }
}

/// Операции над страницами и блоками.
protocol WorkspaceStore: BlockSink {
    func workspaceID() async throws -> UUID
    func allPages() async throws -> [Page]
    func page(_ id: UUID) async throws -> Page?
    func createPage(parent: UUID?, title: String, id: UUID, now: Int64) async throws -> Page
    func updatePage(_ page: Page) async throws
    /// Перемещение транзакционно; цикл запрещён.
    func movePage(_ id: UUID, toParent parent: UUID?, afterSibling: UUID?, now: Int64) async throws
    /// Мягкое удаление поддерева одним пакетом.
    func trashPage(_ id: UUID, batch: UUID, now: Int64) async throws
    func trashItems() async throws -> [TrashItem]
    /// Возвращает true, если прежний родитель недоступен и страница восстановлена в корень.
    func restoreTrash(batch: UUID) async throws -> Bool
    /// Окончательное удаление: только по явному действию пользователя.
    func purgeTrash(batch: UUID) async throws
    func blocks(ofPage id: UUID) async throws -> [Block]
    func markOpened(_ id: UUID, now: Int64) async throws
    func saveRevision(pageID: UUID, reason: String, blocks: [Block], id: UUID, now: Int64) async throws -> Revision?
    func revisions(ofPage id: UUID) async throws -> [Revision]
    func revisionBlocks(_ revisionID: UUID) async throws -> [Block]
    /// Удаляет снимки страницы, кроме перечисленных.
    func pruneRevisions(pageID: UUID, keeping: Set<UUID>) async throws
    /// Оригинал синхронизированного блока и все его потомки (ADR-0012); nil — блока нет.
    func syncedSource(_ id: UUID) async throws -> SyncedSource?
    func close()
}

/// Содержимое оригинала для копии: страница, её заголовок и потомки по порядку обхода.
struct SyncedSource: Equatable {
    var block: Block
    var pageTitle: String
    /// Страница оригинала в корзине: копия показывает «Оригинал недоступен».
    var trashed: Bool
    var descendants: [Block]
}

extension WorkspaceStore {
    func syncedSource(_ id: UUID) async throws -> SyncedSource? { nil }
}

/// Запись импортированной базы: заголовок и значения по ID свойств.
struct ImportedRecord: Equatable {
    var id: UUID
    var title: String
    var values: [UUID: PropertyValue]
}

/// Запись в пространство при импорте. Каждый метод — отдельная транзакция.
protocol ImportTarget: AnyObject {
    func createPage(parent: UUID?, title: String, id: UUID, now: Int64) async throws -> Page
    func updatePage(_ page: Page) async throws
    func commit(_ batch: SaveBatch) async throws
    func addAsset(copying given: URL, id: UUID, now: Int64) async throws -> AssetRecord
    /// База целиком: свойства, варианты и записи появляются вместе или не появляются.
    func importDatabase(parent: UUID?, title: String, viewName: String, properties: [PropertyDefinition],
                        records: [ImportedRecord], now: Int64) async throws -> Database
    /// Текстовое свойство (и, если задано, парное в целевой базе) становится связью с готовыми строками.
    func importRelation(property: UUID, target: UUID, pair: UUID?, links: [(from: UUID, to: UUID)], now: Int64) async throws
}

/// Чтение пространства для переносимого экспорта.
protocol ExportSource: AnyObject {
    func allPages() async throws -> [Page]
    func blocks(ofPage id: UUID) async throws -> [Block]
    func assetURL(_ id: UUID) async throws -> URL?
    func databaseIndex() async throws -> [UUID: UUID]
    func database(_ id: UUID) async throws -> Database?
    func queryRecords(database: Database, state: DatabaseViewState, limit: Int, offset: Int) async throws -> RecordPage
}

/// Согласованный снимок базы и его проверка. Реализация в Persistence: слой Backup не знает об SQLite.
protocol DatabaseSnapshotter {
    /// Снимает копию работающей базы средствами SQLite; обычное копирование файла при WAL некорректно.
    func snapshotDatabase(to url: URL) throws
}

struct SnapshotInfo: Equatable {
    var workspaceID: UUID
    var schemaVersion: Int
    var assets: [AssetRecord]
}

protocol SnapshotInspector {
    /// Проверяет целостность копии и читает из неё сведения. Бросает ошибку, если копия неверна.
    func inspect(_ databaseFile: URL) throws -> SnapshotInfo
    /// Назначает восстановленному пространству новый идентификатор, старый сохраняет в `restored_from`.
    func assignNewIdentity(_ databaseFile: URL, newID: UUID, now: Int64) throws
    var supportedSchemaVersion: Int { get }
}
