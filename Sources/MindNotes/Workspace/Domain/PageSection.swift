import Foundation

/// Свой раздел боковой панели (как «Страницы»), хранится в пространстве.
struct PageSection: Equatable, Identifiable {
    var id: UUID
    var name: String
    var sortKey: String

    static let maxName = 60

    /// Имя без пробелов по краям и не длиннее предела; пустое — nil.
    static func clean(_ name: String) -> String? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxName))
    }
}

/// Место в списке разделов боковой панели: стандартный раздел «Страницы» или свой.
enum SectionSlot: Hashable {
    case pages
    case custom(UUID)

    /// Порядок показа: свои разделы по ключу, «Страницы» — на сохранённой позиции (вне пределов — в край).
    static func order(_ sections: [PageSection], pagesIndex: Int) -> [SectionSlot] {
        var list = sections.map { SectionSlot.custom($0.id) }
        list.insert(.pages, at: min(max(0, pagesIndex), list.count))
        return list
    }

    /// Раздел перенесли на место `target`: сверху вниз он встаёт после цели, снизу вверх — перед ней.
    static func move(_ order: [SectionSlot], _ moving: SectionSlot, onto target: SectionSlot) -> [SectionSlot] {
        guard moving != target, let from = order.firstIndex(of: moving), let to = order.firstIndex(of: target) else { return order }
        var list = order
        list.remove(at: from)
        let index = list.firstIndex(of: target)! + (from < to ? 1 : 0)
        list.insert(moving, at: index)
        return list
    }

    /// Свой раздел, после которого `moving` стоит среди своих разделов (nil — первым); для записи в хранилище.
    static func customPredecessor(of moving: UUID, in order: [SectionSlot]) -> UUID? {
        var previous: UUID?
        for slot in order {
            guard case .custom(let id) = slot else { continue }
            if id == moving { return previous }
            previous = id
        }
        return previous
    }
}

extension SectionSlot {
    /// ID своего раздела; у «Страниц» — nil, как в хранилище.
    var sectionID: UUID? { if case .custom(let id) = self { return id } else { return nil } }
}
