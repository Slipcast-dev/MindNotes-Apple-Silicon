import Foundation

/// Вырезка из браузера в новую страницу (ADR-0019). Путь тот же, что у импорта: страница появляется целиком одним
/// пакетом, картинки становятся управляемыми вложениями, ссылки — только безопасные.
enum ClipImport {
    /// Блоки страницы: карточка источника, заметка пользователя, затем содержимое.
    /// `assets` — вложения по имени из `WebClip.images`; картинка без вложения остаётся подписью.
    static func fragments(for clip: WebClip, assets: [String: AssetRecord]) -> [BlockFragment] {
        var out: [BlockFragment] = []
        if let url = clip.url {
            out.append(AtomData.bookmark(url: url, title: clip.title, description: clip.excerpt))
        }
        if let note = clip.note {
            out.append(BlockFragment(type: .callout, content: BlockContent(text: note)))
        }
        switch clip.mode {
        case .screenshot, .image:
            for image in clip.images { if let asset = assets[image.name] { out.append(AtomData.attachment(type: .image, asset: asset)) } }
            if !clip.markdown.isEmpty { out += body(clip.markdown, assets: assets) }
        case .article, .selection, .bookmark:
            out += body(clip.markdown, assets: assets)
        }
        return out
    }

    /// Ссылки вида [[…]] из чужого текста не становятся ссылками на свои страницы: остаётся текст.
    private static func body(_ markdown: String, assets: [String: AssetRecord]) -> [BlockFragment] {
        MarkdownImport.fragments(from: markdown, image: { _, path in
            assets[path].map { AtomData.attachment(type: .image, asset: $0) }
        }, link: { href in href.hasPrefix("wiki:") ? nil : MarkdownImport.safeLink(href) })
    }

    /// Создаёт страницу под `parent` (nil — верхний уровень). Файлы картинок пишутся во временную папку и копируются
    /// в пространство; временная папка удаляется в любом случае.
    static func run(_ clip: WebClip, into target: ImportTarget, parent: UUID?, ids: IDGenerator, now: Int64) async throws -> Page {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mn-clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var assets: [String: AssetRecord] = [:]
        for image in clip.images {
            let file = temp.appendingPathComponent(image.name)
            try image.data.write(to: file, options: .atomic)
            assets[image.name] = try await target.addAsset(copying: file, id: ids.next(), now: now)
        }
        let page = try await target.createPage(parent: parent, title: clip.title, id: ids.next(), now: now)
        try await FolderImport.commit(fragments(for: clip, assets: assets), to: page.id, target: target, ids: ids, now: now)
        return page
    }
}
