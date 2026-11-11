import Foundation

/// Сборка запроса записей. Имена столбцов и операции — только из кода, значения и ID свойств — только параметрами (FR-11).
enum DatabaseQuerySQL {
    struct Fragment {
        var sql: String
        var args: [SQLValue]
    }

    private static let maxDepth = 8

    /// Условие группы. nil — нечего проверять: нет правил, или все они неполны и пропущены.
    static func compile(_ group: FilterGroup, properties: [PropertyDefinition], zone: TimeZone = .current, depth: Int = 0) -> Fragment? {
        guard depth < maxDepth else { return nil }
        let parts = group.items.compactMap { node -> Fragment? in
            switch node {
            case .rule(let rule): return compile(rule, properties: properties, zone: zone)
            case .group(let inner): return compile(inner, properties: properties, zone: zone, depth: depth + 1)
            }
        }
        guard !parts.isEmpty else { return nil }
        let joiner = group.mode == .or ? " OR " : " AND "
        return Fragment(sql: "(" + parts.map(\.sql).joined(separator: joiner) + ")", args: parts.flatMap(\.args))
    }

    /// Связанные записи строки `p`: живые страницы на другой стороне связи. Условие о самой записи добавляется к `q`.
    static func linked(_ def: PropertyDefinition, where condition: String = "1") -> String {
        let (mine, other) = def.config.isBackSide ? ("to_page", "from_page") : ("from_page", "to_page")
        return "SELECT 1 FROM relation_links l JOIN pages q ON q.id = l.\(other) WHERE l.\(mine) = p.id AND l.property_id = ? AND q.deleted_at IS NULL AND \(condition)"
    }

    /// Границы дня в поясе пользователя, мс UTC: «Создано» и «Изменено» — моменты, а фильтр задаётся днём.
    static func dayBounds(_ day: LocalDate, zone: TimeZone) -> (start: Int64, end: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func ms(_ d: LocalDate) -> Int64 {
            Int64((calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000)
        }
        return (ms(day), ms(day.adding(days: 1)))
    }

    /// Правило неизвестного свойства, неподходящей операции или с неполным значением пропускается.
    static func compile(_ rule: FilterRule, properties: [PropertyDefinition], zone: TimeZone = .current) -> Fragment? {
        guard var def = properties.first(where: { $0.id == rule.property }) else { return nil }
        // Свёртка хранится значением своего результата и фильтруется как число, дата или текст.
        def.type = def.valueType
        guard FilterOp.available(for: def.type).contains(rule.op) else { return nil }
        let prop = SQLValue(def.id)
        if def.type == .relation {
            let owner = SQLValue(def.linkOwner)
            switch rule.op {
            case .isEmpty: return Fragment(sql: "NOT EXISTS (\(linked(def)))", args: [owner])
            case .isNotEmpty: return Fragment(sql: "EXISTS (\(linked(def)))", args: [owner])
            case .contains, .notContains:
                let needle = SearchText.normalize(rule.value.trimmingCharacters(in: .whitespaces))
                guard !needle.isEmpty else { return nil }
                let not = rule.op == .notContains ? "NOT " : ""
                return Fragment(sql: "\(not)EXISTS (\(linked(def, where: "instr(minerva_norm(q.title), ?) > 0")))", args: [owner, .text(needle)])
            default: return nil
            }
        }
        if def.type == .files {
            let any = "EXISTS (SELECT 1 FROM property_value_assets pa WHERE pa.page_id = p.id AND pa.property_id = ?)"
            switch rule.op {
            case .isEmpty: return Fragment(sql: "NOT \(any)", args: [prop])
            case .isNotEmpty: return Fragment(sql: any, args: [prop])
            default: return nil
            }
        }
        if def.type == .person {
            let any = "EXISTS (SELECT 1 FROM property_value_people pp WHERE pp.page_id = p.id AND pp.property_id = ?"
            switch rule.op {
            case .isEmpty: return Fragment(sql: "NOT \(any))", args: [prop])
            case .isNotEmpty: return Fragment(sql: "\(any))", args: [prop])
            case .contains, .notContains:
                guard let person = UUID(uuidString: rule.value) else { return nil }
                return Fragment(sql: "\(rule.op == .notContains ? "NOT " : "")\(any) AND pp.person_id = ?)", args: [prop, SQLValue(person)])
            default: return nil
            }
        }
        if def.type.isTimestamp {
            guard let day = LocalDate(iso: rule.value.trimmingCharacters(in: .whitespaces)) else { return nil }
            let column = def.type == .createdTime ? "p.created_at" : "p.updated_at"
            let (start, end) = dayBounds(day, zone: zone)
            switch rule.op {
            case .equals: return Fragment(sql: "(\(column) >= ? AND \(column) < ?)", args: [.int(start), .int(end)])
            case .less: return Fragment(sql: "\(column) < ?", args: [.int(start)])
            case .lessOrEqual: return Fragment(sql: "\(column) < ?", args: [.int(end)])
            case .greater: return Fragment(sql: "\(column) >= ?", args: [.int(end)])
            case .greaterOrEqual: return Fragment(sql: "\(column) >= ?", args: [.int(start)])
            default: return nil
            }
        }
        func value(_ condition: String, _ args: [SQLValue], negate: Bool = false) -> Fragment {
            let sql = "\(negate ? "NOT " : "")EXISTS (SELECT 1 FROM property_values v WHERE v.page_id = p.id AND v.property_id = ? AND \(condition))"
            return Fragment(sql: sql, args: [prop] + args)
        }
        func option(_ id: UUID, negate: Bool) -> Fragment {
            Fragment(sql: "\(negate ? "NOT " : "")EXISTS (SELECT 1 FROM property_value_options o WHERE o.page_id = p.id AND o.property_id = ? AND o.option_id = ?)", args: [prop, SQLValue(id)])
        }
        // Пустое значение: нет ни строки значения, ни выбранных вариантов.
        if rule.op == .isEmpty || rule.op == .isNotEmpty {
            let not = rule.op == .isEmpty ? "NOT " : ""
            if def.type == .title { return Fragment(sql: rule.op == .isEmpty ? "p.title = ''" : "p.title <> ''", args: []) }
            if def.type.usesOptions {
                let any = "(EXISTS (SELECT 1 FROM property_value_options o WHERE o.page_id = p.id AND o.property_id = ?) OR EXISTS (SELECT 1 FROM property_values v WHERE v.page_id = p.id AND v.property_id = ?))"
                return Fragment(sql: not + any, args: [prop, prop])
            }
            return Fragment(sql: "\(not)EXISTS (SELECT 1 FROM property_values v WHERE v.page_id = p.id AND v.property_id = ?)", args: [prop])
        }
        switch def.type {
        case .title, .text, .url:
            let needle = SearchText.normalize(rule.value.trimmingCharacters(in: .whitespaces))
            guard !needle.isEmpty else { return nil }
            let column = def.type == .title ? "minerva_norm(p.title)" : "minerva_norm(v.value_text)"
            let condition: String, args: [SQLValue], negate: Bool
            switch rule.op {
            case .contains: (condition, args, negate) = ("instr(\(column), ?) > 0", [.text(needle)], false)
            case .notContains: (condition, args, negate) = ("instr(\(column), ?) > 0", [.text(needle)], true)
            case .equals: (condition, args, negate) = ("\(column) = ?", [.text(needle)], false)
            case .notEquals: (condition, args, negate) = ("\(column) = ?", [.text(needle)], true)
            case .startsWith: (condition, args, negate) = ("substr(\(column), 1, length(?)) = ?", [.text(needle), .text(needle)], false)
            default: return nil
            }
            if def.type == .title { return Fragment(sql: "\(negate ? "NOT " : "")(\(condition))", args: args) }
            return value(condition, args, negate: negate)
        case .number:
            guard let n = PropertyParse.number(rule.value) else { return nil }
            switch rule.op {
            case .equals: return value("v.value_num = ?", [.real(n)])
            case .notEquals: return value("v.value_num = ?", [.real(n)], negate: true)
            case .less: return value("v.value_num < ?", [.real(n)])
            case .lessOrEqual: return value("v.value_num <= ?", [.real(n)])
            case .greater: return value("v.value_num > ?", [.real(n)])
            case .greaterOrEqual: return value("v.value_num >= ?", [.real(n)])
            default: return nil
            }
        case .date:
            guard let day = LocalDate(iso: rule.value.trimmingCharacters(in: .whitespaces))?.iso else { return nil }
            // Сравнивается день в собственном поясе значения; диапазон покрывает все свои дни.
            let start = "substr(v.value_date, 1, 10)", end = "substr(COALESCE(v.value_date_end, v.value_date), 1, 10)"
            switch rule.op {
            case .equals: return value("\(start) <= ? AND \(end) >= ?", [.text(day), .text(day)])
            case .less: return value("\(start) < ?", [.text(day)])
            case .lessOrEqual: return value("\(start) <= ?", [.text(day)])
            case .greater: return value("\(end) > ?", [.text(day)])
            case .greaterOrEqual: return value("\(end) >= ?", [.text(day)])
            default: return nil
            }
        case .checkbox:
            return value("v.value_num = 1", [], negate: rule.op == .isFalse)
        case .status, .select, .multiSelect:
            guard let id = UUID(uuidString: rule.value), def.options.contains(where: { $0.id == id }) else { return nil }
            return option(id, negate: rule.op == .notEquals || rule.op == .notContains)
        default:
            return nil
        }
    }

    /// Соединения и выражения сортировки: пустые значения всегда в конце, ничья — по порядку записей.
    /// Без сортировки и с `manualView` — ручной порядок этого представления; записи без места в нём идут в конце.
    static func order(_ sorts: [SortRule], properties: [PropertyDefinition], manualView: UUID? = nil) -> (joins: Fragment, order: Fragment) {
        var joins = Fragment(sql: "", args: [])
        var order = Fragment(sql: "", args: [])
        var terms: [String] = []
        if sorts.isEmpty, let manualView {
            joins.sql += " LEFT JOIN view_record_order vo ON vo.view_id = ? AND vo.page_id = p.id"
            joins.args.append(SQLValue(manualView))
            terms.append("vo.sort_key IS NULL, vo.sort_key")
        }
        for (index, sort) in sorts.enumerated() {
            guard var def = properties.first(where: { $0.id == sort.property }) else { continue }
            def.type = def.valueType
            let direction = sort.descending ? "DESC" : "ASC"
            let alias = "s\(index)"
            let expression: String
            switch def.type {
            case .title:
                expression = "minerva_norm(p.title)"
            case .createdTime:
                expression = "p.created_at"
            case .editedTime:
                expression = "p.updated_at"
            case .relation:
                // Связь сортируется по числу живых связанных записей; пустая — в конце.
                expression = "(SELECT NULLIF(count(*), 0) FROM (\(linked(def))))"
                order.args.append(SQLValue(def.linkOwner))
                order.args.append(SQLValue(def.linkOwner))
            case .files:
                // По числу файлов; без файлов — в конце.
                expression = "(SELECT NULLIF(count(*), 0) FROM property_value_assets pa WHERE pa.page_id = p.id AND pa.property_id = ?)"
                order.args.append(SQLValue(def.id))
                order.args.append(SQLValue(def.id))
            case .person:
                // По имени первого по алфавиту человека, как у Notion; без людей — в конце.
                expression = "(SELECT MIN(minerva_norm(pe.name)) FROM property_value_people pv JOIN people pe ON pe.id = pv.person_id WHERE pv.page_id = p.id AND pv.property_id = ?)"
                order.args.append(SQLValue(def.id))
                order.args.append(SQLValue(def.id))
            case .status, .select, .multiSelect:
                expression = "(SELECT MIN(so.sort_key) FROM property_value_options po JOIN property_options so ON so.id = po.option_id WHERE po.page_id = p.id AND po.property_id = ?)"
                order.args.append(SQLValue(def.id))
                // Параметр нужен в двух местах: проверка на пустоту и сама сортировка.
                order.args.append(SQLValue(def.id))
            default:
                joins.sql += " LEFT JOIN property_values \(alias) ON \(alias).page_id = p.id AND \(alias).property_id = ?"
                joins.args.append(SQLValue(def.id))
                switch def.type {
                case .number: expression = "\(alias).value_num"
                case .checkbox: expression = "COALESCE(\(alias).value_num, 0)"
                case .date: expression = "\(alias).value_date"
                default: expression = "minerva_norm(\(alias).value_text)"
                }
            }
            terms.append("(\(expression)) IS NULL, (\(expression)) \(direction)")
        }
        terms.append("p.sort_key")
        terms.append("p.id")
        order.sql = terms.joined(separator: ", ")
        return (joins, order)
    }
}

/// Базы, свойства, значения и представления. Каждое действие — одна транзакция.
extension SQLiteWorkspace {
    private static func storageError(_ text: String) -> WorkspaceError {
        .storage(code: 0, detail: NSLocalizedString(text, comment: ""))
    }

