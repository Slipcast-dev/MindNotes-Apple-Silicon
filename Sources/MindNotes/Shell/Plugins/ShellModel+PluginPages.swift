import Foundation

/// Чтение страниц плагином (разрешение `pages.read`, ADR-0019, п. 12): список, текст в Markdown и вложения.
/// Закрытые паролем страницы и всё под ними плагину не видны, даже если замок сейчас открыт.
extension ShellModel {
    struct ReadablePage {
        var id: UUID
        var parentID: UUID?
        var title: String
        var path: String
        var isFolder: Bool
        var updatedAt: Int64
        var contentRev: Int64
    }

    struct PageMarkdown {
        var page: ReadablePage
        var markdown: String
        var assets: [(id: UUID, path: String)]
        var report: [(reason: String, count: Int)]
    }

    enum PageReadFailure: Error {
        case noWorkspace
        case notFound
        case tooLarge
        case failed(String)
    }

    /// Обычные страницы и папки: без баз и их записей (в Markdown они не выражаются целиком) и без закрытых паролем.
    func isPluginReadable(_ page: Page) -> Bool {
        page.deletedAt == nil && page.databaseID == nil && !isDatabase(page.id) && !isProtected(page.id)
    }

    func readablePages() -> [ReadablePage] {
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return pages.filter(isPluginReadable).map { page in
            var names: [String] = [], seen: Set<UUID> = [], current: Page? = page
            while let p = current, !seen.contains(p.id), names.count < 12 {
                seen.insert(p.id)
                names.insert(p.title.isEmpty ? L("Без названия") : p.title, at: 0)
                current = p.parentID.flatMap { byID[$0] }
            }
            // Родитель, которого плагин не видит (база, закрытая страница), не называется: страница — от корня.
            let parent = page.parentID.flatMap { byID[$0] }.flatMap { isPluginReadable($0) ? $0.id : nil }
            return ReadablePage(id: page.id, parentID: parent, title: page.title, path: names.joined(separator: " / "),
                                isFolder: page.isFolder, updatedAt: page.updatedAt, contentRev: page.contentRev)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Текст страницы тем же экспортом, что «Экспорт в Markdown». Сначала записываются все подтверждённые правки.
    /// Ссылки на страницы, которые плагин не видит, остаются без названия.
    func pluginMarkdown(_ id: UUID, assetFolder: String) async -> Result<PageMarkdown, PageReadFailure> {
        await withCheckedContinuation { (done: CheckedContinuation<Result<PageMarkdown, PageReadFailure>, Never>) in
            enqueue {
                guard let store = self.store, self.isOpen else { done.resume(returning: .failure(.noWorkspace)); return }
                guard let page = self.pages.first(where: { $0.id == id }), self.isPluginReadable(page),
                      let readable = self.readablePages().first(where: { $0.id == id }) else {
                    done.resume(returning: .failure(.notFound)); return
                }
                do {
                    try await self.flushForPlugin()
                    let blocks = BlockDocument(pageID: id, blocks: try await store.blocks(ofPage: id)).blocks
                    let result = MarkdownExport.export(title: page.title, blocks: blocks, assetFolder: assetFolder) { other in
                        guard let target = self.pages.first(where: { $0.id == other }), self.isPluginReadable(target) else { return nil }
                        return target.title
                    }
                    // Свежие время и номер правки: flush мог записать изменения после чтения списка.
                    var fresh = readable
                    if let updated = try await store.page(id) { fresh.updatedAt = updated.updatedAt; fresh.contentRev = updated.contentRev }
                    done.resume(returning: .success(PageMarkdown(page: fresh, markdown: result.markdown, assets: result.assets,
                                                                 report: result.report.map { (L($0.reason), $0.count) })))
                } catch {
                    done.resume(returning: .failure(.failed(Self.describe(error))))
                }
            }
        }
    }

    /// Вложение отдаётся, только если оно есть в тексте этой страницы: так плагин не прочитает чужой файл по id.
    func pluginAsset(page id: UUID, asset: UUID) async -> Result<Data, PageReadFailure> {
        switch await pluginMarkdown(id, assetFolder: "files") {
        case .failure(let failure): return .failure(failure)
        case .success(let page):
            guard page.assets.contains(where: { $0.id == asset }) else { return .failure(.notFound) }
        }
        guard let store else { return .failure(.noWorkspace) }
        do {
            guard let url = try await store.assetURL(asset), FileManager.default.fileExists(atPath: url.path) else { return .failure(.notFound) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= LocalAPI.maxAssetBytes else { return .failure(.tooLarge) }
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure(.failed(Self.describe(error)))
        }
    }
}
