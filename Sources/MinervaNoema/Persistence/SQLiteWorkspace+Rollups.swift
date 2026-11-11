import Foundation

/// Свёртки: значение хранится готовым в `property_values` и пересчитывается по зависимостям (FR-13),
/// поэтому фильтры и сортировка работают в SQL так же, как у обычных свойств.
/// Пересчёт идёт в той же транзакции, что и правка: незаконченного состояния не бывает.
extension SQLiteWorkspace {
    /// Действующая свёртка: связь своей базы, свойство связанных записей и агрегат.
    struct LiveRollup {
        var def: PropertyDefinition
        var relation: PropertyDefinition
        var target: PropertyDefinition
        var aggregate: RollupAggregate
    }

    private static let chunk = 400

    private static func chunks<T>(_ items: [T]) -> [ArraySlice<T>] {
        stride(from: 0, to: items.count, by: chunk).map { items[$0..<min($0 + chunk, items.count)] }
    }

    private static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    /// Есть ли вычисляемые свойства (свёртки или формулы): иначе пересчёт не нужен вовсе.
    static func hasRollups(_ db: SQLiteConnection) throws -> Bool {
        try db.scalarInt("SELECT 1 FROM property_definitions WHERE type IN (?, ?) LIMIT 1", [.text(PropertyType.rollup.rawValue), .text(PropertyType.formula.rawValue)]) != nil
    }

    /// Свойства «Изменено» баз этих записей: правка записи меняет их значение.
    static func editedStamps(_ db: SQLiteConnection, pages: Set<UUID>) throws -> Set<UUID> {
        guard !pages.isEmpty, try hasRollups(db) else { return [] }
        var out: Set<UUID> = []
        for part in chunks(Array(pages)) {
            let sql = "SELECT DISTINCT d.id FROM property_definitions d JOIN pages p ON p.database_id = d.database_id WHERE d.type = ? AND p.id IN (" + marks(part.count) + ")"
            for id in try db.query(sql, [.text(PropertyType.editedTime.rawValue)] + part.map { SQLValue($0) }, { $0.uuid(0) }) {
                if let id { out.insert(id) }
            }
        }
        return out
    }

    /// Проверка настроек свёртки. nil — источник удалён или больше не подходит: значения такой свёртки очищаются.
    static func resolveRollup(_ db: SQLiteConnection, _ def: PropertyDefinition) -> LiveRollup? {
        guard def.type == .rollup, let relationID = def.config.rollupRelation, let propertyID = def.config.rollupProperty,
              let aggregate = def.config.aggregate,
              let relation = try? definition(db, relationID), relation.type == .relation, relation.databaseID == def.databaseID,
              let targetBase = relation.config.target,
              let target = try? definition(db, propertyID), target.databaseID == targetBase, target.type != .editedTime,
              RollupAggregate.available(for: target.valueType).contains(aggregate) else { return nil }
        return LiveRollup(def: def, relation: relation, target: target, aggregate: aggregate)
    }

    private static func allRollups(_ db: SQLiteConnection) throws -> [PropertyDefinition] {
        try db.query("SELECT id FROM property_definitions WHERE type=?", [.text(PropertyType.rollup.rawValue)]) { $0.uuid(0) }
            .compactMap { $0 }.compactMap { try? definition(db, $0) }
    }

    /// Длина цепочки «свёртка свёртки»: защита от бесконечного пересчёта при повреждённых настройках.
    static func chainLength(_ db: SQLiteConnection, from property: UUID) throws -> Int {
        var length = 0, current = property, seen: Set<UUID> = []
        while let def = try? definition(db, current), def.type == .rollup, let next = def.config.rollupProperty {
            guard seen.insert(current).inserted else { return Int.max }
            length += 1
            if length > RollupLimits.maxChain { return length }
            current = next
        }
        return length
    }

    /// Записи, связанные с данными любой связью в любую сторону, включая скрытые.
    static func neighbors(_ db: SQLiteConnection, of pages: Set<UUID>) throws -> Set<UUID> {
        var out: Set<UUID> = []
        for part in chunks(Array(pages)) {
            let args = part.map { SQLValue($0) }
            let m = marks(part.count)
            for id in try db.query("SELECT to_page FROM relation_links WHERE from_page IN (\(m)) UNION SELECT from_page FROM relation_links WHERE to_page IN (\(m))", args + args, { $0.uuid(0) }) {
                if let id { out.insert(id) }
            }
        }
        return out
    }