    // MARK: Чтение

    /// Какие страницы являются базами: страница → база.
    func databaseIndex() async throws -> [UUID: UUID] {
        try await reader.run { db in
            var out: [UUID: UUID] = [:]
            for row in try db.query("SELECT page_id, id FROM databases", [], { ($0.uuid(0), $0.uuid(1)) }) {
                if let page = row.0, let id = row.1 { out[page] = id }
            }
            return out
        }
    }

    func database(_ id: UUID) async throws -> Database? {
        try await reader.run { try Self.loadDatabase($0, id) }
    }

    /// Пара связи могла исчезнуть вместе со своей базой при окончательном удалении.
    /// Тогда оставшаяся сторона читается и пишется как самостоятельная связь под своим ID.
    private static func resolvePair(_ db: SQLiteConnection, _ def: inout PropertyDefinition) throws {
        guard def.type == .relation, let pair = def.config.pair else { return }
        if try db.scalarInt("SELECT 1 FROM property_definitions WHERE id=?", [SQLValue(pair)]) == nil {
            def.config.pair = nil
            def.config.isBackSide = false
        }
    }

    static func loadDatabase(_ db: SQLiteConnection, _ id: UUID) throws -> Database? {
        guard let page = try db.query("SELECT page_id FROM databases WHERE id=?", [SQLValue(id)], { $0.uuid(0) }).first ?? nil else { return nil }
        var properties = try db.query("SELECT id, name, type, sort_key, config_json FROM property_definitions WHERE database_id=? ORDER BY sort_key, id", [SQLValue(id)]) { r -> PropertyDefinition? in
            guard let pid = r.uuid(0) else { return nil }
            return PropertyDefinition(id: pid, databaseID: id, name: r.text(1), type: PropertyType(rawValue: r.text(2)), sortKey: r.text(3), config: PropertyConfig(json: r.optText(4)))
        }.compactMap { $0 }
        let options = try db.query("""
        SELECT o.id, o.property_id, o.name, o.color, o.sort_key FROM property_options o JOIN property_definitions d ON d.id = o.property_id
        WHERE d.database_id=? ORDER BY o.sort_key, o.id
        """, [SQLValue(id)]) { r -> (UUID, PropertyOption)? in
            guard let oid = r.uuid(0), let pid = r.uuid(1) else { return nil }
            return (pid, PropertyOption(id: oid, name: r.text(2), color: r.optText(3), sortKey: r.text(4)))
        }.compactMap { $0 }
        for (pid, option) in options {
            if let i = properties.firstIndex(where: { $0.id == pid }) { properties[i].options.append(option) }
        }
        for i in properties.indices { try resolvePair(db, &properties[i]) }
        let views = try db.query("SELECT id, name, kind, sort_key, state_json FROM database_views WHERE database_id=? ORDER BY sort_key, id", [SQLValue(id)]) { r -> DatabaseView? in
            guard let vid = r.uuid(0) else { return nil }
            return DatabaseView(id: vid, databaseID: id, name: r.text(1), kind: r.text(2), sortKey: r.text(3), state: DatabaseViewState(json: r.text(4)))
        }.compactMap { $0 }
        return Database(id: id, pageID: page, properties: properties, views: views)
    }

    /// Страница записей под фильтром; строки за пределами страницы не читаются (FR-11).
    func queryRecords(database: Database, state: DatabaseViewState, limit: Int, offset: Int) async throws -> RecordPage {
        try await queryRecords(database: database, state: state, limit: limit, offset: offset, manualView: nil)
    }

    /// `manualView` — представление, чей ручной порядок действует, когда сортировок нет.
    func queryRecords(database: Database, state: DatabaseViewState, limit: Int, offset: Int, manualView: UUID?) async throws -> RecordPage {
        try await reader.run { db in
            let filter = DatabaseQuerySQL.compile(state.filter, properties: database.properties)
            let (joins, order) = DatabaseQuerySQL.order(state.sorts, properties: database.properties, manualView: manualView)
            let whereSQL = "p.database_id = ? AND p.deleted_at IS NULL" + (filter.map { " AND \($0.sql)" } ?? "")
            let whereArgs = [SQLValue(database.id)] + (filter?.args ?? [])
            let total = try db.scalarInt("SELECT count(*) FROM pages p WHERE \(whereSQL)", whereArgs) ?? 0
            let rows = try db.query("""
            SELECT p.id, p.title, p.icon, p.cover_asset_id FROM pages p\(joins.sql) WHERE \(whereSQL) ORDER BY \(order.sql) LIMIT ? OFFSET ?
            """, joins.args + whereArgs + order.args + [.int(Int64(limit)), .int(Int64(offset))]) { r -> RecordRow? in
                guard let id = r.uuid(0) else { return nil }
                return RecordRow(id: id, title: r.text(1), icon: r.optText(2), cover: r.uuid(3), values: [:])
            }.compactMap { $0 }
            let values = try Self.loadValues(db, pages: rows.map(\.id), properties: database.properties)
            return RecordPage(rows: rows.map { var row = $0; row.values = values[$0.id] ?? [:]; return row }, total: Int(total))
        }
    }

    func recordValues(page: UUID, database: Database) async throws -> [UUID: PropertyValue] {
        try await reader.run { try Self.loadValues($0, pages: [page], properties: database.properties)[page] ?? [:] }
    }

