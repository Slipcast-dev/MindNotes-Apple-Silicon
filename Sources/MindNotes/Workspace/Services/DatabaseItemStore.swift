import Foundation

/// `LocalItemStore` поверх баз данных MindNotes: каждая запись связанной базы — элемент синхронизации,
/// id элемента — id страницы записи. При переносе: `Workspace/Services/`.
///
/// Движок работает синхронно, а база — асинхронно, поэтому:
/// - перед сверкой вызывается `refresh()`: снимок записей и связей в память;
/// - `save` и `purge` сразу меняют снимок и ставят запись в базу в очередь; `flush()` ждёт очередь.
@MainActor
final class DatabaseItemStore: LocalItemStore {
    private(set) var bindings: [CalendarBinding]
    private let source: CalendarRecordSource
    private let linksFile: URL?
    private let now: () -> Date
    private var items: [UUID: LocalItem] = [:]
    private var links: [UUID: CalendarLink] = [:]
    /// К какой связке относится запись (по базе).
    private var owner: [UUID: CalendarBinding] = [:]
    private var queue: Task<Void, Never>?
    private(set) var lastError: String?

    init(source: CalendarRecordSource, bindings: [CalendarBinding], linksFile: URL?, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.bindings = bindings
        self.linksFile = linksFile
        self.now = now
        if let linksFile, let data = try? Data(contentsOf: linksFile),
           let saved = try? JSONDecoder().decode([UUID: CalendarLink].self, from: data) {
            links = saved
        }
    }

    func setBindings(_ b: [CalendarBinding]) { bindings = b }

    // MARK: Снимок

    func prepare() async {
        do { try await refresh() } catch { lastError = "\(error)" }
    }

    func finish() async { await flush() }

    /// Перечитывает записи связанных баз. Записи, которых больше нет, но которые были связаны, становятся удалёнными.
    func refresh() async throws {
        await flush()
        var fresh: [UUID: LocalItem] = [:]
        var freshOwner: [UUID: CalendarBinding] = [:]
        for b in bindings {
            guard let db = try await source.calendarDatabase(b.databaseID) else { continue }
            for row in try await source.calendarRecords(db) {
                let link = links[row.id]
                guard let fields = RecordCalendarMapping.fields(row, binding: b, previous: link?.syncedFields) else {
                    // Событие без даты в Календаре не живёт: если было выгружено — удалить там.
                    if let link, link.externalID != nil { fresh[row.id] = tombstone(row.id, link) ; freshOwner[row.id] = b }
                    continue
                }
                let unchanged = link?.syncedFields.map { $0.sameContent(as: fields) } ?? false
                fresh[row.id] = LocalItem(id: row.id, kind: b.kind, fields: fields, externalID: link?.externalID,
                                          updatedAt: unchanged ? (link?.syncedAt ?? now()) : now(),
                                          syncedAt: link?.syncedAt, isDeleted: false,
                                          syncEnabled: b.enabled && (link?.syncEnabled ?? true))
                freshOwner[row.id] = b
            }
        }
        // Связанные записи, которых нет в выборке: удалены в MindNotes (корзина) или база отвязана.
        for (id, link) in links where fresh[id] == nil {
            guard link.externalID != nil else { links[id] = nil; continue }
            fresh[id] = tombstone(id, link)
        }
        items = fresh
        owner = freshOwner
        persistLinks()
    }

    private func tombstone(_ id: UUID, _ link: CalendarLink) -> LocalItem {
        LocalItem(id: id, kind: link.kind, fields: link.syncedFields ?? SyncFields(title: ""), externalID: link.externalID,
                  updatedAt: now(), syncedAt: link.syncedAt, isDeleted: true, syncEnabled: true)
    }

    // MARK: LocalItemStore

    func all(_ kind: SyncKind) -> [LocalItem] { items.values.filter { $0.kind == kind }.sorted { $0.id.uuidString < $1.id.uuidString } }
    func item(_ id: UUID) -> LocalItem? { items[id] }

    func save(_ item: LocalItem) {
        let old = items[item.id]
        items[item.id] = item
        var link = links[item.id] ?? CalendarLink(kind: item.kind)
        link.externalID = item.externalID
        link.syncEnabled = item.syncEnabled
        // Снимок «как синхронизировано» меняется только вместе с отметкой синхронизации:
        // иначе перепривязка при открытом конфликте спрятала бы правку записи.
        if item.syncedAt != link.syncedAt {
            link.syncedAt = item.syncedAt
            if item.syncedAt != nil { link.syncedFields = item.fields }
        }
        links[item.id] = link
        persistLinks()

        // Изменения, пришедшие из Календаря, записываются в базу.
        if item.isDeleted {
            if old?.isDeleted == false { enqueue { try await self.source.calendarTrash(records: [item.id]) } }
            return
        }
        guard let binding = owner[item.id] ?? bindings.first(where: { $0.kind == item.kind && $0.enabled }) else {
            lastError = "no binding for \(item.kind)"
            return
        }
        owner[item.id] = binding
        if old == nil {
            enqueue {
                try await self.source.calendarCreateRecord(database: binding.databaseID, title: item.fields.title, id: item.id)
                try await self.writeValues(item.fields, binding: binding, id: item.id)
            }
        } else if let old, !old.fields.sameContent(as: item.fields) {
            enqueue {
                if old.fields.title != item.fields.title { try await self.source.calendarRename(record: item.id, title: item.fields.title) }
                try await self.writeValues(item.fields, binding: binding, id: item.id)
            }
        }
    }

    func purge(_ id: UUID) {
        items[id] = nil
        links[id] = nil
        owner[id] = nil
        persistLinks()
    }

    // MARK: Запись в базу

    private func writeValues(_ f: SyncFields, binding: CalendarBinding, id: UUID) async throws {
        for (p, v) in RecordCalendarMapping.values(f, binding: binding) {
            try await source.calendarSetValue(record: id, property: p, value: v)
        }
    }

    private func enqueue(_ op: @escaping @MainActor () async throws -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            do { try await op() } catch { self.lastError = "\(error)" }
        }
    }

    /// Дождаться, пока все изменения дойдут до базы.
    func flush() async {
        while let q = queue {
            await q.value
            if queue == q { queue = nil }
        }
    }

    /// Убрать связи отвязанной базы: элементы в Календаре остаются, но больше не синхронизируются.
    func forget(database: UUID) {
        for (id, b) in owner where b.databaseID == database { links[id] = nil; items[id] = nil; owner[id] = nil }
        persistLinks()
    }

    private func persistLinks() {
        guard let linksFile else { return }
        try? FileManager.default.createDirectory(at: linksFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(links) { try? data.write(to: linksFile, options: .atomic) }
    }
}
