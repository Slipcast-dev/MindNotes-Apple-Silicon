import Foundation

/// Поисковый индекс и ссылки. Обновляется в транзакции записи; ошибка откатывает правку вместе с ним.
enum SearchIndex {
    // Строка индекса адресуется rowid: столбцы page_id и block_id не индексируются, и удаление по ним сканировало бы весь индекс.
    // Блок: rowid его строки в blocks. Заголовок страницы: отрицательный rowid страницы.

    private static func insert(_ db: SQLiteConnection, rowid: Int64, page: UUID, block: UUID?, text: String) throws {
        try db.run("INSERT INTO search_index(rowid, page_id, block_id, text) VALUES(?,?,?,?)",
                   [.int(rowid), SQLValue(page), block.map { SQLValue($0) } ?? .text(""), .text(SearchText.normalize(text))])
    }

    static func updateBlock(_ db: SQLiteConnection, id: UUID, page: UUID, text: String, targets: Set<UUID>) throws {
        guard let rowid = try db.scalarInt("SELECT rowid FROM blocks WHERE id=?", [SQLValue(id)]) else { return }
        try db.run("DELETE FROM search_index WHERE rowid=?", [.int(rowid)])
        if !text.isEmpty { try insert(db, rowid: rowid, page: page, block: id, text: text) }
        try db.run("DELETE FROM page_links WHERE block_id=?", [SQLValue(id)])
        for target in targets {
            try db.run("INSERT OR IGNORE INTO page_links(block_id, from_page, to_page) VALUES(?,?,?)", [SQLValue(id), SQLValue(page), SQLValue(target)])
        }
    }

    /// Вызывается до удаления блока. Потомки уйдут каскадом, поэтому их строки убираются здесь же.
    static func removeBlock(_ db: SQLiteConnection, id: UUID) throws {
        let rowids = try db.query("""
        WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT b.id FROM blocks b JOIN sub ON b.parent_id = sub.id)
        SELECT rowid FROM blocks WHERE id IN (SELECT id FROM sub)
        """, [SQLValue(id)]) { $0.int(0) }
        for rowid in rowids { try db.run("DELETE FROM search_index WHERE rowid=?", [.int(rowid)]) }
    }

    static func updateTitle(_ db: SQLiteConnection, page: UUID, title: String) throws {
        guard let rowid = try db.scalarInt("SELECT rowid FROM pages WHERE id=?", [SQLValue(page)]) else { return }
        try db.run("DELETE FROM search_index WHERE rowid=?", [.int(-rowid)])
        try insert(db, rowid: -rowid, page: page, block: nil, text: title)
    }

    /// Вызывается до удаления страницы: её блоки уйдут каскадом.
    static func removePage(_ db: SQLiteConnection, page: UUID) throws {
        let blocks = try db.query("SELECT rowid FROM blocks WHERE page_id=?", [SQLValue(page)]) { $0.int(0) }
        for rowid in blocks { try db.run("DELETE FROM search_index WHERE rowid=?", [.int(rowid)]) }
        if let rowid = try db.scalarInt("SELECT rowid FROM pages WHERE id=?", [SQLValue(page)]) {
            try db.run("DELETE FROM search_index WHERE rowid=?", [.int(-rowid)])
        }
    }

    /// Полная перестройка порциями: индекс нигде не считается источником истины.
    static func rebuild(_ db: SQLiteConnection) throws {
        try db.execute("DELETE FROM search_index; DELETE FROM page_links;")
        let pages = try db.query("SELECT rowid, id, title FROM pages") { ($0.int(0), $0.uuid(1), $0.text(2)) }
        for (rowid, id, title) in pages {
            if let id { try insert(db, rowid: -rowid, page: id, block: nil, text: title) }
        }
        var last: Int64 = 0
        while true {
            let rows = try db.query("""
            SELECT rowid, id, page_id, type, content_v, content_json, plain_text FROM blocks WHERE rowid > ? ORDER BY rowid LIMIT 2000
            """, [.int(last)]) { ($0.int(0), $0.uuid(1), $0.uuid(2), $0.text(3), $0.int(4), $0.text(5), $0.text(6)) }
            guard let end = rows.last?.0 else { return }
            last = end
            for (rowid, id, page, type, version, json, text) in rows {
                guard let id, let page else { continue }
                if !text.isEmpty { try insert(db, rowid: rowid, page: page, block: id, text: text) }
                let block = Block(id: id, pageID: page, parentID: nil, sortKey: "", type: BlockType(rawValue: type), contentVersion: Int(version), contentJSON: json, plainText: text, createdAt: 0, updatedAt: 0)
                for target in PageLink.targets(of: block) {
                    try db.run("INSERT OR IGNORE INTO page_links(block_id, from_page, to_page) VALUES(?,?,?)", [SQLValue(id), SQLValue(page), SQLValue(target)])
                }
            }
        }
    }
}