    /// Пересчёт всего, что зависит от изменения. `touched` — записи, чьи значения, заголовки или связи изменились;
    /// `properties` — какие свойства изменились (nil — неизвестно, проверяются все свёртки).
    /// Пересчитанные свёртки сами становятся изменением следующего шага: так проходит цепочка «свёртка свёртки».
    static func recalcRollups(_ db: SQLiteConnection, touched start: Set<UUID>, properties start2: Set<UUID>?, now: Int64) throws {
        guard !start.isEmpty, try hasRollups(db) else { return }
        let all = try allRollups(db)
        let formulas = try allFormulas(db)
        var databaseProperties: [UUID: [PropertyDefinition]] = [:]
        for f in formulas where databaseProperties[f.def.databaseID] == nil {
            databaseProperties[f.def.databaseID] = try loadDatabase(db, f.def.databaseID)?.properties ?? []
        }
        // Настройки проверяются один раз на пересчёт и только у свёрток, которых изменение может касаться.
        var resolved: [UUID: LiveRollup?] = [:]
        func live(_ def: PropertyDefinition) -> LiveRollup? {
            if let known = resolved[def.id] { return known }
            let r = resolveRollup(db, def)
            resolved[def.id] = r
            return r
        }
        var touched = start, changed = start2
        for _ in 0..<RollupLimits.maxChain {
            var next: Set<UUID> = [], nextProps: Set<UUID> = []
            for def in all {
                if let changed {
                    let relation = def.config.rollupRelation, source = def.config.rollupProperty
                    guard relation.map(changed.contains) == true || source.map(changed.contains) == true else { continue }
                }
                guard let r = live(def) else { continue }
                let scope = try scope(db, r, touched: touched)
                guard !scope.isEmpty else { continue }
                try recompute(db, r, pages: Array(scope), now: now)
                next.formUnion(scope)
                nextProps.insert(r.def.id)
            }
            // Формулы зависят только от свойств своей записи: пересчитываются затронутые записи своей базы.
            for f in formulas {
                if let changed, f.dependencies.isDisjoint(with: changed) { continue }
                var scope: [UUID] = []
                for part in chunks(Array(touched)) {
                    scope += try db.query("SELECT id FROM pages WHERE database_id=? AND id IN (" + marks(part.count) + ")",
                                          [SQLValue(f.def.databaseID)] + part.map { SQLValue($0) }) { $0.uuid(0) }.compactMap { $0 }
                }
                guard !scope.isEmpty else { continue }
                try recomputeFormula(db, f, pages: scope, properties: databaseProperties[f.def.databaseID] ?? [], now: now)
                next.formUnion(scope)
                nextProps.insert(f.def.id)
            }
            if next.isEmpty { return }
            touched = next
            changed = nextProps
        }
    }

    /// Записи базы свёртки, на которые влияет изменение: сами затронутые записи этой базы и связанные с затронутыми.
    private static func scope(_ db: SQLiteConnection, _ r: LiveRollup, touched: Set<UUID>) throws -> Set<UUID> {
        let (mine, other) = r.relation.config.isBackSide ? ("to_page", "from_page") : ("from_page", "to_page")
        var out: Set<UUID> = []
        for part in chunks(Array(touched)) {
            let args = part.map { SQLValue($0) }
            let m = marks(part.count)
            for id in try db.query("SELECT id FROM pages WHERE database_id=? AND id IN (\(m))", [SQLValue(r.def.databaseID)] + args, { $0.uuid(0) }) {
                if let id { out.insert(id) }
            }
            for id in try db.query("SELECT \(mine) FROM relation_links WHERE property_id=? AND \(other) IN (\(m))", [SQLValue(r.relation.linkOwner)] + args, { $0.uuid(0) }) {
                if let id { out.insert(id) }
            }
        }
        return out
    }

    /// Все записи базы: после создания свёртки или изменения её источника.
    static func recomputeAll(_ db: SQLiteConnection, _ r: LiveRollup, now: Int64) throws -> Set<UUID> {
        let pages = try db.query("SELECT id FROM pages WHERE database_id=?", [SQLValue(r.def.databaseID)]) { $0.uuid(0) }.compactMap { $0 }
        try recompute(db, r, pages: pages, now: now)
        return Set(pages)
    }

    private static func recompute(_ db: SQLiteConnection, _ r: LiveRollup, pages: [UUID], now: Int64) throws {
        let (mine, other) = r.relation.config.isBackSide ? ("to_page", "from_page") : ("from_page", "to_page")
        for part in chunks(pages) {
            var linked: [UUID: [UUID]] = [:]
            _ = try db.query("""
            SELECT l.\(mine), l.\(other) FROM relation_links l JOIN pages q ON q.id = l.\(other)
            WHERE l.property_id=? AND l.\(mine) IN (\(marks(part.count))) AND q.deleted_at IS NULL ORDER BY l.sort_key, q.id
            """, [SQLValue(r.relation.linkOwner)] + part.map { SQLValue($0) }) { row in
                if let a = row.uuid(0), let b = row.uuid(1) { linked[a, default: []].append(b) }
            }
            let targets = Array(Set(linked.values.joined()))
            var values: [UUID: PropertyValue] = [:]
            for t in chunks(targets) {
                if r.target.type == .title {
                    _ = try db.query("SELECT id, title FROM pages WHERE id IN (\(marks(t.count)))", t.map { SQLValue($0) }) { row in
                        if let id = row.uuid(0) { values[id] = .text(row.text(1)) }
                    }
                } else {
                    for (page, byProperty) in try loadValues(db, pages: Array(t), properties: [r.target]) {
                        if let v = byProperty[r.target.id] { values[page] = v }
                    }
                }
            }
            for page in part {
                let list = (linked[page] ?? []).map { values[$0] }
                let result = RollupMath.compute(r.aggregate, values: list, options: r.target.options)
                try storeComputed(db, page: page, property: r.def.id, value: result, now: now)
            }
        }
    }