    static func loadValues(_ db: SQLiteConnection, pages: [UUID], properties: [PropertyDefinition]) throws -> [UUID: [UUID: PropertyValue]] {
        guard !pages.isEmpty else { return [:] }
        let types = Dictionary(uniqueKeysWithValues: properties.map { ($0.id, $0.valueType) })
        let marks = Array(repeating: "?", count: pages.count).joined(separator: ",")
        let args = pages.map { SQLValue($0) }
        var out: [UUID: [UUID: PropertyValue]] = [:]
        _ = try db.query("""
        SELECT page_id, property_id, value_text, value_num, value_date, value_date_end, value_ts, value_ts_end, value_tz, unconverted, calc_error
        FROM property_values WHERE page_id IN (\(marks))
        """, args) { r in
            guard let page = r.uuid(0), let prop = r.uuid(1), let type = types[prop] else { return }
            if let error = r.optText(10) { out[page, default: [:]][prop] = .error(error); return }
            if let raw = r.optText(9) { out[page, default: [:]][prop] = .unconverted(raw); return }
            let value: PropertyValue?
            switch type {
            case .number: value = r.isNull(3) ? nil : .number(r.real(3))
            case .checkbox: value = .checkbox(r.real(3) != 0)
            case .url: value = r.optText(2).map { .url($0) }
            case .date: value = decodeDate(r)
            case .text: value = r.optText(2).map { .text($0) }
            default: value = r.optText(2).map { .unconverted($0) } // Неизвестный тип: только показать.
            }
            if let value { out[page, default: [:]][prop] = value }
        }
        _ = try db.query("""
        SELECT v.page_id, v.property_id, v.option_id FROM property_value_options v JOIN property_options o ON o.id = v.option_id
        WHERE v.page_id IN (\(marks)) ORDER BY o.sort_key, o.id
        """, args) { r in
            guard let page = r.uuid(0), let prop = r.uuid(1), let option = r.uuid(2) else { return }
            if case .options(let ids)? = out[page]?[prop] {
                out[page]?[prop] = .options(ids + [option])
            } else {
                out[page, default: [:]][prop] = .options([option])
            }
        }
        if properties.contains(where: { $0.type == .person }) {
            _ = try db.query("""
            SELECT v.page_id, v.property_id, e.id, e.name, e.color, e.emoji, e.sort_key FROM property_value_people v JOIN people e ON e.id = v.person_id
            WHERE v.page_id IN (\(marks)) ORDER BY v.sort_key, e.id
            """, args) { r in
                guard let page = r.uuid(0), let prop = r.uuid(1), types[prop] == .person, let id = r.uuid(2) else { return }
                let person = Person(id: id, name: r.text(3), color: r.optText(4), emoji: r.optText(5), sortKey: r.text(6))
                if case .people(let list)? = out[page]?[prop] { out[page]?[prop] = .people(list + [person]) } else { out[page, default: [:]][prop] = .people([person]) }
            }
        }
        if properties.contains(where: { $0.type == .files }) {
            _ = try db.query("""
            SELECT v.page_id, v.property_id, a.id, a.original_name FROM property_value_assets v JOIN assets a ON a.id = v.asset_id
            WHERE v.page_id IN (\(marks)) ORDER BY v.sort_key, a.id
            """, args) { r in
                guard let page = r.uuid(0), let prop = r.uuid(1), types[prop] == .files, let id = r.uuid(2) else { return }
                let file = AttachedFile(id: id, name: r.text(3))
                if case .files(let list)? = out[page]?[prop] { out[page]?[prop] = .files(list + [file]) } else { out[page, default: [:]][prop] = .files([file]) }
            }
        }
        for def in properties where def.type == .relation {
            let (mine, other) = def.config.isBackSide ? ("to_page", "from_page") : ("from_page", "to_page")
            // Прямая сторона — в порядке связи, обратная — по заголовку: у неё нет собственного порядка.
            let order = def.config.isBackSide ? "minerva_norm(q.title), q.id" : "l.sort_key, q.id"
            var collected: [UUID: [LinkedPage]] = [:]
            _ = try db.query("""
            SELECT l.\(mine), q.id, q.title, q.icon FROM relation_links l JOIN pages q ON q.id = l.\(other)
            WHERE l.property_id = ? AND l.\(mine) IN (\(marks)) AND q.deleted_at IS NULL ORDER BY \(order)
            """, [SQLValue(def.linkOwner)] + args) { r in
                guard let page = r.uuid(0), let target = r.uuid(1) else { return }
                collected[page, default: []].append(LinkedPage(id: target, title: r.text(2), icon: r.optText(3)))
            }
            for (page, links) in collected { out[page, default: [:]][def.id] = .relation(links) }
        }
        let stamps = properties.filter(\.type.isTimestamp)
        if !stamps.isEmpty {
            _ = try db.query("SELECT id, created_at, updated_at FROM pages WHERE id IN (\(marks))", args) { r in
                guard let page = r.uuid(0) else { return }
                for def in stamps { out[page, default: [:]][def.id] = .time(def.type == .createdTime ? r.int(1) : r.int(2)) }
            }
        }
        return out
    }

    private static func decodeDate(_ r: SQLRow) -> PropertyValue? {
        if !r.isNull(6) {
            let zone = r.text(8)
            let start = DatePoint.moment(ms: r.int(6), zone: zone)
            return .date(DateValue(start: start, end: r.optInt(7).map { .moment(ms: $0, zone: zone) }))
        }
        guard let start = r.optText(4).flatMap(LocalDate.init(iso:)) else { return nil }
        return .date(DateValue(start: .day(start), end: r.optText(5).flatMap(LocalDate.init(iso:)).map { .day($0) }))
    }

    // MARK: Создание

    /// База со свойствами по умолчанию и первым представлением: появляется целиком или не появляется.
    func createDatabase(parent: UUID?, template: NewDatabase, ids: IDGenerator, now: Int64) async throws -> Database {
        try await writer.run { db in
            try db.transaction {
                if let parent, try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND deleted_at IS NULL", [SQLValue(parent)]) == nil { throw WorkspaceError.pageNotFound(parent) }
                let last = try db.scalarText("SELECT sort_key FROM pages WHERE parent_id IS ? AND deleted_at IS NULL ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(parent)])
                let page = ids.next(), id = ids.next()
                try db.run("INSERT INTO pages(id, parent_id, sort_key, title, created_at, updated_at) VALUES(?,?,?,?,?,?)",
                           [SQLValue(page), SQLValue(parent), .text(SortKey.between(last, nil)), .text(template.title), .int(now), .int(now)])
                try SearchIndex.updateTitle(db, page: page, title: template.title)
                try db.run("INSERT INTO databases(id, page_id, created_at) VALUES(?,?,?)", [SQLValue(id), SQLValue(page), .int(now)])
                let keys = SortKey.keys(after: nil, before: nil, count: 3)
                let definitions: [(String, PropertyType)] = [(template.titleProperty, .title), (template.statusProperty, .status), (template.dateProperty, .date)]
                var status: UUID?
                for (i, item) in definitions.enumerated() {
                    let pid = ids.next()
                    if item.1 == .status { status = pid }
                    try db.run("INSERT INTO property_definitions(id, database_id, name, type, sort_key, created_at) VALUES(?,?,?,?,?,?)",
                               [SQLValue(pid), SQLValue(id), .text(item.0), .text(item.1.rawValue), .text(keys[i]), .int(now)])
                }
                let optionKeys = SortKey.keys(after: nil, before: nil, count: template.statusOptions.count)
                for (name, key) in zip(template.statusOptions, optionKeys) {
                    try db.run("INSERT INTO property_options(id, property_id, name, sort_key) VALUES(?,?,?,?)", [SQLValue(ids.next()), SQLValue(status), .text(name), .text(key)])
                }
                try db.run("INSERT INTO database_views(id, database_id, name, kind, sort_key, state_json) VALUES(?,?,?,?,?,?)",
                           [SQLValue(ids.next()), SQLValue(id), .text(template.viewName), .text(DatabaseView.tableKind), .text(SortKey.between(nil, nil)), .text(try DatabaseViewState().jsonString())])
                var viewKey = SortKey.between(nil, nil)
                for extra in template.extraViews {
                    viewKey = SortKey.between(viewKey, nil)
                    try db.run("INSERT INTO database_views(id, database_id, name, kind, sort_key, state_json) VALUES(?,?,?,?,?,?)",
                               [SQLValue(ids.next()), SQLValue(id), .text(extra.name), .text(extra.kind), .text(viewKey), .text(try DatabaseViewState().jsonString())])
                }
                guard let created = try Self.loadDatabase(db, id) else { throw WorkspaceError.corrupted("база не создана") }
                return created
            }
        }
    }

    func importDatabase(parent: UUID?, title: String, viewName: String, properties: [PropertyDefinition],
                        records: [ImportedRecord], now: Int64) async throws -> Database {
        let ids = RandomIDs()
        return try await writer.run { db in
            try db.transaction {
                if let parent, try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND deleted_at IS NULL", [SQLValue(parent)]) == nil { throw WorkspaceError.pageNotFound(parent) }
                let last = try db.scalarText("SELECT sort_key FROM pages WHERE parent_id IS ? AND deleted_at IS NULL ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(parent)])
                let page = ids.next(), id = ids.next()
                try db.run("INSERT INTO pages(id, parent_id, sort_key, title, created_at, updated_at) VALUES(?,?,?,?,?,?)",
                           [SQLValue(page), SQLValue(parent), .text(SortKey.between(last, nil)), .text(title), .int(now), .int(now)])
                try SearchIndex.updateTitle(db, page: page, title: title)
                try db.run("INSERT INTO databases(id, page_id, created_at) VALUES(?,?,?)", [SQLValue(id), SQLValue(page), .int(now)])
                let keys = SortKey.keys(after: nil, before: nil, count: properties.count)
                var stored: [PropertyDefinition] = []
                for (property, key) in zip(properties, keys) {
                    var def = property
                    def.databaseID = id
                    def.sortKey = key
                    try db.run("INSERT INTO property_definitions(id, database_id, name, type, sort_key, created_at) VALUES(?,?,?,?,?,?)",
                               [SQLValue(def.id), SQLValue(id), .text(def.name), .text(def.type.rawValue), .text(key), .int(now)])
                    for (option, optionKey) in zip(def.options, SortKey.keys(after: nil, before: nil, count: def.options.count)) {
                        try db.run("INSERT INTO property_options(id, property_id, name, color, sort_key) VALUES(?,?,?,?,?)",
                                   [SQLValue(option.id), SQLValue(def.id), .text(option.name), SQLValue(option.color), .text(optionKey)])
                    }
                    stored.append(def)
                }
                try db.run("INSERT INTO database_views(id, database_id, name, kind, sort_key, state_json) VALUES(?,?,?,?,?,?)",
                           [SQLValue(ids.next()), SQLValue(id), .text(viewName), .text(DatabaseView.tableKind), .text(SortKey.between(nil, nil)), .text(try DatabaseViewState().jsonString())])
                let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
                for (record, key) in zip(records, SortKey.keys(after: nil, before: nil, count: records.count)) {
                    try db.run("INSERT INTO pages(id, parent_id, database_id, sort_key, title, created_at, updated_at) VALUES(?,?,?,?,?,?,?)",
                               [SQLValue(record.id), SQLValue(page), SQLValue(id), .text(key), .text(record.title), .int(now), .int(now)])
                    try SearchIndex.updateTitle(db, page: record.id, title: record.title)
                    for (propertyID, value) in record.values {
                        guard let def = byID[propertyID], def.type != .title else { continue }
                        try Self.writeValue(db, page: record.id, def: def, value: value, now: now)
                    }
                }
                guard let created = try Self.loadDatabase(db, id) else { throw WorkspaceError.corrupted("база не создана") }
                return created
            }
        }
    }

    /// Запись — обычная страница базы: открывается редактором и попадает в корзину как все страницы.
    func createRecord(database: UUID, title: String, id: UUID, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                guard let page = try db.query("SELECT d.page_id FROM databases d JOIN pages q ON q.id = d.page_id WHERE d.id=? AND q.deleted_at IS NULL", [SQLValue(database)], { $0.uuid(0) }).first ?? nil else {
                    throw Self.storageError("База недоступна.")
                }
                let last = try db.scalarText("SELECT sort_key FROM pages WHERE parent_id = ? AND deleted_at IS NULL ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(page)])
                try db.run("INSERT INTO pages(id, parent_id, database_id, sort_key, title, created_at, updated_at) VALUES(?,?,?,?,?,?,?)",
                           [SQLValue(id), SQLValue(page), SQLValue(database), .text(SortKey.between(last, nil)), .text(title), .int(now), .int(now)])
                try SearchIndex.updateTitle(db, page: id, title: title)
                // Новая запись сразу получает свои счётчики (0), а не пустую ячейку.
                try Self.recalcRollups(db, touched: [id], properties: nil, now: now)
            }
        }
    }

    /// Несколько записей в корзину одной транзакцией; каждая восстанавливается отдельно.
    func trashRecords(_ pages: [UUID], ids: IDGenerator, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                for page in pages {
                    try db.run("""
                    WITH RECURSIVE sub(id) AS (
                        SELECT ? UNION ALL SELECT p.id FROM pages p JOIN sub ON p.parent_id = sub.id WHERE p.deleted_at IS NULL
                    ) UPDATE pages SET deleted_at=?, trash_batch_id=? WHERE id IN (SELECT id FROM sub) AND deleted_at IS NULL
                    """, [SQLValue(page), .int(now), SQLValue(ids.next())])
                }
                let set = Set(pages)
                try Self.recalcRollups(db, touched: set.union(try Self.neighbors(db, of: set)), properties: nil, now: now)
            }
        }
    }

