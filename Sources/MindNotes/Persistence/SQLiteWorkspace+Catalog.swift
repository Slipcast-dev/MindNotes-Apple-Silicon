import Foundation

extension SQLiteWorkspace {
    /// Устанавливает шаблон каталога: страницы, базы, связи, свёртки, формулы, виды и примеры записей.
    /// Шаги идут через обычные операции хранилища, поэтому результат ничем не отличается от собранного руками.
    /// Если шаг не удался, всё созданное уходит в корзину одной пачкой: половины шаблона в пространстве не остаётся.
    /// Возвращает страницу, которую стоит открыть: общую страницу или единственную базу.
    func install(_ template: CatalogTemplate, today: LocalDate, now: Int64) async throws -> UUID {
        let problems = CatalogValidation.problems(template)
        guard problems.isEmpty else { throw WorkspaceError.corrupted("шаблон «\(template.title)»: " + problems.joined(separator: "; ")) }
        var created: [UUID] = []
        do {
            return try await installSteps(template, today: today, now: now, created: &created)
        } catch {
            let batch = UUID()
            for page in created.reversed() { try? await trashPage(page, batch: batch, now: now) }
            throw error
        }
    }

    private func installSteps(_ template: CatalogTemplate, today: LocalDate, now: Int64, created: inout [UUID]) async throws -> UUID {
        var parent: UUID?
        if let rootTitle = template.rootTitle {
            let root = try await createPage(parent: nil, title: rootTitle, id: UUID(), now: now)
            created.append(root.id)
            try await setPageIcon(root.id, icon: template.icon)
            parent = root.id
        }

        // 1. Базы с обычными свойствами и вариантами.
        var bases: [String: UUID] = [:]
        for spec in template.databases {
            let status = spec.properties.first { if case .choice(.status, _) = $0.kind { return true } else { return false } }
            let date = spec.properties.first { if case .plain(.date) = $0.kind { return true } else { return false } }
            var statusOptions: [CatalogOption] = []
            if case .choice(_, let options)? = status?.kind { statusOptions = options }
            let new = NewDatabase(title: spec.title, titleProperty: spec.titleProperty,
                                  statusProperty: status?.name ?? "status·tmp", statusOptions: statusOptions.map(\.name),
                                  dateProperty: date?.name ?? "date·tmp", viewName: "view·tmp",
                                  extraViews: spec.views.map { ($0.name, $0.kind) })
            // Первый вид новой базы всегда таблица: виды из описания идут следом, а временный убирается.
            let base = try await createDatabase(parent: parent, template: new, ids: RandomIDs(), now: now)
            if let temporary = base.views.first(where: { $0.name == "view·tmp" }) { try await deleteView(temporary.id, database: base.id) }
            if parent == nil { created.append(base.pageID) }
            bases[spec.key] = base.id
            try await setPageIcon(base.pageID, icon: spec.icon ?? (template.databases.count == 1 ? template.icon : nil))
            // Свойства по умолчанию, которых нет в описании, убираются.
            for def in base.properties where def.type == .status && status == nil || def.type == .date && date == nil {
                try await deleteProperty(def.id)
            }
            for property in spec.properties {
                switch property.kind {
                case .plain(let type):
                    if type == .date, property.name == date?.name { continue }
                    try await addProperty(database: base.id, name: property.name, type: type, id: UUID(), now: now)
                case .choice(let type, let options):
                    if type == .status, property.name == status?.name, let existing = base.properties.first(where: { $0.type == .status }) {
                        // Варианты статуса уже созданы вместе с базой: остаётся раскрасить их.
                        for option in existing.options {
                            if let color = options.first(where: { $0.name == option.name })?.color {
                                try await updateOption(option.id, name: option.name, color: color)
                            }
                        }
                        continue
                    }
                    let id = UUID()
                    try await addProperty(database: base.id, name: property.name, type: type, id: id, now: now)
                    for option in options { try await addOption(property: id, name: option.name, color: option.color, id: UUID()) }
                case .formula, .rollup:
                    continue
                }
            }
        }

        // 2. Связи между базами.
        for relation in template.relations {
            guard let from = bases[relation.from], let to = bases[relation.to] else { continue }
            try await addRelation(database: from, name: relation.name, target: to, twoWay: true, pairName: relation.pairName,
                                  id: UUID(), pairID: UUID(), now: now)
        }

        // 3. Записи и их значения; связи — когда записи всех баз уже есть.
        var records: [String: UUID] = [:]
        for spec in template.databases {
            guard let base = bases[spec.key] else { continue }
            for record in spec.records {
                let id = UUID()
                try await createRecord(database: base, title: record.title, id: id, now: now)
                if let icon = record.icon { try await setPageIcon(id, icon: icon) }
                records[record.key] = id
            }
        }
        for spec in template.databases {
            guard let baseID = bases[spec.key], let base = try await database(baseID) else { continue }
            for record in spec.records {
                guard let page = records[record.key] else { continue }
                for (name, value) in record.values.sorted(by: { $0.key < $1.key }) {
                    guard let def = base.properties.first(where: { $0.name == name }),
                          let converted = Self.catalogValue(value, def: def, today: today, records: records) else { continue }
                    try await setValue(pages: [page], property: def.id, value: converted, now: now)
                }
            }
        }

        // 4. Формулы и свёртки: им нужны свойства, связи и значения.
        for spec in template.databases {
            guard let baseID = bases[spec.key] else { continue }
            for property in spec.properties {
                switch property.kind {
                case .formula(let source):
                    try await addFormula(database: baseID, name: property.name, source: source, id: UUID(), now: now)
                case .rollup(let relationName, let targetName, let aggregate):
                    guard let base = try await database(baseID),
                          let relation = base.properties.first(where: { $0.name == relationName && $0.type == .relation }),
                          let targetID = relation.config.target, let target = try await database(targetID),
                          let source = target.properties.first(where: { $0.name == targetName }) else {
                        throw WorkspaceError.corrupted("свёртка «\(property.name)»: нет связи или свойства")
                    }
                    try await addRollup(database: baseID, name: property.name, relation: relation.id, property: source.id,
                                        aggregate: aggregate, id: UUID(), now: now)
                default:
                    continue
                }
            }
        }

        // 5. Виды: группировка, дата, скрытые свойства, итоги и сортировка — по свежей базе со всеми свойствами.
        for spec in template.databases {
            guard let baseID = bases[spec.key], let base = try await database(baseID) else { continue }
            func id(_ name: String?) -> UUID? { name.flatMap { n in base.properties.first { $0.name == n }?.id } }
            for view in spec.views {
                guard let stored = base.views.first(where: { $0.name == view.name && $0.kind == view.kind }) else { continue }
                var state = stored.state
                state.groupBy = id(view.groupBy)
                state.dateProperty = id(view.dateProperty)
                state.sorts = view.sorts.compactMap { s in id(s.property).map { SortRule(property: $0, descending: s.descending) } }
                state.showTimelineTable = view.showTimelineTable
                state.hideEmptyGroups = view.hideEmptyGroups
                var columns = state.orderedColumns(base.properties)
                for i in columns.indices {
                    let name = base.property(columns[i].property)?.name ?? ""
                    if view.hidden.contains(name) { columns[i].visible = false }
                    columns[i].calculation = view.calculations[name]
                }
                state.columns = columns
                try await saveViewState(stored.id, state)
            }
        }

        if let parent { return parent }
        guard let only = template.databases.first.flatMap({ bases[$0.key] }), let base = try await database(only) else {
            throw WorkspaceError.corrupted("шаблон не создан")
        }
        return base.pageID
    }