    static func storeComputed(_ db: SQLiteConnection, page: UUID, property: UUID, value: PropertyValue?, now: Int64) throws {
        try db.run("DELETE FROM property_values WHERE page_id=? AND property_id=?", [SQLValue(page), SQLValue(property)])
        guard let value else { return }
        var text: String?, num: Double?, date: String?, dateEnd: String?, ts: Int64?, tsEnd: Int64?, tz: String?, error: String?
        switch value {
        case .number(let n): num = n
        case .checkbox(let b): num = b ? 1 : 0
        case .error(let message): error = message
        case .text(let s): text = s
        case .date(let d):
            date = d.start.localText
            dateEnd = d.end?.localText
            if case .moment(let ms, let zone) = d.start { ts = ms; tz = zone }
            if case .moment(let ms, _)? = d.end { tsEnd = ms }
        default: return
        }
        try db.run("""
        INSERT INTO property_values(page_id, property_id, value_text, value_num, value_date, value_date_end, value_ts, value_ts_end, value_tz, unconverted, calc_error, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,NULL,?,?)
        """, [SQLValue(page), SQLValue(property), SQLValue(text), num.map { .real($0) } ?? .null, SQLValue(date), SQLValue(dateEnd),
              SQLValue(ts), SQLValue(tsEnd), SQLValue(tz), SQLValue(error), .int(now)])
    }

    /// Свёртки, чей источник пропал или больше не подходит, теряют значения: устаревшее число хуже пустой ячейки.
    /// Возвращает очищенные свёртки, чтобы пересчитать то, что от них зависит.
    @discardableResult
    static func clearBrokenRollups(_ db: SQLiteConnection, now: Int64) throws -> Set<UUID> {
        guard try hasRollups(db) else { return [] }
        var cleared: Set<UUID> = []
        // Незнакомый агрегат из более новой версии — не поломка: его значения не трогаются.
        for def in try allRollups(db) where def.config.aggregate?.resultType != nil && resolveRollup(db, def) == nil {
            try db.run("DELETE FROM property_values WHERE property_id=?", [SQLValue(def.id)])
            if db.changes > 0 { cleared.insert(def.id) }
        }
        if !cleared.isEmpty {
            let pages = Set(try db.query("SELECT DISTINCT p.id FROM pages p JOIN property_definitions d ON d.database_id = p.database_id WHERE d.id IN (\(marks(cleared.count)))",
                                         cleared.map { SQLValue($0) }) { $0.uuid(0) }.compactMap { $0 })
            try recalcRollups(db, touched: pages, properties: cleared, now: now)
        }
        return cleared
    }

    /// После изменения источника (тип свойства, варианты) пересчитываются все свёртки, которые на него смотрят.
    static func recalcDependents(_ db: SQLiteConnection, of property: UUID, now: Int64) throws {
        guard try hasRollups(db) else { return }
        let rollupUses = try allRollups(db).contains { $0.config.rollupProperty == property }
        let formulaUses = try allFormulas(db).contains { $0.dependencies.contains(property) }
        guard rollupUses || formulaUses else { return }
        try clearBrokenRollups(db, now: now)
        guard let def = try? definition(db, property) else { return }
        let pages = Set(try db.query("SELECT id FROM pages WHERE database_id=?", [SQLValue(def.databaseID)]) { $0.uuid(0) }.compactMap { $0 })
        try recalcRollups(db, touched: pages, properties: [property], now: now)
    }

    // MARK: Создание

    /// Свёртка по связи `relation` этой базы: агрегат свойства `property` связанных записей.
    /// Значения считаются сразу для всех записей той же транзакцией.
    func addRollup(database: UUID, name: String, relation: UUID, property: UUID, aggregate: RollupAggregate, id: UUID, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                let last = try db.scalarText("SELECT sort_key FROM property_definitions WHERE database_id=? ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(database)])
                let config = PropertyConfig.rollup(relation: relation, property: property, aggregate: aggregate)
                try db.run("INSERT INTO property_definitions(id, database_id, name, type, sort_key, created_at, config_json) VALUES(?,?,?,?,?,?,?)",
                           [SQLValue(id), SQLValue(database), .text(name), .text(PropertyType.rollup.rawValue), .text(SortKey.between(last, nil)), .int(now), .text(try config.jsonString())])
                guard let rollup = Self.resolveRollup(db, try Self.definition(db, id)) else {
                    throw WorkspaceError.storage(code: 0, detail: NSLocalizedString("Свёртку нельзя построить по этим свойствам.", comment: ""))
                }
                guard try Self.chainLength(db, from: id) <= RollupLimits.maxChain else {
                    throw WorkspaceError.storage(code: 0, detail: NSLocalizedString("Слишком длинная цепочка свёрток.", comment: ""))
                }
                // Через формулы свёртка может замкнуться на себя.
                try Self.checkNoCycle(db, through: id)
                _ = try Self.recomputeAll(db, rollup, now: now)
            }
        }
    }
}
