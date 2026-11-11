import Foundation

/// Справочник людей пространства (M10): общий для всех баз, без аккаунтов и сети.
extension SQLiteWorkspace {
    private static func peopleError(_ text: String) -> WorkspaceError {
        .storage(code: 0, detail: NSLocalizedString(text, comment: ""))
    }

    static func loadPeople(_ db: SQLiteConnection) throws -> [Person] {
        try db.query("SELECT id, name, color, emoji, sort_key FROM people ORDER BY sort_key, id") { r -> Person? in
            guard let id = r.uuid(0) else { return nil }
            return Person(id: id, name: r.text(1), color: r.optText(2), emoji: r.optText(3), sortKey: r.text(4))
        }.compactMap { $0 }
    }

    func people() async throws -> [Person] {
        try await reader.run { try Self.loadPeople($0) }
    }

    /// Имя без пробелов по краям, непустое и не длиннее предела; эмодзи — один видимый символ или ничего.
    private static func clean(_ person: Person) throws -> Person {
        var out = person
        out.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.name.isEmpty else { throw peopleError("Укажите имя.") }
        guard out.name.count <= PeopleLimits.maxName else { throw peopleError("Слишком длинное имя.") }
        let emoji = person.emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        out.emoji = emoji.isEmpty ? nil : String(emoji.prefix(1))
        return out
    }

    func addPerson(name: String, color: String?, emoji: String?, id: UUID, now: Int64) async throws -> Person {
        let person = try Self.clean(Person(id: id, name: name, color: color, emoji: emoji))
        return try await writer.run { db in
            let last = try db.scalarText("SELECT sort_key FROM people ORDER BY sort_key DESC, id DESC LIMIT 1")
            var stored = person
            stored.sortKey = SortKey.between(last, nil)
            try db.run("INSERT INTO people(id, name, color, emoji, sort_key, created_at) VALUES(?,?,?,?,?,?)",
                       [SQLValue(stored.id), .text(stored.name), SQLValue(stored.color), SQLValue(stored.emoji), .text(stored.sortKey), .int(now)])
            return stored
        }
    }

    /// Имя, цвет и эмодзи. Значения записей хранят ID, поэтому переименование видно сразу во всех базах.
    func updatePerson(_ person: Person, now: Int64) async throws {
        let person = try Self.clean(person)
        try await writer.run { db in
            try db.transaction {
                try db.run("UPDATE people SET name=?, color=?, emoji=? WHERE id=?", [.text(person.name), SQLValue(person.color), SQLValue(person.emoji), SQLValue(person.id)])
                guard db.changes > 0 else { throw Self.peopleError("Человека нет в справочнике.") }
                try SearchIndex.relabelPerson(db, person) // Упоминания в тексте показывают новое имя (M12).
                // Формулы и свёртки могли показывать имя: пересчитываются записи, где человек указан.
                try Self.recalcRollups(db, touched: try Self.pagesWith(db, person: person.id), properties: try Self.personProperties(db), now: now)
            }
        }
    }

    /// Сколько живых записей указывают человека: подтверждение удаления называет реальное число.
    func personUsage(_ id: UUID) async throws -> Int {
        try await reader.run { db in
            Int(try db.scalarInt("""
            SELECT count(DISTINCT v.page_id) FROM property_value_people v JOIN pages p ON p.id = v.page_id WHERE v.person_id=? AND p.deleted_at IS NULL
            """, [SQLValue(id)]) ?? 0)
        }
    }

    /// Удаляет человека и его упоминания в записях, в том числе в корзине. Одна транзакция.
    func deletePerson(_ id: UUID, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                let pages = try Self.pagesWith(db, person: id)
                try db.run("DELETE FROM people WHERE id=?", [SQLValue(id)])
                try Self.updatePersonFilters(db, removing: id)
                try Self.recalcRollups(db, touched: pages, properties: try Self.personProperties(db), now: now)
            }
        }
    }

    private static func pagesWith(_ db: SQLiteConnection, person: UUID) throws -> Set<UUID> {
        Set(try db.query("SELECT DISTINCT page_id FROM property_value_people WHERE person_id=?", [SQLValue(person)]) { $0.uuid(0) }.compactMap { $0 })
    }

    private static func personProperties(_ db: SQLiteConnection) throws -> Set<UUID> {
        Set(try db.query("SELECT id FROM property_definitions WHERE type=?", [.text(PropertyType.person.rawValue)]) { $0.uuid(0) }.compactMap { $0 })
    }

    /// Правила фильтра с удалённым человеком убираются: иначе представление молча показывало бы пустоту.
    private static func updatePersonFilters(_ db: SQLiteConnection, removing person: UUID) throws {
        let views = try db.query("SELECT id, state_json FROM database_views") { ($0.uuid(0), $0.text(1)) }
        for (view, json) in views {
            guard let view, json.contains(person.uuidString) else { continue }
            var state = DatabaseViewState(json: json)
            state.filter = state.filter.removingRules { $0.value == person.uuidString }
            try db.run("UPDATE database_views SET state_json=? WHERE id=?", [.text(try state.jsonString()), SQLValue(view)])
        }
    }
}
