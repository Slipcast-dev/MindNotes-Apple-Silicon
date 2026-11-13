import Foundation

/// Хранилище MindNotes как источник записей для синхронизации. При переносе: `Persistence/`.
extension SQLiteWorkspace: CalendarRecordSource {
    func calendarDatabases() async throws -> [CalendarDatabaseInfo] {
        let index = try await databaseIndex()
        let pages = try await allPages()
        var out: [CalendarDatabaseInfo] = []
        for dbID in Set(index.values) {
            guard let db = try await database(dbID) else { continue }
            let title = pages.first { $0.id == db.pageID && $0.deletedAt == nil }?.title
            guard let title else { continue }
            out.append(CalendarDatabaseInfo(database: db, title: title))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func calendarDatabase(_ id: UUID) async throws -> Database? { try await database(id) }

    func calendarRecords(_ database: Database) async throws -> [RecordRow] {
        var rows: [RecordRow] = []
        let pageSize = 500
        while true {
            let page = try await queryRecords(database: database, state: DatabaseViewState(), limit: pageSize, offset: rows.count)
            rows += page.rows
            if page.rows.count < pageSize || rows.count >= page.total { break }
        }
        return rows
    }

    func calendarCreateRecord(database: UUID, title: String, id: UUID) async throws {
        try await createRecord(database: database, title: title, id: id, now: SystemClock().nowMillis())
    }

    func calendarRename(record: UUID, title: String) async throws {
        guard var p = try await page(record) else { return }
        p.title = title
        p.updatedAt = SystemClock().nowMillis()
        try await updatePage(p)
    }

    func calendarSetValue(record: UUID, property: UUID, value: PropertyValue?) async throws {
        try await setValue(pages: [record], property: property, value: value, now: SystemClock().nowMillis())
    }

    func calendarTrash(records: [UUID]) async throws {
        try await trashRecords(records, ids: RandomIDs(), now: SystemClock().nowMillis())
    }
}