extension SQLiteWorkspace {
    /// Поиск по заголовкам и тексту блоков; корзина исключена. По странице — одно лучшее совпадение, заголовки выше.
    func search(_ query: String, limit: Int = 40) async throws -> [SearchHit] {
        guard let match = SearchText.match(query) else { return [] }
        return try await reader.run { db in
            let rows = try db.query("""
            SELECT search_index.page_id, search_index.block_id, pages.title, COALESCE(blocks.plain_text, '')
            FROM search_index JOIN pages ON pages.id = search_index.page_id
            LEFT JOIN blocks ON blocks.id = search_index.block_id
            WHERE search_index MATCH ? AND pages.deleted_at IS NULL AND (search_index.block_id = '' OR blocks.id IS NOT NULL)
            ORDER BY (search_index.block_id = '') DESC, bm25(search_index) LIMIT 400
            """, [.text(match)]) { r -> SearchHit? in
                guard let page = r.uuid(0) else { return nil }
                let block = r.uuid(1)
                let text = r.text(3)
                return SearchHit(pageID: page, blockID: block, title: r.text(2), snippet: block == nil ? "" : SearchText.snippet(text, query: query))
            }
            var seen: Set<UUID> = []
            var out: [SearchHit] = []
            for hit in rows.compactMap({ $0 }) where !seen.contains(hit.pageID) {
                seen.insert(hit.pageID)
                out.append(hit)
                if out.count == limit { break }
            }
            return out
        }
    }

    /// Страницы, которые ссылаются на эту. Ссылки из корзины не показываются.
    func backlinks(to page: UUID) async throws -> [Backlink] {
        try await reader.run { db in
            try db.query("""
            SELECT l.from_page, l.block_id, p.title, b.plain_text
            FROM page_links l JOIN pages p ON p.id = l.from_page JOIN blocks b ON b.id = l.block_id
            WHERE l.to_page = ? AND p.deleted_at IS NULL AND l.from_page <> ?
            ORDER BY p.title
            """, [SQLValue(page), SQLValue(page)]) { r -> Backlink? in
                guard let from = r.uuid(0), let block = r.uuid(1) else { return nil }
                return Backlink(pageID: from, blockID: block, title: r.text(2), text: r.text(3))
            }.compactMap { $0 }
        }
    }

    func rebuildSearchIndex() async throws {
        try await writer.run { db in try db.transaction { try SearchIndex.rebuild(db) } }
    }

    // MARK: Страницы: значок, избранное, дублирование

    func setPageIcon(_ id: UUID, icon: String?) async throws {
        try await writer.run { try $0.run("UPDATE pages SET icon=? WHERE id=?", [SQLValue(icon), SQLValue(id)]) }
    }

    func setPageCover(_ id: UUID, asset: UUID?) async throws {
        try await writer.run { try $0.run("UPDATE pages SET cover_asset_id=? WHERE id=?", [SQLValue(asset), SQLValue(id)]) }
    }

    func setPageFullWidth(_ id: UUID, _ value: Bool) async throws {
        try await writer.run { try $0.run("UPDATE pages SET full_width=? WHERE id=?", [.int(value ? 1 : 0), SQLValue(id)]) }
    }

    func setFavorite(_ id: UUID, _ value: Bool) async throws {
        try await writer.run { db in
            if value {
                let last = try db.scalarText("SELECT favorite_key FROM pages WHERE favorite_key IS NOT NULL ORDER BY favorite_key DESC LIMIT 1")
                try db.run("UPDATE pages SET favorite_key=? WHERE id=?", [.text(SortKey.between(last, nil)), SQLValue(id)])
            } else {
                try db.run("UPDATE pages SET favorite_key=NULL WHERE id=?", [SQLValue(id)])
            }
        }
    }

    /// Копия страницы с подстраницами. Новые UUID; ссылки внутри поддерева переназначаются, внешние сохраняются (FR-12).
    func duplicatePage(_ id: UUID, title: String, ids: IDGenerator, now: Int64) async throws -> UUID {
        try await writer.run { db in
            try db.transaction {
                try Self.copySubtree(db, root: id, title: title, target: .besideSource, ids: ids, now: now)
            }
        }
    }

    /// Куда попадает копия. Страница-шаблон получает `deleted_at` без пакета корзины.
    enum CopyTarget {
        case besideSource
        case hidden(now: Int64)
        case live(parent: UUID?)
    }