    // MARK: Значения

    static func definition(_ db: SQLiteConnection, _ id: UUID) throws -> PropertyDefinition {
        let rows = try db.query("SELECT id, database_id, name, type, sort_key, config_json FROM property_definitions WHERE id=?", [SQLValue(id)]) { r -> PropertyDefinition? in
            guard let pid = r.uuid(0), let dbid = r.uuid(1) else { return nil }
            return PropertyDefinition(id: pid, databaseID: dbid, name: r.text(2), type: PropertyType(rawValue: r.text(3)), sortKey: r.text(4), config: PropertyConfig(json: r.optText(5)))
        }
        guard var def = rows.first ?? nil else { throw storageError("Свойство не найдено.") }
        try resolvePair(db, &def)
        def.options = try db.query("SELECT id, name, color, sort_key FROM property_options WHERE property_id=? ORDER BY sort_key, id", [SQLValue(id)]) { r -> PropertyOption? in
            guard let oid = r.uuid(0) else { return nil }
            return PropertyOption(id: oid, name: r.text(1), color: r.optText(2), sortKey: r.text(3))
        }.compactMap { $0 }
        return def
    }

    /// Значение обязано соответствовать типу свойства: неверное не записывается.
    private static func isCompatible(_ value: PropertyValue, with def: PropertyDefinition) -> Bool {
        switch (value, def.type) {
        case (.text, .text), (.url, .url), (.checkbox, .checkbox): return true
        case (.number(let n), .number): return n.isFinite
        case (.date(let d), .date): return d.isValid
        case (.options(let ids), .status), (.options(let ids), .select):
            return ids.count <= 1 && ids.allSatisfy { id in def.options.contains { $0.id == id } }
        case (.options(let ids), .multiSelect):
            return ids.allSatisfy { id in def.options.contains { $0.id == id } }
        case (.relation(let links), .relation):
            return links.count <= RelationLimits.maxLinks && Set(links.map(\.id)).count == links.count
        case (.people(let people), .person):
            return people.count <= PeopleLimits.maxPerValue && Set(people.map(\.id)).count == people.count
        case (.files(let files), .files):
            return files.count <= FileLimits.maxPerValue && Set(files.map(\.id)).count == files.count
        case (.unconverted, _): return def.type != .relation && def.type != .person && def.type != .files
        default: return false
        }
    }

