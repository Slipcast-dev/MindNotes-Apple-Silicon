import Foundation

/// Готовый шаблон из каталога: страница с одной или несколькими базами, их свойствами, видами и примерами записей.
/// Описание хранится в коде приложения, а не в пространстве; установка создаёт обычные страницы и базы,
/// которые дальше ничем не отличаются от созданных вручную. Ссылки внутри описания — по именам и ключам.
struct CatalogTemplate: Identifiable {
    enum Category: String, CaseIterable {
        case personal, work, projects, study
    }

    var id: String
    var category: Category
    var title: String
    var detail: String
    var icon: String
    /// Общая страница, внутри которой лежат базы; nil — единственная база создаётся на верхнем уровне.
    var rootTitle: String?
    var databases: [CatalogDatabase]
    /// Связи между базами создаются после самих баз и до свёрток.
    var relations: [CatalogRelation] = []
}

struct CatalogDatabase {
    /// Ключ базы внутри шаблона: на него ссылаются связи.
    var key: String
    var title: String
    var icon: String?
    /// Имя свойства-заголовка.
    var titleProperty: String
    /// Свойства в порядке показа; свёртки и формулы — после обычных свойств и связей.
    var properties: [CatalogProperty]
    /// Первый вид — основной; видов не меньше одного.
    var views: [CatalogView]
    var records: [CatalogRecord] = []
}

struct CatalogOption: Equatable {
    var name: String
    /// Имя цвета палитры: gray, brown, orange, yellow, green, blue, purple, pink, red.
    var color: String?
}

struct CatalogProperty {
    enum Kind {
        case plain(PropertyType)
        case choice(PropertyType, [CatalogOption])
        /// Текст формулы со ссылками `prop("Имя")` на свойства этой базы.
        case formula(String)
        /// Свёртка по связи `relation` этой базы над свойством `property` связанной базы.
        case rollup(relation: String, property: String, aggregate: RollupAggregate)
    }

    var name: String
    var kind: Kind

    static func plain(_ name: String, _ type: PropertyType) -> CatalogProperty { CatalogProperty(name: name, kind: .plain(type)) }
    static func choice(_ name: String, _ type: PropertyType, _ options: [CatalogOption]) -> CatalogProperty {
        CatalogProperty(name: name, kind: .choice(type, options))
    }
    static func formula(_ name: String, _ source: String) -> CatalogProperty { CatalogProperty(name: name, kind: .formula(source)) }
    static func rollup(_ name: String, relation: String, property: String, _ aggregate: RollupAggregate) -> CatalogProperty {
        CatalogProperty(name: name, kind: .rollup(relation: relation, property: property, aggregate: aggregate))
    }

    var isComputed: Bool {
        switch kind {
        case .formula, .rollup: return true
        default: return false
        }
    }
}

struct CatalogRelation {
    var from: String
    var name: String
    var to: String
    var pairName: String
}

struct CatalogView {
    var name: String
    var kind: String
    var groupBy: String?
    var dateProperty: String?
    /// Свойства, скрытые в этом виде.
    var hidden: [String] = []
    /// Итоги под столбцами таблицы.
    var calculations: [String: RollupAggregate] = [:]
    var sorts: [(property: String, descending: Bool)] = []
    var showTimelineTable = false
    var hideEmptyGroups = false
}

struct CatalogRecord {
    /// Ключ записи: на него ссылаются значения связей.
    var key: String
    var title: String
    var icon: String?
    var values: [String: CatalogValue] = [:]
}

enum CatalogValue {
    case text(String)
    case number(Double)
    case checkbox(Bool)
    case url(String)
    /// Вариант выбора или статуса по имени.
    case option(String)
    case options([String])
    /// День относительно дня установки; `end` — конец диапазона, тоже относительно.
    case day(Int, end: Int? = nil)
    /// Записи другой (или этой же) базы по ключам.
    case relation([String])
}

/// Проверка описания до установки: ошибка в каталоге не должна оставить в пространстве половину шаблона.
enum CatalogValidation {
    static func problems(_ template: CatalogTemplate) -> [String] {
        var out: [String] = []
        let keys = Set(template.databases.map(\.key))
        if keys.count != template.databases.count { out.append("повторяется ключ базы") }
        if template.databases.isEmpty { out.append("нет баз") }
        if template.databases.count > 1, template.rootTitle == nil { out.append("несколько баз без общей страницы") }
        var relationNames: [String: Set<String>] = [:]
        for r in template.relations {
            if !keys.contains(r.from) || !keys.contains(r.to) { out.append("связь «\(r.name)» ссылается на неизвестную базу") }
            relationNames[r.from, default: []].insert(r.name)
            relationNames[r.to, default: []].insert(r.pairName)
        }
        let allRecords = Set(template.databases.flatMap { $0.records.map(\.key) })
        for db in template.databases {
            if db.views.isEmpty { out.append("у базы «\(db.title)» нет видов") }
            var names = Set([db.titleProperty])
            for p in db.properties {
                if names.contains(p.name) { out.append("в базе «\(db.title)» повторяется свойство «\(p.name)»") }
                names.insert(p.name)
            }
            let known = names.union(relationNames[db.key] ?? [])
            for p in db.properties {
                if case .rollup(let relation, _, _) = p.kind, !(relationNames[db.key] ?? []).contains(relation) {
                    out.append("свёртка «\(p.name)» ссылается на неизвестную связь «\(relation)»")
                }
            }
            for v in db.views {
                for name in [v.groupBy, v.dateProperty].compactMap({ $0 }) + v.hidden + Array(v.calculations.keys) + v.sorts.map(\.property)
                where !known.contains(name) {
                    out.append("вид «\(v.name)» базы «\(db.title)» ссылается на неизвестное свойство «\(name)»")
                }
            }
            for r in db.records {
                for (name, value) in r.values {
                    if !known.contains(name) { out.append("запись «\(r.title)» задаёт неизвестное свойство «\(name)»") }
                    if case .relation(let targets) = value {
                        for t in targets where !allRecords.contains(t) { out.append("запись «\(r.title)» ссылается на неизвестную запись «\(t)»") }
                    }
                }
            }
        }
        return out
    }
}