    /// Значение из описания в значение свойства; несовместимое с типом пропускается.
    static func catalogValue(_ value: CatalogValue, def: PropertyDefinition, today: LocalDate, records: [String: UUID]) -> PropertyValue? {
        switch value {
        case .text(let s): return def.type == .text ? .text(s) : nil
        case .number(let n): return def.type == .number ? .number(n) : nil
        case .checkbox(let b): return def.type == .checkbox ? .checkbox(b) : nil
        case .url(let s): return def.type == .url ? .url(s) : nil
        case .option(let name):
            guard def.type.usesOptions, let option = def.options.first(where: { $0.name == name }) else { return nil }
            return .options([option.id])
        case .options(let names):
            guard def.type.usesOptions else { return nil }
            let ids = names.compactMap { n in def.options.first { $0.name == n }?.id }
            return ids.isEmpty ? nil : .options(ids)
        case .day(let offset, let end):
            guard def.type == .date else { return nil }
            return .date(DateValue(start: .day(today.adding(days: offset)), end: end.map { .day(today.adding(days: $0)) }))
        case .relation(let keys):
            guard def.type == .relation else { return nil }
            let links = keys.compactMap { records[$0] }.map { LinkedPage(id: $0, title: "") }
            return links.isEmpty ? nil : .relation(links)
        }
    }
}
