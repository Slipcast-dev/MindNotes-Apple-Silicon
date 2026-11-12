import Foundation

/// Вырезки из браузера (плагин WebClipper, ADR-0019): куда можно сохранять и сама запись.
extension ShellModel {
    struct ClipTarget {
        var id: UUID
        var title: String
        var path: String
        var isFolder: Bool
    }

    /// Папка по умолчанию на верхнем уровне; создаётся при первой вырезке.
    static var clipFolderTitle: String { L("Из браузера") }

    /// Обычные страницы и папки: без баз, записей и всего, что под паролем (ADR-0017).
    func clipTargets() -> [ClipTarget] {
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ page: Page) -> String {
            var names: [String] = [], seen: Set<UUID> = [], current: Page? = page
            while let p = current, !seen.contains(p.id), names.count < 12 {
                seen.insert(p.id)
                names.insert(p.title.isEmpty ? L("Без названия") : p.title, at: 0)
                current = p.parentID.flatMap { byID[$0] }
            }
            return names.joined(separator: " / ")
        }
        return pages.filter(isClipTarget).map { ClipTarget(id: $0.id, title: $0.title, path: path($0), isFolder: $0.isFolder) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func isClipTarget(_ page: Page) -> Bool {
        page.deletedAt == nil && page.databaseID == nil && !isDatabase(page.id) && !isProtected(page.id)
    }

    enum ClipFailure: Error {
        case noWorkspace
        case badParent
        case failed(String)
    }

    /// Новая страница из вырезки. Запись встаёт в общую очередь оболочки: открытая страница сохраняется как обычно.
    func saveClip(_ clip: WebClip) async -> Result<Page, ClipFailure> {
        await withCheckedContinuation { (done: CheckedContinuation<Result<Page, ClipFailure>, Never>) in
            enqueue {
                guard let store = self.store else { done.resume(returning: .failure(.noWorkspace)); return }
                do {
                    let now = SystemClock().nowMillis()
                    let parent: UUID
                    if let wanted = clip.parent {
                        guard let page = self.pages.first(where: { $0.id == wanted }), self.isClipTarget(page) else {
                            done.resume(returning: .failure(.badParent)); return
                        }
                        parent = wanted
                    } else {
                        parent = try await self.defaultClipFolder(store, now: now)
                    }
                    let page = try await ClipImport.run(clip, into: store, parent: parent, ids: RandomIDs(), now: now)
                    for name in clip.tags {
                        let tag = try await store.createTag(name: name, color: nil, now: now)
                        try await store.setTag(tag.id, on: page.id, true)
                    }
                    try await self.refreshAfterExternalWrite()
                    self.notice = String(format: L("Сохранено из браузера: «%@»"), page.title)
                    done.resume(returning: .success(page))
                } catch {
                    done.resume(returning: .failure(.failed(Self.describe(error))))
                }
            }
        }
    }

    private func defaultClipFolder(_ store: SQLiteWorkspace, now: Int64) async throws -> UUID {
        if let found = pages.first(where: { $0.parentID == nil && $0.isFolder && $0.title == Self.clipFolderTitle && isClipTarget($0) }) {
            return found.id
        }
        var folder = try await store.createPage(parent: nil, title: Self.clipFolderTitle, id: UUID(), now: now)
        folder.icon = Page.folderIcon
        try await store.updatePage(folder)
        try await refreshAfterExternalWrite()
        return folder.id
    }
}
