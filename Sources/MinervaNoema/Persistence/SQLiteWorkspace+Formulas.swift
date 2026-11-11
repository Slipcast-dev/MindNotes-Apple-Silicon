import Foundation

/// Формулы (FR-13): результат хранится готовым, как у свёрток, и пересчитывается по зависимостям в транзакции правки.
/// Ошибка вычисления пишется в `calc_error` записи: ячейка показывает её, данные не страдают.
extension SQLiteWorkspace {
    /// Формула с разобранным текстом. Если текст не проверяется (свойство удалено, тип сменился), `compiled` — ошибка.
    struct LiveFormula {
        var def: PropertyDefinition
        var compiled: Result<CompiledFormula, FormulaError>
        /// Свойства из текста, даже если формула сейчас не проверяется: их правка должна её пересчитать.
        var dependencies: Set<UUID>
        var usesToday: Bool
    }

    /// Результат предварительного просмотра для редактора.
    struct FormulaPreview: Equatable {
        var type: FormulaType?
        var error: FormulaError?
        var samples: [(title: String, value: String)] = []

        static func == (a: FormulaPreview, b: FormulaPreview) -> Bool {
            a.type == b.type && a.error == b.error && a.samples.map(\.title) == b.samples.map(\.title) && a.samples.map(\.value) == b.samples.map(\.value)
        }
    }

    private static func formulaError(_ key: String, _ args: CVarArg...) -> WorkspaceError {
        .storage(code: 0, detail: String(format: NSLocalizedString(key, comment: ""), arguments: args))
    }

    // MARK: Разбор

    /// ID свойств, на которые ссылается сохранённый текст.
    static func referencedIDs(_ stored: String) -> Set<UUID> {
        var out: Set<UUID> = []
        _ = try? FormulaReferences.rewrite(stored) { arg in
            if let id = UUID(uuidString: arg) { out.insert(id) }
            return nil
        }
        return out
    }

    private static func usesToday(_ node: FormulaNode) -> Bool {
        switch node {
        case .call("today", _, _): return true
        case .call(_, let args, _): return args.contains(where: usesToday)
        case .unary(_, let e, _): return usesToday(e)
        case .binary(_, let a, let b, _): return usesToday(a) || usesToday(b)
        default: return false
        }
    }

    /// Проверка сохранённой формулы по текущим свойствам базы.
    static func liveFormula(_ def: PropertyDefinition, properties: [PropertyDefinition]) -> LiveFormula {
        let stored = def.config.formula ?? ""
        let deps = referencedIDs(stored)
        let result = Result<CompiledFormula, Error> {
            guard deps.allSatisfy({ id in properties.contains { $0.id == id } }) else {
                throw FormulaError("Свойство, на которое ссылается формула, удалено. Откройте формулу и исправьте её.", at: 0..<0)
            }
            let compiled = try CompiledFormula.compile(stored) { arg in
                guard let id = UUID(uuidString: arg), let p = properties.first(where: { $0.id == id }) else { return nil }
                return (p.id, FormulaType.of(p))
            }
            // Тип результата сохранён вместе с формулой: от него зависят хранение и фильтры.
            guard compiled.type == def.config.formulaType else {
                throw FormulaError("Тип результата изменился: откройте формулу и сохраните её заново.", at: 0..<0)
            }
            return compiled
        }.mapError { ($0 as? FormulaError) ?? FormulaError("Формула не проверяется.", at: 0..<0) }
        let today = (try? result.get()).map { usesToday($0.node) } ?? false
        return LiveFormula(def: def, compiled: result, dependencies: deps, usesToday: today)
    }

    static func allFormulas(_ db: SQLiteConnection) throws -> [LiveFormula] {
        let rows = try db.query("SELECT DISTINCT database_id FROM property_definitions WHERE type=?", [.text(PropertyType.formula.rawValue)]) { $0.uuid(0) }
        var out: [LiveFormula] = []
        for case let base? in rows {
            guard let database = try loadDatabase(db, base) else { continue }
            for def in database.properties where def.type == .formula {
                out.append(liveFormula(def, properties: database.properties))
            }
        }
        return out
    }

