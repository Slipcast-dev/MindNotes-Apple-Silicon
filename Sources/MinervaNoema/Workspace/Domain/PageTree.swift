import Foundation

/// Дерево страниц для боковой панели, собранное заранее.
/// Панель обращается к дереву при каждой перерисовке, а проход по всему списку на каждую строку
/// на десятках тысяч страниц останавливал главный поток. Порядок детей совпадает с порядком исходного списка.
struct PageTree {
    /// Видимая строка дерева: панель показывает плоский список, чтобы строить только строки на экране.
    struct Row: Identifiable, Equatable {
        let page: Page
        let depth: Int
        let hasChildren: Bool
        var id: UUID { page.id }
    }

    private let roots: [Page]
    private let byParent: [UUID: [Page]]
    private let byID: [UUID: Page]

    /// `byID` содержит и скрытые страницы: заголовок записи нужен, хотя в дереве её нет.
    init(pages: [Page] = [], excluding isHidden: (Page) -> Bool = { _ in false }) {
        var roots: [Page] = []
        var byParent: [UUID: [Page]] = [:]
        var byID: [UUID: Page] = [:]
        byID.reserveCapacity(pages.count)
        for page in pages {
            byID[page.id] = page
            if isHidden(page) { continue }
            if let parent = page.parentID {
                byParent[parent, default: []].append(page)
            } else {
                roots.append(page)
            }
        }
        self.roots = roots
        self.byParent = byParent
        self.byID = byID
    }

    func page(_ id: UUID) -> Page? { byID[id] }

    func children(of parent: UUID?) -> [Page] {
        guard let parent else { return roots }
        return byParent[parent] ?? []
    }

    /// Строки в порядке обхода; дети свёрнутых страниц пропускаются.
    func rows(collapsed: Set<UUID> = []) -> [Row] {
        var out: [Row] = []
        var stack: [(page: Page, depth: Int)] = roots.reversed().map { ($0, 0) }
        while let (page, depth) = stack.popLast() {
            let kids = byParent[page.id] ?? []
            out.append(Row(page: page, depth: depth, hasChildren: !kids.isEmpty))
            if !collapsed.contains(page.id) {
                stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) })
            }
        }
        return out
    }

    /// Сама страница и все её потомки: перемещать страницу в них нельзя.
    func subtree(of id: UUID) -> Set<UUID> {
        var out: Set<UUID> = []
        var stack = [id]
        while let current = stack.popLast() {
            guard out.insert(current).inserted else { continue }
            stack.append(contentsOf: (byParent[current] ?? []).map(\.id))
        }
        return out
    }

    /// Предки от корня к странице. Обход ограничен на случай повреждённых данных с циклом.
    func path(of id: UUID) -> [Page] {
        var out: [Page] = []
        var seen: Set<UUID> = [id]
        var current = byID[id]?.parentID
        while let parent = current, seen.insert(parent).inserted, let page = byID[parent] {
            out.insert(page, at: 0)
            current = page.parentID
        }
        return out
    }
}