    /// Единая копия поддерева для дублирования и шаблонов: правила UUID и ссылок одни (FR-12).
    @discardableResult
    static func copySubtree(_ db: SQLiteConnection, root id: UUID, title: String, target: CopyTarget, ids: IDGenerator, now: Int64) throws -> UUID {
                try db.execute("PRAGMA defer_foreign_keys=ON") // Блок может быть вставлен раньше родителя.
                // Поддерево в том же состоянии, что и корень: корзина не попадает в копию, шаблон видит свои страницы.
                let subtree = try db.query("""
                WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT p.id FROM pages p JOIN sub ON p.parent_id = sub.id WHERE p.deleted_at IS (SELECT deleted_at FROM pages WHERE id = ?) AND p.trash_batch_id IS NULL)
                SELECT id FROM sub
                """, [SQLValue(id), SQLValue(id)]) { $0.uuid(0) }.compactMap { $0 }
                // Скрытый корень копируется только при создании из шаблона: обычное дублирование его не видит.
                var sourceSQL = "SELECT parent_id, sort_key FROM pages WHERE id=? AND trash_batch_id IS NULL"
                if case .live = target {} else { sourceSQL += " AND deleted_at IS NULL" }
                guard !subtree.isEmpty, let source = try db.query(sourceSQL, [SQLValue(id)], { ($0.uuid(0), $0.text(1)) }).first else {
                    throw WorkspaceError.pageNotFound(id)
                }
                let rootParent: UUID?
                var deletedAt: Int64?
                switch target {
                case .besideSource: rootParent = source.0
                case .hidden(let at): rootParent = source.0; deletedAt = at
                case .live(let parent): rootParent = parent
                }
                var pageMap: [UUID: UUID] = [:]
                for old in subtree { pageMap[old] = ids.next() }
                let next = try db.scalarText("SELECT sort_key FROM pages WHERE parent_id IS ? AND deleted_at IS NULL AND sort_key > ? ORDER BY sort_key LIMIT 1", [SQLValue(rootParent), .text(source.1)])
                var last: String?
                if case .live = target { last = try db.scalarText("SELECT sort_key FROM pages WHERE parent_id IS ? AND deleted_at IS NULL ORDER BY sort_key DESC, id DESC LIMIT 1", [SQLValue(rootParent)]) }

                for old in subtree {
                    guard let row = try db.query("SELECT parent_id, sort_key, title, icon, cover_asset_id, full_width FROM pages WHERE id=?", [SQLValue(old)], {
                        (parent: $0.uuid(0), key: $0.text(1), title: $0.text(2), icon: $0.optText(3), cover: $0.uuid(4), full: $0.int(5))
                    }).first, let newID = pageMap[old] else { continue }
                    let isRoot = old == id
                    let newTitle = isRoot ? title : row.title
                    try db.run("""
                    INSERT INTO pages(id, parent_id, sort_key, title, icon, cover_asset_id, full_width, created_at, updated_at, deleted_at) VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, [SQLValue(newID), SQLValue(isRoot ? rootParent : row.parent.flatMap { pageMap[$0] }),
                          .text(isRoot ? (last != nil || { if case .live = target { return true } else { return false } }() ? SortKey.between(last, nil) : SortKey.between(row.key, next)) : row.key),
                          .text(newTitle), SQLValue(row.icon), SQLValue(row.cover), .int(row.full), .int(now), .int(now), SQLValue(deletedAt)])
                    try SearchIndex.updateTitle(db, page: newID, title: newTitle)
                    try db.run("INSERT INTO page_tags(page_id, tag_id) SELECT ?, tag_id FROM page_tags WHERE page_id=?", [SQLValue(newID), SQLValue(old)])

                    let blocks = try db.query("SELECT id, parent_id, sort_key, type, content_v, content_json, plain_text FROM blocks WHERE page_id=?", [SQLValue(old)]) {
                        (id: $0.uuid(0), parent: $0.uuid(1), key: $0.text(2), type: $0.text(3), v: $0.int(4), json: $0.text(5), text: $0.text(6))
                    }
                    var blockMap: [UUID: UUID] = [:]
                    for b in blocks { if let bid = b.id { blockMap[bid] = ids.next() } }
                    for b in blocks {
                        guard let bid = b.id, let nb = blockMap[bid] else { continue }
                        var json = b.json
                        for (from, to) in pageMap { json = json.replacingOccurrences(of: from.lowercasedString, with: to.lowercasedString) }
                        try db.run("""
                        INSERT INTO blocks(id, page_id, parent_id, sort_key, type, content_v, content_json, plain_text, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
                        """, [SQLValue(nb), SQLValue(newID), SQLValue(b.parent.flatMap { blockMap[$0] }), .text(b.key), .text(b.type), .int(b.v), .text(json), .text(b.text), .int(now), .int(now)])
                        let copy = Block(id: nb, pageID: newID, parentID: nil, sortKey: b.key, type: BlockType(rawValue: b.type), contentVersion: Int(b.v), contentJSON: json, plainText: b.text, createdAt: now, updatedAt: now)
                        try SearchIndex.updateBlock(db, id: nb, page: newID, text: b.text, targets: PageLink.targets(of: copy))
                        try db.run("INSERT OR IGNORE INTO block_assets(owner_id, asset_id) SELECT ?, asset_id FROM block_assets WHERE owner_id=?", [SQLValue(nb), SQLValue(bid)])
                    }
                }
                try Self.duplicateDatabaseData(db, pageMap: pageMap, ids: ids, now: now)
                // Копии и записи, получившие связь с копией, пересчитывают свёртки.
                let copies = Set(pageMap.values)
                try Self.recalcRollups(db, touched: copies.union(try Self.neighbors(db, of: copies)), properties: nil, now: now)
                guard let root = pageMap[id] else { throw WorkspaceError.pageNotFound(id) }
                return root
    }
}