    /// Связи одной записи по одному свойству. Связи с записями в корзине и скрытыми страницами не трогаются:
    /// они не видны, но вернутся вместе с восстановленной записью.
    private static func writeLinks(_ db: SQLiteConnection, page: UUID, def: PropertyDefinition, links: [UUID]) throws {
        guard let target = def.config.target else { throw storageError("Связь не настроена.") }
        let owner = SQLValue(def.linkOwner)
        let (mine, other) = def.config.isBackSide ? ("to_page", "from_page") : ("from_page", "to_page")
        for link in links {
            guard try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND database_id=? AND deleted_at IS NULL", [SQLValue(link), SQLValue(target)]) != nil else {
                throw storageError("Связанная запись недоступна.")
            }
        }
        if def.config.isBackSide {
            // Обратная сторона меняет только то, что добавили или сняли: порядок у связанных записей задаёт прямая сторона.
            let existing = Set(try db.query("""
            SELECT l.from_page FROM relation_links l JOIN pages q ON q.id = l.from_page WHERE l.to_page=? AND l.property_id=? AND q.deleted_at IS NULL
            """, [SQLValue(page), owner]) { $0.uuid(0) }.compactMap { $0 })
            let wanted = Set(links)
            for gone in existing.subtracting(wanted) {
                try db.run("DELETE FROM relation_links WHERE from_page=? AND property_id=? AND to_page=?", [SQLValue(gone), owner, SQLValue(page)])
            }
            for from in links where !existing.contains(from) {
                let last = try db.scalarText("SELECT max(sort_key) FROM relation_links WHERE from_page=? AND property_id=?", [SQLValue(from), owner])
                try db.run("INSERT OR IGNORE INTO relation_links(from_page, property_id, to_page, sort_key) VALUES(?,?,?,?)",
                           [SQLValue(from), owner, SQLValue(page), .text(SortKey.between(last, nil))])
            }
            return
        }
        try db.run("DELETE FROM relation_links WHERE \(mine)=? AND property_id=? AND \(other) IN (SELECT id FROM pages WHERE deleted_at IS NULL)", [SQLValue(page), owner])
        // Скрытые связи остаются первыми: новые встают после них.
        let kept = try db.scalarText("SELECT max(sort_key) FROM relation_links WHERE \(mine)=? AND property_id=?", [SQLValue(page), owner])
        for (link, key) in zip(links, SortKey.keys(after: kept, before: nil, count: links.count)) {
            try db.run("INSERT OR IGNORE INTO relation_links(from_page, property_id, to_page, sort_key) VALUES(?,?,?,?)", [SQLValue(page), owner, SQLValue(link), .text(key)])
        }
    }

    private static func writeValue(_ db: SQLiteConnection, page: UUID, def: PropertyDefinition, value: PropertyValue?, now: Int64) throws {
        if def.type == .relation {
            guard case .relation(let links)? = value else { return try writeLinks(db, page: page, def: def, links: []) }
            return try writeLinks(db, page: page, def: def, links: links.map(\.id))
        }
        guard !def.type.isComputed else { return }
        let keys: [SQLValue] = [SQLValue(page), SQLValue(def.id)]
        if def.type == .files {
            try db.run("DELETE FROM property_value_assets WHERE page_id=? AND property_id=?", keys)
            guard case .files(let files)? = value else { return }
            for (file, key) in zip(files, SortKey.keys(after: nil, before: nil, count: files.count)) {
                guard try db.scalarInt("SELECT 1 FROM assets WHERE id=?", [SQLValue(file.id)]) != nil else { throw storageError("Файл недоступен.") }
                try db.run("INSERT INTO property_value_assets(page_id, property_id, asset_id, sort_key) VALUES(?,?,?,?)", keys + [SQLValue(file.id), .text(key)])
            }
            return
        }
        if def.type == .person {
            try db.run("DELETE FROM property_value_people WHERE page_id=? AND property_id=?", keys)
            guard case .people(let people)? = value else { return }
            for (person, key) in zip(people, SortKey.keys(after: nil, before: nil, count: people.count)) {
                guard try db.scalarInt("SELECT 1 FROM people WHERE id=?", [SQLValue(person.id)]) != nil else { throw storageError("Человека нет в справочнике.") }
                try db.run("INSERT INTO property_value_people(page_id, property_id, person_id, sort_key) VALUES(?,?,?,?)", keys + [SQLValue(person.id), .text(key)])
            }
            return
        }
        try db.run("DELETE FROM property_value_options WHERE page_id=? AND property_id=?", keys)
        try db.run("DELETE FROM property_values WHERE page_id=? AND property_id=?", keys)
        guard let value else { return }
        var text: String?, num: Double?, date: String?, dateEnd: String?, ts: Int64?, tsEnd: Int64?, tz: String?, raw: String?
        switch value {
        case .text(let s), .url(let s):
            if s.isEmpty { return }
            text = s
        case .number(let n): num = n
        case .checkbox(let b): num = b ? 1 : 0
        case .unconverted(let s): raw = s
        case .date(let d):
            date = d.start.localText
            dateEnd = d.end?.localText
            if case .moment(let ms, let zone) = d.start { ts = ms; tz = zone }
            if case .moment(let ms, _)? = d.end { tsEnd = ms }
        case .options(let ids):
            for id in ids {
                try db.run("INSERT OR IGNORE INTO property_value_options(page_id, property_id, option_id) VALUES(?,?,?)", keys + [SQLValue(id)])
            }
            return
        case .relation, .time, .error, .people, .files: return
        }
        try db.run("""
        INSERT INTO property_values(page_id, property_id, value_text, value_num, value_date, value_date_end, value_ts, value_ts_end, value_tz, unconverted, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        """, keys + [SQLValue(text), num.map { .real($0) } ?? .null, SQLValue(date), SQLValue(dateEnd), SQLValue(ts), SQLValue(tsEnd), SQLValue(tz), SQLValue(raw), .int(now)])
    }

    /// Значение одного свойства у одной или многих записей; одна транзакция: применится ко всем или ни к одной (FR-10).
    func setValue(pages: [UUID], property: UUID, value: PropertyValue?, now: Int64) async throws {
        try await setValues(property: property, pages.map { ($0, value) }, now: now)
    }

    /// Каждой записи своё значение одного свойства, одной транзакцией: так отмена возвращает прежние значения разом (M10.5).
    func setValues(property: UUID, _ values: [(page: UUID, value: PropertyValue?)], now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                let def = try Self.definition(db, property)
                guard def.type.isKnown, def.type != .title, !def.type.isComputed else { throw Self.storageError("Это свойство нельзя изменить здесь.") }
                for value in values.compactMap(\.value) where !Self.isCompatible(value, with: def) { throw Self.storageError("Значение не подходит типу свойства.") }
                let pages = values.map(\.page)
                // Связь: прежние и новые записи другой стороны тоже затронуты, их свёртки пересчитываются.
                var touched = Set(pages)
                if def.type == .relation {
                    let (mine, other) = def.config.isBackSide ? ("to_page", "from_page") : ("from_page", "to_page")
                    for page in pages {
                        for id in try db.query("SELECT \(other) FROM relation_links WHERE \(mine)=? AND property_id=?", [SQLValue(page), SQLValue(def.linkOwner)], { $0.uuid(0) }) {
                            if let id { touched.insert(id) }
                        }
                    }
                    for case .relation(let links)? in values.map(\.value) { touched.formUnion(links.map(\.id)) }
                }
                for (page, value) in values {
                    guard try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND database_id=?", [SQLValue(page), SQLValue(def.databaseID)]) != nil else {
                        throw Self.storageError("Запись не входит в эту базу.")
                    }
                    try Self.writeValue(db, page: page, def: def, value: value, now: now)
                    try db.run("UPDATE pages SET updated_at=? WHERE id=?", [.int(now), SQLValue(page)])
                }
                // Свёртка может стоять и на парной стороне связи; формулы с «Изменено» тоже зависят от правки.
                var changed: Set<UUID> = Set([def.id, def.linkOwner] + (def.config.pair.map { [$0] } ?? []))
                changed.formUnion(try Self.editedStamps(db, pages: Set(pages)))
                try Self.recalcRollups(db, touched: touched, properties: changed, now: now)
            }
        }
    }

    // MARK: Свойства

    func addProperty(database: UUID, name: String, type: PropertyType, id: UUID, now: Int64) async throws {
        guard PropertyType.creatable.contains(type), ![.relation, .rollup, .formula].contains(type) else { throw Self.storageError("Этот тип свойства нельзя создать.") }
        try await writer.run { db in
            let last = try db.scalarText("SELECT sort_key FROM property_definitions WHERE database_id=? ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(database)])
            try db.run("INSERT INTO property_definitions(id, database_id, name, type, sort_key, created_at) VALUES(?,?,?,?,?,?)",
                       [SQLValue(id), SQLValue(database), .text(name), .text(type.rawValue), .text(SortKey.between(last, nil)), .int(now)])
        }
    }

    /// Связь с базой `target`. Двусторонняя создаёт в целевой базе обратное свойство `pairID` (FR-13).
    /// Связь базы с самой собой допустима: тогда обе стороны — свойства одной базы.
    func addRelation(database: UUID, name: String, target: UUID, twoWay: Bool, pairName: String, id: UUID, pairID: UUID, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                for base in [database, target] {
                    guard try db.scalarInt("SELECT 1 FROM databases d JOIN pages q ON q.id = d.page_id WHERE d.id=? AND q.deleted_at IS NULL", [SQLValue(base)]) != nil else {
                        throw Self.storageError("База недоступна.")
                    }
                }
                func insert(_ pid: UUID, into base: UUID, name: String, config: PropertyConfig) throws {
                    let last = try db.scalarText("SELECT sort_key FROM property_definitions WHERE database_id=? ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(base)])
                    try db.run("INSERT INTO property_definitions(id, database_id, name, type, sort_key, created_at, config_json) VALUES(?,?,?,?,?,?,?)",
                               [SQLValue(pid), SQLValue(base), .text(name), .text(PropertyType.relation.rawValue), .text(SortKey.between(last, nil)), .int(now), .text(try config.jsonString())])
                }
                try insert(id, into: database, name: name, config: PropertyConfig(target: target, pair: twoWay ? pairID : nil))
                if twoWay { try insert(pairID, into: target, name: pairName, config: PropertyConfig(target: database, pair: id, isBackSide: true)) }
            }
        }
    }

    /// Импорт: текстовое свойство становится связью с базой `target`, на его месте и под тем же именем.
    /// `pair` — текстовое свойство целевой базы, которое станет обратной стороной (Notion выгружает обе).
    /// `links` — пары «запись → связанная запись» в порядке ячеек. Одна транзакция: всё или ничего.
    func importRelation(property: UUID, target: UUID, pair: UUID?, links: [(from: UUID, to: UUID)], now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                let def = try Self.definition(db, property)
                guard def.type == .text else { throw Self.storageError("Связью становится только текстовое свойство.") }
                var sides = [(def, PropertyConfig(target: target, pair: pair))]
                if let pair {
                    let other = try Self.definition(db, pair)
                    guard other.type == .text, other.databaseID == target, other.id != property else { throw Self.storageError("Связью становится только текстовое свойство.") }
                    sides.append((other, PropertyConfig(target: def.databaseID, pair: property, isBackSide: true)))
                }
                for (side, config) in sides {
                    try db.run("DELETE FROM property_values WHERE property_id=?", [SQLValue(side.id)])
                    try db.run("DELETE FROM property_value_options WHERE property_id=?", [SQLValue(side.id)])
                    try db.run("UPDATE property_definitions SET type=?, config_json=? WHERE id=?",
                               [.text(PropertyType.relation.rawValue), .text(try config.jsonString()), SQLValue(side.id)])
                }
                var counts: [UUID: Int] = [:]
                var last: [UUID: String] = [:]
                var touched: Set<UUID> = []
                for link in links {
                    guard try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND database_id=? AND deleted_at IS NULL", [SQLValue(link.from), SQLValue(def.databaseID)]) != nil,
                          try db.scalarInt("SELECT 1 FROM pages WHERE id=? AND database_id=? AND deleted_at IS NULL", [SQLValue(link.to), SQLValue(target)]) != nil else {
                        throw Self.storageError("Связанная запись недоступна.")
                    }
                    guard counts[link.from, default: 0] < RelationLimits.maxLinks else { continue }
                    let key = SortKey.between(last[link.from], nil)
                    try db.run("INSERT OR IGNORE INTO relation_links(from_page, property_id, to_page, sort_key) VALUES(?,?,?,?)",
                               [SQLValue(link.from), SQLValue(property), SQLValue(link.to), .text(key)])
                    if db.changes > 0 { counts[link.from, default: 0] += 1; last[link.from] = key }
                    touched.formUnion([link.from, link.to])
                }
                try Self.recalcRollups(db, touched: touched, properties: Set(sides.map(\.0.id)), now: now)
            }
        }
    }

    /// Снимает парность: оставшаяся сторона становится односторонней связью и сохраняет все строки.
    /// Если остаётся обратная сторона, строки переходят под неё с обменом направлений.
    private static func detachRelation(_ db: SQLiteConnection, removing def: PropertyDefinition) throws {
        guard def.type == .relation, let pair = def.config.pair, var other = try? definition(db, pair), other.config.pair == def.id else { return }
        if !def.config.isBackSide {
            try db.run("UPDATE relation_links SET from_page=to_page, to_page=from_page, property_id=? WHERE property_id=?", [SQLValue(other.id), SQLValue(def.id)])
        }
        other.config.pair = nil
        other.config.isBackSide = false
        try db.run("UPDATE property_definitions SET config_json=? WHERE id=?", [.text(try other.config.jsonString()), SQLValue(other.id)])
    }

    func renameProperty(_ id: UUID, to name: String) async throws {
        try await writer.run { try $0.run("UPDATE property_definitions SET name=? WHERE id=?", [.text(name), SQLValue(id)]) }
    }

    /// Удаляет свойство, его значения и упоминания в представлениях. Заголовок удалить нельзя.
    func deleteProperty(_ id: UUID) async throws {
        try await writer.run { db in
            try db.transaction {
                let def = try Self.definition(db, id)
                guard def.type != .title else { throw Self.storageError("Заголовок нельзя удалить.") }
                try Self.detachRelation(db, removing: def)
                try Self.updateViews(db, database: def.databaseID) { state in
                    state.filter = state.filter.removingRules { $0.property == id }
                    state.sorts.removeAll { $0.property == id }
                    state.columns.removeAll { $0.property == id }
                    if state.groupBy == id { state.groupBy = nil }
                    if state.dateProperty == id { state.dateProperty = nil }
                }
                try db.run("DELETE FROM property_definitions WHERE id=?", [SQLValue(id)])
                let now = SystemClock().nowMillis()
                try Self.clearBrokenRollups(db, now: now)
                // Формулы, ссылавшиеся на свойство, получают ошибку «нет свойства», а не устаревшее значение (AT-18).
                let pages = Set(try db.query("SELECT id FROM pages WHERE database_id=?", [SQLValue(def.databaseID)]) { $0.uuid(0) }.compactMap { $0 })
                try Self.recalcRollups(db, touched: pages, properties: [id], now: now)
            }
        }
    }

    /// Сколько записей с непустым значением: подтверждение удаления называет реальное число.
    func valueCount(property: UUID) async throws -> Int {
        try await reader.run { db in
            let def = try Self.definition(db, property)
            if def.type.isComputed { return 0 }
            if def.type == .relation {
                // У двусторонней связи удаляется только эта сторона: строки остаются у парной.
                if def.config.pair != nil { return 0 }
                return Int(try db.scalarInt("""
                SELECT count(DISTINCT l.from_page) FROM relation_links l JOIN pages p ON p.id = l.from_page JOIN pages q ON q.id = l.to_page
                WHERE l.property_id=? AND p.deleted_at IS NULL AND q.deleted_at IS NULL
                """, [SQLValue(property)]) ?? 0)
            }
            if def.type == .files {
                return Int(try db.scalarInt("SELECT count(DISTINCT v.page_id) FROM property_value_assets v JOIN pages p ON p.id = v.page_id WHERE v.property_id=? AND p.deleted_at IS NULL", [SQLValue(property)]) ?? 0)
            }
            if def.type == .person {
                return Int(try db.scalarInt("SELECT count(DISTINCT v.page_id) FROM property_value_people v JOIN pages p ON p.id = v.page_id WHERE v.property_id=? AND p.deleted_at IS NULL", [SQLValue(property)]) ?? 0)
            }
            let plain = try db.scalarInt("SELECT count(*) FROM property_values v JOIN pages p ON p.id = v.page_id WHERE v.property_id=? AND p.deleted_at IS NULL", [SQLValue(property)]) ?? 0
            let options = try db.scalarInt("SELECT count(DISTINCT v.page_id) FROM property_value_options v JOIN pages p ON p.id = v.page_id WHERE v.property_id=? AND p.deleted_at IS NULL", [SQLValue(property)]) ?? 0
            return Int(plain + options)
        }
    }

    func valueCount(option: UUID) async throws -> Int {
        try await reader.run { db in
            Int(try db.scalarInt("SELECT count(*) FROM property_value_options v JOIN pages p ON p.id = v.page_id WHERE v.option_id=? AND p.deleted_at IS NULL", [SQLValue(option)]) ?? 0)
        }
    }

    private static func updateViews(_ db: SQLiteConnection, database: UUID, _ change: (inout DatabaseViewState) -> Void) throws {
        let views = try db.query("SELECT id, state_json FROM database_views WHERE database_id=?", [SQLValue(database)]) { ($0.uuid(0), $0.text(1)) }
        for (id, json) in views {
            guard let id else { continue }
            var state = DatabaseViewState(json: json)
            change(&state)
            try db.run("UPDATE database_views SET state_json=? WHERE id=?", [.text(try state.jsonString()), SQLValue(id)])
        }
    }

    // MARK: Варианты выбора

    func addOption(property: UUID, name: String, color: String?, id: UUID) async throws {
        try await writer.run { db in
            let last = try db.scalarText("SELECT sort_key FROM property_options WHERE property_id=? ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(property)])
            try db.run("INSERT INTO property_options(id, property_id, name, color, sort_key) VALUES(?,?,?,?,?)",
                       [SQLValue(id), SQLValue(property), .text(name), SQLValue(color), .text(SortKey.between(last, nil))])
        }
    }

    func updateOption(_ id: UUID, name: String, color: String?) async throws {
        try await writer.run { db in
            try db.transaction {
                let old = try db.scalarText("SELECT name FROM property_options WHERE id=?", [SQLValue(id)])
                try db.run("UPDATE property_options SET name=?, color=? WHERE id=?", [.text(name), SQLValue(color), SQLValue(id)])
                // «Показать значения» и счёт уникальных зависят от названий вариантов, а не от цвета.
                if old != name, let property = try db.query("SELECT property_id FROM property_options WHERE id=?", [SQLValue(id)], { $0.uuid(0) }).first ?? nil {
                    try Self.recalcDependents(db, of: property, now: SystemClock().nowMillis())
                }
            }
        }
    }

    /// Новый порядок вариантов; от него зависит сортировка по статусу.
    func reorderOptions(property: UUID, ordered: [UUID]) async throws {
        try await writer.run { db in
            try db.transaction {
                let keys = SortKey.keys(after: nil, before: nil, count: ordered.count)
                for (id, key) in zip(ordered, keys) {
                    try db.run("UPDATE property_options SET sort_key=? WHERE id=? AND property_id=?", [.text(key), SQLValue(id), SQLValue(property)])
                }
            }
        }
    }

    /// Удаляет вариант: его снимают с записей и убирают из фильтров, остальные варианты не меняются.
    func deleteOption(_ id: UUID) async throws {
        try await writer.run { db in
            try db.transaction {
                guard let property = try db.query("SELECT property_id FROM property_options WHERE id=?", [SQLValue(id)], { $0.uuid(0) }).first ?? nil else { return }
                let def = try Self.definition(db, property)
                let raw = id.uuidString
                try Self.updateViews(db, database: def.databaseID) { state in
                    state.filter = state.filter.removingRules { $0.property == property && $0.value.caseInsensitiveCompare(raw) == .orderedSame }
                }
                try db.run("DELETE FROM property_options WHERE id=?", [SQLValue(id)])
                try Self.recalcDependents(db, of: property, now: SystemClock().nowMillis())
            }
        }
    }

    // MARK: Смена типа

    private struct TypePlan {
        var preview = TypeChangePreview()
        var values: [(page: UUID, value: PropertyValue)] = []
        var options: [PropertyOption] = []
        var created: [PropertyOption] = []
    }

    private static let maxPreviewSamples = 8

    /// Один расчёт и для просмотра, и для применения: просмотр показывает ровно то, что случится.
    private static func plan(_ db: SQLiteConnection, def: PropertyDefinition, to type: PropertyType, zone: String, ids: IDGenerator) throws -> TypePlan {
        var out = TypePlan()
        out.options = def.options
        let pages = Array(Set(try db.query("""
        SELECT page_id FROM property_values WHERE property_id=? UNION SELECT page_id FROM property_value_options WHERE property_id=?
        """, [SQLValue(def.id), SQLValue(def.id)]) { $0.uuid(0) }.compactMap { $0 })).sorted { $0.uuidString < $1.uuidString }
        var lastKey = def.options.last?.sortKey
        for start in stride(from: 0, to: pages.count, by: 400) {
            let slice = Array(pages[start..<min(start + 400, pages.count)])
            let values = try loadValues(db, pages: slice, properties: [def])
            for page in slice {
                guard let value = values[page]?[def.id] else { continue }
                let text = PropertyConversion.text(of: value, options: def.options)
                let converted = PropertyConversion.convert(text, to: type, options: &out.options, zone: zone) { name in
                    let key = SortKey.between(lastKey, nil)
                    lastKey = key
                    let made = PropertyOption(id: ids.next(), name: name, color: nil, sortKey: key)
                    out.created.append(made)
                    return made
                }
                out.values.append((page, converted))
                out.preview.total += 1
                var failed = false
                if case .unconverted = converted { failed = true; out.preview.failed += 1 }
                if out.preview.samples.count < maxPreviewSamples {
                    out.preview.samples.append(.init(from: text, to: failed ? nil : PropertyConversion.text(of: converted, options: out.options)))
                }
            }
        }
        out.preview.newOptions = out.created.map(\.name)
        return out
    }

    /// Предварительный результат смены типа (FR-10). Ничего не записывает.
    func previewTypeChange(property: UUID, to type: PropertyType, zone: String) async throws -> TypeChangePreview {
        guard PropertyType.convertible.contains(type) else { throw Self.storageError("Этот тип свойства нельзя выбрать.") }
        return try await writer.run { db in
            try Self.plan(db, def: try Self.definition(db, property), to: type, zone: zone, ids: RandomIDs()).preview
        }
    }

    /// Меняет тип. Значение, которое нельзя преобразовать, остаётся текстом с пометкой и вернётся при обратной смене.
    func changePropertyType(_ property: UUID, to type: PropertyType, zone: String, ids: IDGenerator, now: Int64) async throws {
        guard PropertyType.convertible.contains(type) else { throw Self.storageError("Этот тип свойства нельзя выбрать.") }
        try await writer.run { db in
            try db.transaction {
                let def = try Self.definition(db, property)
                guard def.type != .title else { throw Self.storageError("У заголовка нельзя сменить тип.") }
                guard PropertyType.convertible.contains(def.type) else { throw Self.storageError("У этого свойства нельзя сменить тип.") }
                guard def.type != type else { return }
                let plan = try Self.plan(db, def: def, to: type, zone: zone, ids: ids)
                for option in plan.created {
                    try db.run("INSERT INTO property_options(id, property_id, name, color, sort_key) VALUES(?,?,?,?,?)",
                               [SQLValue(option.id), SQLValue(property), .text(option.name), SQLValue(option.color), .text(option.sortKey)])
                }
                try db.run("UPDATE property_definitions SET type=? WHERE id=?", [.text(type.rawValue), SQLValue(property)])
                var updated = def
                updated.type = type
                for (page, value) in plan.values { try Self.writeValue(db, page: page, def: updated, value: value, now: now) }
                // Правила прежнего типа утратили смысл: их значения записаны в другом формате.
                try Self.updateViews(db, database: def.databaseID) { state in
                    state.filter = state.filter.removingRules { $0.property == property }
                }
                try Self.recalcDependents(db, of: property, now: now)
            }
        }
    }

    // MARK: Представления

    func createView(database: UUID, name: String, kind: String, state: DatabaseViewState, id: UUID) async throws {
        let json = try state.jsonString()
        try await writer.run { db in
            let last = try db.scalarText("SELECT sort_key FROM database_views WHERE database_id=? ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(database)])
            try db.run("INSERT INTO database_views(id, database_id, name, kind, sort_key, state_json) VALUES(?,?,?,?,?,?)",
                       [SQLValue(id), SQLValue(database), .text(name), .text(kind), .text(SortKey.between(last, nil)), .text(json)])
        }
    }

    func renameView(_ id: UUID, to name: String) async throws {
        try await writer.run { try $0.run("UPDATE database_views SET name=? WHERE id=?", [.text(name), SQLValue(id)]) }
    }

    func saveViewState(_ id: UUID, _ state: DatabaseViewState) async throws {
        let json = try state.jsonString()
        try await writer.run { try $0.run("UPDATE database_views SET state_json=? WHERE id=?", [.text(json), SQLValue(id)]) }
    }

    /// Последнюю таблицу удалить нельзя: базе нечем было бы показать записи.
    func deleteView(_ id: UUID, database: UUID) async throws {
        try await writer.run { db in
            try db.transaction {
                let table = SQLValue(DatabaseView.tableKind)
                let others = try db.scalarInt("SELECT count(*) FROM database_views WHERE database_id=? AND kind=? AND id<>?", [SQLValue(database), table, SQLValue(id)]) ?? 0
                let isTable = try db.scalarInt("SELECT 1 FROM database_views WHERE id=? AND kind=?", [SQLValue(id), table]) != nil
                guard others > 0 || !isTable else { throw Self.storageError("Последнее представление нельзя удалить.") }
                try db.run("DELETE FROM database_views WHERE id=? AND database_id=?", [SQLValue(id), SQLValue(database)])
            }
        }
    }

    // MARK: Шаблоны

    func templates() async throws -> [PageTemplate] {
        try await reader.run { db in
            try db.query("SELECT id, name, root_page_id, database_id, created_at FROM templates ORDER BY created_at, id") { r -> PageTemplate? in
                guard let id = r.uuid(0), let root = r.uuid(2) else { return nil }
                return PageTemplate(id: id, name: r.text(1), rootPage: root, databaseID: r.uuid(3), createdAt: r.int(4))
            }.compactMap { $0 }
        }
    }

    /// Сохраняет страницу или запись как шаблон. Запись получает шаблон своей базы, со значениями свойств.
    func saveTemplate(from page: UUID, name: String, ids: IDGenerator, now: Int64) async throws -> PageTemplate {
        try await writer.run { db in
            try db.transaction {
                guard try db.scalarInt("SELECT 1 FROM databases WHERE page_id=?", [SQLValue(page)]) == nil else { throw Self.storageError("Базу нельзя сохранить как шаблон.") }
                let root = try Self.copySubtree(db, root: page, title: name, target: .hidden(now: now), ids: ids, now: now)
                let database = try db.query("SELECT database_id FROM pages WHERE id=?", [SQLValue(root)], { $0.uuid(0) }).first ?? nil
                let id = ids.next()
                try db.run("INSERT INTO templates(id, name, root_page_id, database_id, created_at) VALUES(?,?,?,?,?)",
                           [SQLValue(id), .text(name), SQLValue(root), SQLValue(database), .int(now)])
                return PageTemplate(id: id, name: name, rootPage: root, databaseID: database, createdAt: now)
            }
        }
    }

    /// Создаёт страницу из шаблона той же операцией, что и дублирование. Запись появляется в своей базе.
    func instantiate(template: UUID, parent: UUID?, ids: IDGenerator, now: Int64) async throws -> UUID {
        try await writer.run { db in
            try db.transaction {
                guard let row = try db.query("SELECT name, root_page_id, database_id FROM templates WHERE id=?", [SQLValue(template)], { (name: $0.text(0), root: $0.uuid(1), database: $0.uuid(2)) }).first, let root = row.root else {
                    throw Self.storageError("Шаблон не найден.")
                }
                var target = parent
                if let database = row.database {
                    guard let page = try db.query("SELECT d.page_id FROM databases d JOIN pages q ON q.id = d.page_id WHERE d.id=? AND q.deleted_at IS NULL", [SQLValue(database)], { $0.uuid(0) }).first ?? nil else {
                        throw Self.storageError("База недоступна.")
                    }
                    target = page
                }
                return try Self.copySubtree(db, root: root, title: row.name, target: .live(parent: target), ids: ids, now: now)
            }
        }
    }

    func renameTemplate(_ id: UUID, to name: String) async throws {
        try await writer.run { db in
            try db.transaction {
                guard let root = try db.query("SELECT root_page_id FROM templates WHERE id=?", [SQLValue(id)], { $0.uuid(0) }).first ?? nil else { return }
                try db.run("UPDATE templates SET name=? WHERE id=?", [.text(name), SQLValue(id)])
                try db.run("UPDATE pages SET title=? WHERE id=?", [.text(name), SQLValue(root)])
            }
        }
    }

    /// Шаблон удаляется вместе со скрытыми страницами; созданные из него страницы от него не зависят.
    func deleteTemplate(_ id: UUID) async throws {
        try await writer.run { db in
            try db.transaction {
                guard let root = try db.query("SELECT root_page_id FROM templates WHERE id=?", [SQLValue(id)], { $0.uuid(0) }).first ?? nil else { return }
                try Self.deleteHiddenSubtree(db, root: root)
            }
        }
    }

    private static func deleteHiddenSubtree(_ db: SQLiteConnection, root: UUID) throws {
        let pages = try db.query("""
        WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT p.id FROM pages p JOIN sub ON p.parent_id = sub.id WHERE p.deleted_at IS NOT NULL AND p.trash_batch_id IS NULL)
        SELECT id FROM sub
        """, [SQLValue(root)]) { $0.uuid(0) }.compactMap { $0 }
        for page in pages { try SearchIndex.removePage(db, page: page) }
        for page in pages { try db.run("DELETE FROM pages WHERE id=?", [SQLValue(page)]) }
    }

    /// Окончательное удаление базы забирает её шаблоны: без базы они бесполезны и остались бы скрытым мусором.
    static func deleteTemplates(_ db: SQLiteConnection, ofPagesInBatch batch: UUID) throws {
        let roots = try db.query("""
        SELECT t.root_page_id FROM templates t JOIN databases d ON d.id = t.database_id JOIN pages q ON q.id = d.page_id
        WHERE q.trash_batch_id = ? AND q.deleted_at IS NOT NULL
        """, [SQLValue(batch)]) { $0.uuid(0) }.compactMap { $0 }
        for root in roots { try deleteHiddenSubtree(db, root: root) }
    }

    // MARK: Дублирование

    /// Связи скопированных страниц (FR-12). Скопированное прямое свойство получает строки своих записей, внешние цели сохраняются.
    /// Копия записи без своей базы остаётся связанной с теми же записями с обеих сторон.
    /// Обратная сторона, ставшая самостоятельной, получает строки с обменом направлений.
    private static func copyRelationLinks(_ db: SQLiteConnection, pageMap: [UUID: UUID], propertyMap: [UUID: UUID], standalone: [UUID: UUID]) throws {
        let pages = Array(pageMap.keys)
        var seen = Set<String>()
        for start in stride(from: 0, to: pages.count, by: 400) {
            let slice = pages[start..<min(start + 400, pages.count)].map { SQLValue($0) }
            let marks = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = try db.query("SELECT from_page, property_id, to_page, sort_key FROM relation_links WHERE from_page IN (\(marks)) OR to_page IN (\(marks))", slice + slice) {
                (from: $0.uuid(0), property: $0.uuid(1), to: $0.uuid(2), key: $0.text(3))
            }
            for row in rows {
                guard let f = row.from, let p = row.property, let t = row.to, seen.insert("\(f)|\(p)|\(t)").inserted else { continue }
                let link: (UUID, UUID, UUID)
                if let copied = propertyMap[p] {
                    guard let nf = pageMap[f] else { continue }
                    link = (nf, copied, pageMap[t] ?? t)
                } else if let nt = pageMap[t], let own = standalone[p] {
                    link = (nt, own, f)
                } else {
                    link = (pageMap[f] ?? f, p, pageMap[t] ?? t)
                }
                try db.run("INSERT OR IGNORE INTO relation_links(from_page, property_id, to_page, sort_key) VALUES(?,?,?,?)",
                           [SQLValue(link.0), SQLValue(link.1), SQLValue(link.2), .text(row.key)])
            }
        }
    }

    /// Часть дублирования страниц: база в поддереве копируется целиком, копия записи остаётся в базе и сохраняет значения.
    static func duplicateDatabaseData(_ db: SQLiteConnection, pageMap: [UUID: UUID], ids: IDGenerator, now: Int64) throws {
        var databaseMap: [UUID: UUID] = [:], propertyMap: [UUID: UUID] = [:], optionMap: [UUID: UUID] = [:], viewMap: [UUID: UUID] = [:]
        var relationConfigs: [UUID: PropertyConfig] = [:], rollupConfigs: [UUID: PropertyConfig] = [:]
        for old in pageMap.keys {
            guard let id = try db.query("SELECT id FROM databases WHERE page_id=?", [SQLValue(old)], { $0.uuid(0) }).first ?? nil, let page = pageMap[old] else { continue }
            let copy = ids.next()
            databaseMap[id] = copy
            try db.run("INSERT INTO databases(id, page_id, created_at) VALUES(?,?,?)", [SQLValue(copy), SQLValue(page), .int(now)])
            let properties = try db.query("SELECT id, name, type, sort_key, config_json FROM property_definitions WHERE database_id=?", [SQLValue(id)]) {
                (id: $0.uuid(0), name: $0.text(1), type: $0.text(2), key: $0.text(3), config: $0.optText(4))
            }
            for p in properties {
                guard let pid = p.id else { continue }
                let np = ids.next()
                propertyMap[pid] = np
                if p.type == PropertyType.relation.rawValue { relationConfigs[np] = PropertyConfig(json: p.config) }
                if p.type == PropertyType.rollup.rawValue || p.type == PropertyType.formula.rawValue { rollupConfigs[np] = PropertyConfig(json: p.config) }
                try db.run("INSERT INTO property_definitions(id, database_id, name, type, sort_key, created_at, config_json) VALUES(?,?,?,?,?,?,?)",
                           [SQLValue(np), SQLValue(copy), .text(p.name), .text(p.type), .text(p.key), .int(now), SQLValue(p.config)])
                let options = try db.query("SELECT id, name, color, sort_key FROM property_options WHERE property_id=?", [SQLValue(pid)]) { (id: $0.uuid(0), name: $0.text(1), color: $0.optText(2), key: $0.text(3)) }
                for o in options {
                    guard let oid = o.id else { continue }
                    let no = ids.next()
                    optionMap[oid] = no
                    try db.run("INSERT INTO property_options(id, property_id, name, color, sort_key) VALUES(?,?,?,?,?)", [SQLValue(no), SQLValue(np), .text(o.name), SQLValue(o.color), .text(o.key)])
                }
            }
            let views = try db.query("SELECT name, kind, sort_key, state_json, id FROM database_views WHERE database_id=?", [SQLValue(id)]) { (name: $0.text(0), kind: $0.text(1), key: $0.text(2), json: $0.text(3), id: $0.uuid(4)) }
            for v in views {
                let newView = ids.next()
                if let old = v.id { viewMap[old] = newView }
                var json = v.json
                for (from, to) in propertyMap.merging(optionMap, uniquingKeysWith: { a, _ in a }) {
                    // В JSON идентификаторы записаны кодировщиком UUID — прописными буквами.
                    json = json.replacingOccurrences(of: from.uuidString, with: to.uuidString)
                }
                try db.run("INSERT INTO database_views(id, database_id, name, kind, sort_key, state_json) VALUES(?,?,?,?,?,?)",
                           [SQLValue(newView), SQLValue(copy), .text(v.name), .text(v.kind), .text(v.key), .text(json)])
            }
        }
        // Связь копии смотрит на копию цели, если цель скопирована. Пара вне копии не получает второй обратной стороны:
        // копия становится односторонней связью.
        var standalone: [UUID: UUID] = [:] // прямое свойство вне копии → скопированная обратная сторона, ставшая самостоятельной
        for (copyID, old) in relationConfigs {
            var config = old
            config.target = old.target.map { databaseMap[$0] ?? $0 }
            if let pair = old.pair, let mapped = propertyMap[pair] {
                config.pair = mapped
            } else {
                if old.isBackSide, let pair = old.pair { standalone[pair] = copyID }
                config.pair = nil
                config.isBackSide = false
            }
            try db.run("UPDATE property_definitions SET config_json=? WHERE id=?", [.text(try config.jsonString()), SQLValue(copyID)])
        }
        try copyRelationLinks(db, pageMap: pageMap, propertyMap: propertyMap, standalone: standalone)
        // Свёртка копии смотрит на связь копии; свойство цели — на копию, если цель скопирована.
        for (copyID, old) in rollupConfigs {
            var config = old
            config.rollupRelation = old.rollupRelation.map { propertyMap[$0] ?? $0 }
            config.rollupProperty = old.rollupProperty.map { propertyMap[$0] ?? $0 }
            // Формула копии ссылается на свойства копии: ID в тексте заменяются.
            if let text = old.formula {
                config.formula = propertyMap.reduce(text) { $0.replacingOccurrences(of: $1.key.uuidString, with: $1.value.uuidString) }
            }
            try db.run("UPDATE property_definitions SET config_json=? WHERE id=?", [.text(try config.jsonString()), SQLValue(copyID)])
        }

        // Встроенные представления хранят ID свойств и вариантов: у копии базы они свои.
        let idMap = propertyMap.merging(optionMap, uniquingKeysWith: { a, _ in a })
        if !idMap.isEmpty {
            for new in pageMap.values {
                let embedded = try db.query("SELECT id, content_json FROM blocks WHERE page_id=? AND type=?", [SQLValue(new), .text(BlockType.databaseView.rawValue)]) { ($0.uuid(0), $0.text(1)) }
                for (block, json) in embedded {
                    var updated = json
                    for (from, to) in idMap { updated = updated.replacingOccurrences(of: from.uuidString, with: to.uuidString) }
                    if updated != json { try db.run("UPDATE blocks SET content_json=? WHERE id=?", [.text(updated), SQLValue(block)]) }
                }
            }
        }
        for (old, new) in pageMap {
            guard let source = try db.query("SELECT database_id FROM pages WHERE id=?", [SQLValue(old)], { $0.uuid(0) }).first ?? nil else { continue }
            try db.run("UPDATE pages SET database_id=? WHERE id=?", [SQLValue(databaseMap[source] ?? source), SQLValue(new)])
            let values = try db.query("""
            SELECT property_id, value_text, value_num, value_date, value_date_end, value_ts, value_ts_end, value_tz, unconverted FROM property_values WHERE page_id=?
            """, [SQLValue(old)]) { r -> [SQLValue] in
                [SQLValue(r.uuid(0).map { propertyMap[$0] ?? $0 }), SQLValue(r.optText(1)), r.isNull(2) ? .null : .real(r.real(2)), SQLValue(r.optText(3)), SQLValue(r.optText(4)),
                 SQLValue(r.optInt(5)), SQLValue(r.optInt(6)), SQLValue(r.optText(7)), SQLValue(r.optText(8))]
            }
            for row in values {
                try db.run("""
                INSERT INTO property_values(page_id, property_id, value_text, value_num, value_date, value_date_end, value_ts, value_ts_end, value_tz, unconverted, updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """, [SQLValue(new)] + row + [.int(now)])
            }
            // Люди — из общего справочника: копия ссылается на тех же людей.
            // Файлы неизменяемы: копия ссылается на те же вложения.
            let files = try db.query("SELECT property_id, asset_id, sort_key FROM property_value_assets WHERE page_id=?", [SQLValue(old)]) { ($0.uuid(0), $0.uuid(1), $0.text(2)) }
            for (property, asset, key) in files {
                guard let property, let asset else { continue }
                try db.run("INSERT INTO property_value_assets(page_id, property_id, asset_id, sort_key) VALUES(?,?,?,?)",
                           [SQLValue(new), SQLValue(propertyMap[property] ?? property), SQLValue(asset), .text(key)])
            }
            let people = try db.query("SELECT property_id, person_id, sort_key FROM property_value_people WHERE page_id=?", [SQLValue(old)]) { ($0.uuid(0), $0.uuid(1), $0.text(2)) }
            for (property, person, key) in people {
                guard let property, let person else { continue }
                try db.run("INSERT INTO property_value_people(page_id, property_id, person_id, sort_key) VALUES(?,?,?,?)",
                           [SQLValue(new), SQLValue(propertyMap[property] ?? property), SQLValue(person), .text(key)])
            }
            let chosen = try db.query("SELECT property_id, option_id FROM property_value_options WHERE page_id=?", [SQLValue(old)]) { ($0.uuid(0), $0.uuid(1)) }
            for (property, option) in chosen {
                guard let property, let option else { continue }
                try db.run("INSERT INTO property_value_options(page_id, property_id, option_id) VALUES(?,?,?)",
                           [SQLValue(new), SQLValue(propertyMap[property] ?? property), SQLValue(optionMap[option] ?? option)])
            }
        }
        // Ручной порядок копии: те же места у скопированных записей.
        for (oldView, newView) in viewMap {
            let rows = try db.query("SELECT page_id, sort_key FROM view_record_order WHERE view_id=?", [SQLValue(oldView)]) { ($0.uuid(0), $0.text(1)) }
            for (page, key) in rows {
                guard let page, let copied = pageMap[page] else { continue }
                try db.run("INSERT OR IGNORE INTO view_record_order(view_id, page_id, sort_key) VALUES(?,?,?)", [SQLValue(newView), SQLValue(copied), .text(key)])
            }
        }
    }
}