    // MARK: Вычисление

    /// Вычисление на потоке с большим стеком: рекурсивный обход дерева не зависит от стека очереди записи.
    /// Внутри — только чистое вычисление, без обращения к базе.
    static func onLargeStack<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = body()
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        done.wait()
        return result!
    }

    static func propertyValue(_ value: FormulaValue) -> PropertyValue? {
        switch value {
        case .number(let n): return .number(n)
        case .text(let s): return s.isEmpty ? nil : .text(s)
        case .bool(let b): return .checkbox(b)
        case .date(let d): return .date(d)
        case .empty: return nil
        }
    }

    static func today(_ now: Int64) -> LocalDate { LocalDate(date: Date(timeIntervalSince1970: Double(now) / 1000), in: .current) }

    /// Входы формулы для записей: значения свойств-зависимостей и заголовок.
    private static func inputs(_ db: SQLiteConnection, pages: [UUID], dependencies: [PropertyDefinition]) throws -> [UUID: [UUID: FormulaValue]] {
        var out: [UUID: [UUID: FormulaValue]] = [:]
        let plain = dependencies.filter { $0.type != .title }
        let values = try loadValues(db, pages: pages, properties: plain)
        let title = dependencies.first { $0.type == .title }
        var titles: [UUID: String] = [:]
        if title != nil {
            let marks = Array(repeating: "?", count: pages.count).joined(separator: ",")
            _ = try db.query("SELECT id, title FROM pages WHERE id IN (\(marks))", pages.map { SQLValue($0) }) { r in
                if let id = r.uuid(0) { titles[id] = r.text(1) }
            }
        }
        for page in pages {
            var row: [UUID: FormulaValue] = [:]
            for def in plain { row[def.id] = FormulaValue.from(values[page]?[def.id], property: def) }
            if let title { row[title.id] = (titles[page] ?? "").isEmpty ? .empty : .text(titles[page] ?? "") }
            out[page] = row
        }
        return out
    }

    static func recomputeFormula(_ db: SQLiteConnection, _ f: LiveFormula, pages: [UUID], properties: [PropertyDefinition], now: Int64) throws {
        let deps = properties.filter { f.dependencies.contains($0.id) }
        let day = today(now)
        for start in stride(from: 0, to: pages.count, by: 400) {
            let part = Array(pages[start..<min(start + 400, pages.count)])
            switch f.compiled {
            case .failure(let error):
                for page in part { try storeComputed(db, page: page, property: f.def.id, value: .error(error.message), now: now) }
            case .success(let compiled):
                let rows = try inputs(db, pages: part, dependencies: deps)
                let results: [PropertyValue?] = onLargeStack {
                    part.map { page in
                        do {
                            let value = try FormulaEvaluator.evaluate(compiled, context: FormulaContext(values: rows[page] ?? [:], today: day))
                            return propertyValue(value)
                        } catch {
                            return .error((error as? FormulaError)?.message ?? "\(error)")
                        }
                    }
                }
                for (page, value) in zip(part, results) { try storeComputed(db, page: page, property: f.def.id, value: value, now: now) }
            }
        }
    }

    static func recomputeFormulaFully(_ db: SQLiteConnection, _ f: LiveFormula, now: Int64) throws -> Set<UUID> {
        guard let database = try loadDatabase(db, f.def.databaseID) else { return [] }
        let pages = try db.query("SELECT id FROM pages WHERE database_id=?", [SQLValue(f.def.databaseID)]) { $0.uuid(0) }.compactMap { $0 }
        try recomputeFormula(db, f, pages: pages, properties: database.properties, now: now)
        return Set(pages)
    }

    // MARK: Зависимости и циклы

    /// От чего зависит свойство: формула — от свойств в тексте, свёртка — от связи и свойства связанных записей.
    static func dependencyEdges(_ db: SQLiteConnection) -> (UUID) -> Set<UUID> {
        var cache: [UUID: Set<UUID>] = [:]
        return { id in
            if let known = cache[id] { return known }
            var out: Set<UUID> = []
            if let def = try? definition(db, id) {
                switch def.type {
                case .formula: out = referencedIDs(def.config.formula ?? "")
                case .rollup: out = Set([def.config.rollupRelation, def.config.rollupProperty].compactMap { $0 })
                default: break
                }
            }
            cache[id] = out
            return out
        }
    }

    /// Цикл через свойство: ошибка с понятным путём «Итог → Сумма → Итог» (AT-18).
    static func checkNoCycle(_ db: SQLiteConnection, through property: UUID) throws {
        guard let path = DependencyGraph.cycle(from: property, edges: dependencyEdges(db)) else { return }
        let names = path.map { (try? definition(db, $0).name) ?? "?" }
        throw formulaError("Циклическая зависимость: %@. Формула не сохранена.", names.joined(separator: " → "))
    }

    // MARK: Создание и изменение

    /// Текст пользователя (имена) → проверенная формула и текст для хранения (ID).
    private static func prepare(_ source: String, properties: [PropertyDefinition], excluding own: UUID?) throws -> (compiled: CompiledFormula, stored: String) {
        let usable = properties.filter { $0.id != own }
        var byName: [String: PropertyDefinition] = [:]
        for p in usable where byName[p.name] == nil { byName[p.name] = p }
        let compiled = try CompiledFormula.compile(source) { name in byName[name].map { ($0.id, FormulaType.of($0)) } }
        let stored = try FormulaReferences.toStorage(source, names: byName.mapValues(\.id))
        return (compiled, stored)
    }

    /// Предпросмотр: проверка текста и результат на первых записях. Ничего не записывает.
    func previewFormula(database: UUID, source: String, editing: UUID?, limit: Int = 3) async throws -> FormulaPreview {
        let now = clock.nowMillis()
        return try await writer.run { db in
            guard let base = try Self.loadDatabase(db, database) else { throw Self.formulaError("База недоступна.") }
            let prepared: (compiled: CompiledFormula, stored: String)
            do { prepared = try Self.prepare(source, properties: base.properties, excluding: editing) } catch let e as FormulaError {
                return FormulaPreview(type: nil, error: e)
            }
            if let editing {
                // Цикл проверяется так, будто новый текст уже сохранён.
                let edges = Self.dependencyEdges(db)
                let deps = Self.referencedIDs(prepared.stored)
                if let path = DependencyGraph.cycle(from: editing, edges: { $0 == editing ? deps : edges($0) }) {
                    let names = path.map { (try? Self.definition(db, $0).name) ?? "?" }
                    let message = String(format: NSLocalizedString("Циклическая зависимость: %@. Формула не сохранена.", comment: ""), names.joined(separator: " → "))
                    return FormulaPreview(type: prepared.compiled.type, error: FormulaError(message: message, range: 0..<0))
                }
            }
            let pages = try db.query("SELECT id, title FROM pages WHERE database_id=? AND deleted_at IS NULL ORDER BY sort_key, id LIMIT ?",
                                     [SQLValue(database), .int(Int64(limit))]) { (id: $0.uuid(0), title: $0.text(1)) }
            let ids = pages.compactMap(\.id)
            let deps = base.properties.filter { prepared.compiled.dependencies.contains($0.id) }
            let rows = try Self.inputs(db, pages: ids, dependencies: deps)
            let day = Self.today(now)
            let compiled = prepared.compiled
            let values: [String] = Self.onLargeStack {
                ids.map { id in
                    do {
                        let v = try FormulaEvaluator.evaluate(compiled, context: FormulaContext(values: rows[id] ?? [:], today: day))
                        return FormulaEvaluator(context: FormulaContext(values: [:], today: day)).display(v)
                    } catch { return "⚠︎ " + ((error as? FormulaError)?.message ?? "\(error)") }
                }
            }
            return FormulaPreview(type: compiled.type, error: nil, samples: zip(pages, values).map { ($0.title, $1) })
        }
    }

    /// Текст формулы для редактора: ID заменены текущими именами.
    func formulaDisplayText(_ property: PropertyDefinition, in database: Database) -> String {
        let names = Dictionary(database.properties.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Удалённое свойство показывается словами, а не внутренним ID: проверка укажет на него как на неизвестное.
        let missing = NSLocalizedString("удалённое свойство", comment: "")
        return (try? FormulaReferences.rewrite(property.config.formula ?? "") { arg in
            UUID(uuidString: arg).map { names[$0] ?? missing }
        }) ?? (property.config.formula ?? "")
    }

    /// Новая формула: проверяется, сохраняется и сразу считается для всех записей одной транзакцией.
    func addFormula(database: UUID, name: String, source: String, id: UUID, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                guard let base = try Self.loadDatabase(db, database) else { throw Self.formulaError("База недоступна.") }
                let prepared = try Self.prepare(source, properties: base.properties, excluding: nil)
                var config = PropertyConfig()
                config.formula = prepared.stored
                config.formulaType = prepared.compiled.type
                let last = try db.scalarText("SELECT sort_key FROM property_definitions WHERE database_id=? ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(database)])
                try db.run("INSERT INTO property_definitions(id, database_id, name, type, sort_key, created_at, config_json) VALUES(?,?,?,?,?,?,?)",
                           [SQLValue(id), SQLValue(database), .text(name), .text(PropertyType.formula.rawValue), .text(SortKey.between(last, nil)), .int(now), .text(try config.jsonString())])
                try Self.checkNoCycle(db, through: id)
                guard let fresh = try Self.loadDatabase(db, database), let def = fresh.property(id) else { return }
                _ = try Self.recomputeFormulaFully(db, Self.liveFormula(def, properties: fresh.properties), now: now)
            }
        }
    }

    /// Новый текст формулы. Цикл отклоняет правку целиком; зависимые свёртки и формулы пересчитываются.
    func updateFormula(_ id: UUID, source: String, now: Int64) async throws {
        try await writer.run { db in
            try db.transaction {
                let def = try Self.definition(db, id)
                guard def.type == .formula, let base = try Self.loadDatabase(db, def.databaseID) else { throw Self.formulaError("Это свойство нельзя изменить здесь.") }
                let prepared = try Self.prepare(source, properties: base.properties, excluding: id)
                var config = def.config
                config.formula = prepared.stored
                config.formulaType = prepared.compiled.type
                try db.run("UPDATE property_definitions SET config_json=? WHERE id=?", [.text(try config.jsonString()), SQLValue(id)])
                try Self.checkNoCycle(db, through: id)
                guard let fresh = try Self.loadDatabase(db, def.databaseID), let updated = fresh.property(id) else { return }
                let pages = try Self.recomputeFormulaFully(db, Self.liveFormula(updated, properties: fresh.properties), now: now)
                try Self.clearBrokenRollups(db, now: now)
                try Self.recalcRollups(db, touched: pages, properties: [id], now: now)
            }
        }
    }

    /// Формулы с `today()`: раз в день, при открытии пространства и при смене даты. Возвращает, был ли пересчёт.
    @discardableResult
    func refreshDailyFormulas() async throws -> Bool {
        let now = clock.nowMillis()
        let day = Self.today(now).iso
        return try await writer.run { db in
            try db.transaction {
                guard try db.scalarText("SELECT value FROM workspace_meta WHERE key='formula_day'") != day else { return false }
                var touched: Set<UUID> = [], changed: Set<UUID> = []
                for f in try Self.allFormulas(db) where f.usesToday {
                    touched.formUnion(try Self.recomputeFormulaFully(db, f, now: now))
                    changed.insert(f.def.id)
                }
                if !changed.isEmpty { try Self.recalcRollups(db, touched: touched, properties: changed, now: now) }
                try db.run("INSERT INTO workspace_meta(key, value) VALUES('formula_day', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(day)])
                return true
            }
        }
    }
}
