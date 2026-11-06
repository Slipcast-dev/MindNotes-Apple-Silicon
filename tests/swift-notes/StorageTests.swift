import Foundation
import CryptoKit

func fileHash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func expectError(_ error: Error?, _ expected: WorkspaceError, file: StaticString = #fileID, line: UInt = #line) {
    check((error as? WorkspaceError) == expected, "ожидалось \(expected), получено \(String(describing: error))", file: file, line: line)
}

func schemaDump(_ db: SQLiteConnection) throws -> [String] {
    try db.query("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY name") {
        $0.text(0).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

func runStorageTests() async {
    await test("Открытие: PRAGMA, схема v1 совпадает с fixture") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "Тест")
            let (mode, fk, sync, version, app) = try ws.maintenanceWrite { db in
                (try db.scalarText("PRAGMA journal_mode"), try db.scalarInt("PRAGMA foreign_keys"), try db.scalarInt("PRAGMA synchronous"),
                 try db.scalarInt("PRAGMA user_version"), try db.scalarInt("PRAGMA application_id"))
            }
            checkEqual(mode, "wal"); checkEqual(fk, 1); checkEqual(sync, 2); checkEqual(version, Optional(Int64(Migrations.supportedVersion)))
            checkEqual(app, Migrations.applicationID)
            let live = try ws.maintenanceWrite { try schemaDump($0) }
            let fixture = try SQLiteConnection(path: dir.appendingPathComponent("f.sqlite").path, create: true)
            try fixture.execute(try String(contentsOfFile: "tests/fixtures/notes/schema_v1.sql"))
            try fixture.execute("PRAGMA user_version=1")
            // База прошлой версии после миграции совпадает с новой.
            try Migrator.migrate(fixture, migrations: Migrations.all, appVersion: "t", now: 1)
            checkEqual(try schemaDump(fixture), live, "миграция v1 даёт ту же схему, что новая база")
            ws.close()
        }
    }

    await test("Второе открытие отклоняется, после закрытия разрешено") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let a = try SQLiteWorkspace.create(at: w, name: "A")
            expectError(await checkThrows { try SQLiteWorkspace.open(at: w) }, .alreadyOpen)
            a.close()
            let b = try SQLiteWorkspace.open(at: w)
            b.close()
        }
    }

    await test("AT-16: новая схема отклоняется без изменения данных") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let a = try SQLiteWorkspace.create(at: w, name: "A")
            let id = UUID()
            _ = try await a.createPage(parent: nil, title: "Страница", id: id, now: 1)
            try a.maintenanceWrite { try $0.execute("PRAGMA user_version=99; PRAGMA wal_checkpoint(TRUNCATE)") }
            a.close()
            let db = WorkspaceLayout(root: w).database
            let before = try fileHash(db)
            expectError(await checkThrows { try SQLiteWorkspace.open(at: w) }, .schemaTooNew(found: 99, supported: Migrations.supportedVersion))
            checkEqual(try fileHash(db), before, "файл базы не изменён")
        }
    }

    await test("Отказы: чужая база, не пространство, нет прав, повреждение, непустая папка") {
        try await withTempDir { dir in
            let foreign = dir.appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            let c = try SQLiteConnection(path: WorkspaceLayout(root: foreign).database.path, create: true)
            try c.execute("CREATE TABLE x(a); PRAGMA user_version=1")
            c.close()
            expectError(await checkThrows { try SQLiteWorkspace.open(at: foreign) }, .notAWorkspace(foreign.path))

            let empty = dir.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            expectError(await checkThrows { try SQLiteWorkspace.open(at: empty) }, .notAWorkspace(empty.path))

            let busy = dir.appendingPathComponent("busy")
            try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: busy.appendingPathComponent("личное.txt"))
            expectError(await checkThrows { try SQLiteWorkspace.create(at: busy, name: "A") }, .directoryNotEmpty(busy.path))

            let locked = dir.appendingPathComponent("locked")
            try SQLiteWorkspace.create(at: locked, name: "A").close()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            expectError(await checkThrows { try SQLiteWorkspace.open(at: locked) }, .noPermission(locked.path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)

            let broken = dir.appendingPathComponent("broken")
            try SQLiteWorkspace.create(at: broken, name: "A").close()
            let file = WorkspaceLayout(root: broken).database
            var bytes = try Data(contentsOf: file)
            bytes.replaceSubrange(0..<32, with: Data(repeating: 0x41, count: 32))
            try bytes.write(to: file)
            let error = await checkThrows { try SQLiteWorkspace.open(at: broken) }
            if case .corrupted? = error as? WorkspaceError { check(true) } else { check(false, "ожидалось повреждение: \(String(describing: error))") }
        }
    }

    await test("Миграции: откат при ошибке, копия до миграции, запись в журнал") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let a = try SQLiteWorkspace.create(at: w, name: "A")
            let pid = UUID()
            _ = try await a.createPage(parent: nil, title: "До миграции", id: pid, now: 1)
            a.close()

            var bad = SQLiteWorkspace.Options()
            bad.migrations = Migrations.all + [Migration(version: Migrations.supportedVersion + 1, name: "ошибка") { db in
                try db.execute("ALTER TABLE pages ADD COLUMN mood TEXT")
                try db.execute("THIS IS NOT SQL")
            }]
            let failure = await checkThrows { try SQLiteWorkspace.open(at: w, options: bad) }
            if case .migrationFailed(let v, _)? = failure as? WorkspaceError { checkEqual(v, Migrations.supportedVersion + 1) } else { check(false, "\(String(describing: failure))") }
            let still = try SQLiteWorkspace.open(at: w)
            checkEqual(try still.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM pragma_table_info('pages') WHERE name='mood'") }, 0, "колонка откатилась")
            still.close()

            var good = SQLiteWorkspace.Options()
            var backedUp = false
            good.beforeMigration = { snapshotter, _ in
                let copy = dir.appendingPathComponent("pre.sqlite")
                try snapshotter.snapshotDatabase(to: copy)
                let info = try SQLiteSnapshotInspector().inspect(copy)
                checkEqual(info.schemaVersion, Migrations.supportedVersion, "копия снята до миграции")
                backedUp = true
            }
            good.migrations = Migrations.all + [Migration(version: Migrations.supportedVersion + 1, name: "настроение") { try $0.execute("ALTER TABLE pages ADD COLUMN mood TEXT") }]
            let v2 = try SQLiteWorkspace.open(at: w, options: good)
            check(backedUp, "копия сделана")
            checkEqual(try v2.maintenanceWrite { try $0.scalarInt("PRAGMA user_version") }, Optional(Int64(Migrations.supportedVersion + 1)))
            checkEqual(try v2.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM schema_migrations") }, Optional(Int64(Migrations.supportedVersion + 1)))
            let page = try await v2.page(pid)
            checkEqual(page?.title, "До миграции")
            v2.close()
        }
    }

    await test("AT-02: дерево страниц, циклы запрещены, порядок переживает перезапуск") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            var ws = try SQLiteWorkspace.create(at: w, name: "A")
            let root = UUID(), child = UUID(), grand = UUID(), other = UUID()
            _ = try await ws.createPage(parent: nil, title: "Корень", id: root, now: 1)
            _ = try await ws.createPage(parent: root, title: "Дочерняя", id: child, now: 2)
            _ = try await ws.createPage(parent: child, title: "Внучка", id: grand, now: 3)
            _ = try await ws.createPage(parent: nil, title: "Корень", id: other, now: 4)
            let pages = try await ws.allPages()
            checkEqual(pages.filter { $0.title == "Корень" }.count, 2, "одинаковые заголовки разрешены")

            expectError(await checkThrows { try await ws.movePage(root, toParent: root, afterSibling: nil, now: 5) }, .wouldCreateCycle)
            expectError(await checkThrows { try await ws.movePage(root, toParent: grand, afterSibling: nil, now: 5) }, .wouldCreateCycle)
            try await ws.movePage(grand, toParent: other, afterSibling: nil, now: 6)
            try await ws.movePage(child, toParent: nil, afterSibling: root, now: 7)

            ws.close()
            ws = try SQLiteWorkspace.open(at: w)
            let after = try await ws.allPages()
            checkEqual(after.first { $0.id == grand }?.parentID, other, "перемещение сохранено")
            let roots = after.filter { $0.parentID == nil }.map(\.id)
            checkEqual(roots, [root, child, other], "порядок сохранён")
            ws.close()
        }
    }

    await test("Блоки: кириллица, emoji, неизвестный тип, каскад") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            var ws = try SQLiteWorkspace.create(at: w, name: "A")
            let page = UUID()
            _ = try await ws.createPage(parent: nil, title: "С", id: page, now: 1)
            let task = UUID(), text = UUID(), unknown = UUID(), child = UUID()
            var batch = SaveBatch()
            batch.upserts[task] = Block(id: task, pageID: page, sortKey: "a0", type: .task, content: BlockContent(runs: [TextRun("Купить ёлку 🎄")], checked: true), createdAt: 1)
            batch.upserts[text] = Block(id: text, pageID: page, sortKey: "a1", content: BlockContent(text: "Текст 👨‍👩‍👧"), createdAt: 1)
            batch.upserts[child] = Block(id: child, pageID: page, parentID: text, sortKey: "a0", content: BlockContent(text: "Вложенный"), createdAt: 1)
            let raw = #"{"будущее":  true}"#
            batch.upserts[unknown] = Block(id: unknown, pageID: page, parentID: nil, sortKey: "a2", type: BlockType(rawValue: "future"),
                                           contentVersion: 7, contentJSON: raw, plainText: "поиск", createdAt: 1, updatedAt: 1)
            batch.touchedPages = [page]
            batch.titles[page] = "Новое имя"
            try await ws.commit(batch)
            ws.close()
            ws = try SQLiteWorkspace.open(at: w)
            let blocks = try await ws.blocks(ofPage: page)
            let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
            checkEqual(byID[task]?.content?.plainText, "Купить ёлку 🎄")
            checkEqual(byID[task]?.content?.checked, true)
            checkEqual(byID[text]?.plainText, "Текст 👨‍👩‍👧")
            checkEqual(try byID[unknown]?.contentJSON(), raw, "неизвестный блок без изменений")
            let p = try await ws.page(page)
            checkEqual(p?.title, "Новое имя")
            checkEqual(p?.contentRev, 1)

            var del = SaveBatch()
            del.deletes = [text]
            try await ws.commit(del)
            let left = try await ws.blocks(ofPage: page).map(\.id)
            check(!left.contains(child), "дочерний блок удалён каскадом")
            ws.close()
        }
    }

    await test("Отказ записи: заполненный диск даёт ошибку и откат") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let page = UUID()
            _ = try await ws.createPage(parent: nil, title: "С", id: page, now: 1)
            try ws.maintenanceWrite { db in
                let used = try db.scalarInt("PRAGMA page_count") ?? 1
                _ = try db.query("PRAGMA max_page_count=\(used)") { $0.int(0) }
            }
            var batch = SaveBatch()
            for i in 0..<400 {
                let id = UUID()
                batch.upserts[id] = Block(id: id, pageID: page, sortKey: "a\(i)", content: BlockContent(text: String(repeating: "ё", count: 2000)), createdAt: 1)
            }
            expectError(await checkThrows { try await ws.commit(batch) }, .diskFull)
            let count = try await ws.blocks(ofPage: page).count
            checkEqual(count, 0, "частичной записи нет")
            ws.close()
        }
    }

    await test("История: снимок, пропуск при том же содержимом, чтение обратно") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let page = UUID()
            _ = try await ws.createPage(parent: nil, title: "С", id: page, now: 1)
            let block = Block(id: UUID(), pageID: page, sortKey: "a0", type: .task, content: BlockContent(runs: [TextRun("Дело ✅")], checked: true), createdAt: 1)
            let first = try await ws.saveRevision(pageID: page, reason: "тест", blocks: [block], id: UUID(), now: 10)
            check(first != nil, "снимок создан")
            let same = try await ws.saveRevision(pageID: page, reason: "тест", blocks: [block], id: UUID(), now: 20)
            check(same == nil, "то же содержимое не сохраняется")
            var changed = block
            changed.setContent(BlockContent(text: "Иначе"))
            let second = try await ws.saveRevision(pageID: page, reason: "тест", blocks: [changed], id: UUID(), now: 30)
            checkEqual(second?.seq, 2)
            let back = try await ws.revisionBlocks(first!.id)
            checkEqual(back.first?.content?.plainText, "Дело ✅")
            checkEqual(back.first?.content?.checked, true)
            let list = try await ws.revisions(ofPage: page)
            checkEqual(list.map(\.seq), [2, 1])
            ws.close()
        }
    }
}

func runCrashTests() async {
    await test("AT-09: авария до COMMIT теряет правку, после COMMIT сохраняет; блокировка снимается") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let page = UUID()
            _ = try await ws.createPage(parent: nil, title: "Мой проект", id: page, now: 1)
            ws.close()

            checkEqual(try runCrashChild(dir: w, point: "before-commit"), 42, "процесс оборван до фиксации")
            var r = try SQLiteWorkspace.open(at: w)
            var blocks = try await r.blocks(ofPage: page)
            checkEqual(blocks.count, 0, "незафиксированной правки нет")
            r.close()

            checkEqual(try runCrashChild(dir: w, point: "after-commit"), 42, "процесс оборван после фиксации")
            r = try SQLiteWorkspace.open(at: w)
            blocks = try await r.blocks(ofPage: page)
            checkEqual(blocks.map(\.plainText), ["после аварии: after-commit"], "подтверждённая правка восстановлена")
            r.close()
        }
    }
}

func runTagAndLookTests() async {
    await test("Миграция настоящей базы v1: страницы целы, копия сделана, теги работают") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            let c = try SQLiteConnection(path: WorkspaceLayout(root: w).database.path, create: true)
            try c.execute("PRAGMA application_id=\(Migrations.applicationID)")
            try c.execute(try String(contentsOfFile: "tests/fixtures/notes/schema_v1.sql"))
            try c.execute("PRAGMA user_version=1")
            let wid = UUID(), page = UUID()
            try c.run("INSERT INTO workspace_meta(key, value) VALUES('workspace_id', ?), ('name', 'Старое')", [SQLValue(wid)])
            try c.run("INSERT INTO pages(id, sort_key, title, created_at, updated_at) VALUES(?, 'a0', 'Страница v1', 1, 1)", [SQLValue(page)])
            c.close()
            var options = SQLiteWorkspace.Options()
            let copy = dir.appendingPathComponent("pre.grizzlybackup")
            options.beforeMigration = { snapshotter, root in
                try BackupService.create(workspaceRoot: root, snapshotter: snapshotter, inspector: SQLiteSnapshotInspector(), destination: copy, appVersion: "t", now: 1)
            }
            let ws = try SQLiteWorkspace.open(at: w, options: options)
            check(FileManager.default.fileExists(atPath: copy.path), "копия до миграции")
            let manifest = try RestoreService.verify(archive: copy)
            checkEqual(manifest.schema_version, 1, "в копии старая схема")
            let p = try await ws.page(page)
            checkEqual(p?.title, "Страница v1")
            let t = try await ws.createTag(name: "Проект", color: nil, now: 1)
            try await ws.setTag(t.id, on: page, true)
            let pt = try await ws.pageTags()
            checkEqual(pt[page], [t.id])
            ws.close()
            // Архив старой версии восстанавливается и обновляется.
            let target = dir.appendingPathComponent("r")
            try RestoreService.restore(archive: copy, to: target, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 2)
            let re = try SQLiteWorkspace.open(at: target)
            let again = try await re.page(page)
            checkEqual(again?.title, "Страница v1")
            re.close()
        }
    }

    await test("Теги: регистр, ё/е, переименование с объединением, удаление, корзина") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let a = try await ws.createPage(parent: nil, title: "А", id: UUID(), now: 1)
            let b = try await ws.createPage(parent: nil, title: "Б", id: UUID(), now: 1)
            let t1 = try await ws.createTag(name: " Ёлка ", color: "green", now: 1)
            checkEqual(t1.name, "Ёлка", "пробелы убраны")
            let same = try await ws.createTag(name: "елка", color: nil, now: 2)
            checkEqual(same.id, t1.id, "тот же тег без учёта регистра и ё")
            await checkThrows("пустое имя") { try await ws.createTag(name: "  ", color: nil, now: 1) }
            let t2 = try await ws.createTag(name: "Работа", color: nil, now: 1)
            try await ws.setTag(t1.id, on: a.id, true)
            try await ws.setTag(t1.id, on: a.id, true)
            try await ws.setTag(t2.id, on: a.id, true)
            try await ws.setTag(t2.id, on: b.id, true)
            var map = try await ws.pageTags()
            checkEqual(map[a.id], [t1.id, t2.id], "порядок по имени, без повторов")
            try await ws.setTag(t1.id, on: a.id, false)
            map = try await ws.pageTags()
            checkEqual(map[a.id], [t2.id])
            try await ws.setTagColor(t2.id, color: "red")
            try await ws.renameTag(t2.id, to: "Дела")
            var all = try await ws.tags()
            checkEqual(all.first { $0.id == t2.id }?.name, "Дела")
            checkEqual(all.first { $0.id == t2.id }?.color, "red")
            try await ws.setTag(t1.id, on: b.id, true)
            try await ws.renameTag(t2.id, to: "ёлка")
            all = try await ws.tags()
            checkEqual(all.map(\.id), [t1.id], "теги объединились")
            map = try await ws.pageTags()
            checkEqual(map[a.id], [t1.id], "страницы перешли к оставшемуся тегу")
            checkEqual(map[b.id], [t1.id])
            try await ws.trashPage(b.id, batch: UUID(), now: 3)
            map = try await ws.pageTags()
            check(map[b.id] == nil, "страница в корзине не считается")
            try await ws.deleteTag(t1.id)
            map = try await ws.pageTags()
            check(map.isEmpty, "удаление снимает тег")
            let page = try await ws.page(a.id)
            check(page != nil, "страницы целы")
            ws.close()
        }
    }

    await test("Вид пространства и файлы: сохранение, архив, восстановление") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            var ws = try SQLiteWorkspace.create(at: w, name: "Старое имя")
            let source = dir.appendingPathComponent("обложка.PNG")
            let body = Data((0..<4096).map { UInt8($0 % 251) })
            try body.write(to: source)
            let asset = try await ws.addAsset(copying: source, now: 1)
            check(asset.relPath.hasSuffix(".png"), "расширение в нижнем регистре")
            check(RestoreService.isAllowedAssetPath(asset.relPath), "путь проходит проверку архива")
            checkEqual(asset.originalName, "обложка.PNG")
            let url = try await ws.assetURL(asset.id)
            checkEqual(try Data(contentsOf: url!), body, "копия совпадает")
            try FileManager.default.removeItem(at: source)
            check(FileManager.default.fileExists(atPath: url!.path), "копия не зависит от источника")
            checkEqual((try? FileManager.default.contentsOfDirectory(atPath: w.appendingPathComponent("tmp").path))?.count, 0, "временных файлов нет")
            await checkThrows("нет исходного файла") { try await ws.addAsset(copying: source, now: 1) }
            var look = WorkspaceLook()
            let initial = try await ws.look()
            checkEqual(initial, look, "по умолчанию")
            look.logoKind = .emoji
            look.logoValue = "🐻"
            look.logoColor = "blue"
            look.coverKind = .image
            look.coverAsset = asset.id
            look.coverLabel = "Мой дом"
            try await ws.setLook(look)
            try await ws.rename(to: "Новое имя")
            ws.close()
            ws = try SQLiteWorkspace.open(at: w)
            let reread = try await ws.look()
            checkEqual(reread, look, "после перезапуска")
            let name = try await ws.workspaceName()
            checkEqual(name, "Новое имя")
            let archive = dir.appendingPathComponent("a.grizzlybackup")
            let r = try BackupService.create(workspaceRoot: w, snapshotter: ws, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 1)
            check(r.isComplete, "обложка в архиве")
            ws.close()
            let target = dir.appendingPathComponent("r")
            try RestoreService.restore(archive: archive, to: target, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 2)
            let re = try SQLiteWorkspace.open(at: target)
            let restoredLook = try await re.look()
            checkEqual(restoredLook, look, "вид перенёсся")
            let restored = try await re.assetURL(asset.id)
            checkEqual(try Data(contentsOf: restored!), body, "картинка перенеслась")
            re.close()
        }
    }
}

func runAssetDeleteTests() async {
    await test("Вложение: удаление убирает запись и файл, длинное расширение отбрасывается") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let source = dir.appendingPathComponent("a." + String(repeating: "x", count: 40))
            try Data("x".utf8).write(to: source)
            let asset = try await ws.addAsset(copying: source, now: 1)
            check(!asset.relPath.contains("xxx"), "расширение отброшено: \(asset.relPath)")
            let url = try await ws.assetURL(asset.id)
            try await ws.deleteAsset(asset.id)
            let gone = try await ws.assetURL(asset.id)
            check(gone == nil, "записи нет")
            check(!FileManager.default.fileExists(atPath: url!.path), "файла нет")
            try await ws.deleteAsset(UUID())
            ws.close()
        }
    }
}

func runSearchTests() async {
    func para(_ page: UUID, _ key: String, _ text: String, marks: [String] = []) -> Block {
        Block(id: UUID(), pageID: page, sortKey: key, content: BlockContent(runs: [TextRun(text, marks: marks)]), createdAt: 1)
    }
    func commit(_ ws: SQLiteWorkspace, _ blocks: [Block], deletes: [UUID] = [], titles: [UUID: String] = [:]) async throws {
        var b = SaveBatch()
        for x in blocks { b.upserts[x.id] = x }
        b.deletes = Set(deletes)
        b.titles = titles
        try await ws.commit(b)
    }

    await test("Поиск: заголовки и текст, префиксы, регистр, ё/е, й≠и, спецсимволы") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let a = try await ws.createPage(parent: nil, title: "Ёлочные игрушки", id: UUID(), now: 1)
            let b = try await ws.createPage(parent: nil, title: "Заметки", id: UUID(), now: 1)
            let block = para(b.id, "a0", "Купить ёлку и МАЙСКИЙ мёд 🍯 для дома")
            try await commit(ws, [block])
            func ids(_ q: String) async throws -> [UUID] { try await ws.search(q).map(\.pageID) }
            var r = try await ids("елоч")
            checkEqual(r, [a.id], "префикс заголовка, ё как е")
            r = try await ids("ЁЛОЧНЫЕ")
            checkEqual(r, [a.id], "регистр")
            r = try await ids("елку")
            checkEqual(r, [b.id], "текст блока")
            r = try await ids("майский мед")
            checkEqual(r, [b.id], "несколько слов")
            r = try await ids("маиский")
            checkEqual(r, [], "й и и различаются")
            r = try await ids("  ")
            checkEqual(r, [])
            r = try await ids("\" OR * NEAR( -")
            checkEqual(r.count, 0, "спецсимволы не ломают запрос")
            let hit = try await ws.search("майский").first
            checkEqual(hit?.blockID, block.id, "переход к блоку")
            check(hit?.snippet.contains("МАЙСКИЙ") == true, "фрагмент исходного текста: \(hit?.snippet ?? "")")
            ws.close()
        }
    }

    await test("Поиск: правка, переименование, удаление блока, корзина, перестройка индекса") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            var ws = try SQLiteWorkspace.create(at: w, name: "A")
            let p = try await ws.createPage(parent: nil, title: "Старое", id: UUID(), now: 1)
            var block = para(p.id, "a0", "первое слово")
            try await commit(ws, [block])
            block.setContent(BlockContent(text: "другое значение"))
            try await commit(ws, [block])
            var r = try await ws.search("первое")
            check(r.isEmpty, "старый текст ушёл из индекса")
            r = try await ws.search("значение")
            checkEqual(r.count, 1, "новый текст")
            try await commit(ws, [], titles: [p.id: "Новое имя"])
            r = try await ws.search("старое")
            check(r.isEmpty, "старый заголовок")
            r = try await ws.search("новое")
            checkEqual(r.first?.title, "Новое имя")
            let batch = UUID()
            try await ws.trashPage(p.id, batch: batch, now: 2)
            r = try await ws.search("значение")
            check(r.isEmpty, "корзина исключена")
            _ = try await ws.restoreTrash(batch: batch)
            r = try await ws.search("значение")
            checkEqual(r.count, 1, "восстановленная снова находится")
            try await commit(ws, [], deletes: [block.id])
            r = try await ws.search("значение")
            check(r.isEmpty, "удалённый блок")
            // Индекс производный: разрушенный восстанавливается из данных.
            let keep = para(p.id, "a1", "сохранённый текст")
            try await commit(ws, [keep])
            try ws.maintenanceWrite { try $0.execute("DELETE FROM search_index; DELETE FROM page_links") }
            r = try await ws.search("сохраненный")
            check(r.isEmpty, "индекс очищен")
            try await ws.rebuildSearchIndex()
            r = try await ws.search("сохраненный")
            checkEqual(r.count, 1, "перестроен")
            ws.close()
            ws = try SQLiteWorkspace.open(at: w)
            r = try await ws.search("сохраненный")
            checkEqual(r.count, 1, "после перезапуска")
            ws.close()
        }
    }

    await test("Миграция v3: старые страницы и блоки попадают в индекс и ссылки") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            let c = try SQLiteConnection(path: WorkspaceLayout(root: w).database.path, create: true)
            try c.execute("PRAGMA application_id=\(Migrations.applicationID)")
            try c.execute(try String(contentsOfFile: "tests/fixtures/notes/schema_v1.sql"))
            try c.execute("PRAGMA user_version=1")
            let page = UUID(), other = UUID(), block = UUID()
            let json = #"{"runs":[{"t":"см. страницу","m":["\#(PageLink.mark(other))"]}]}"#
            try c.run("INSERT INTO workspace_meta(key, value) VALUES('workspace_id', ?), ('name', 'С')", [SQLValue(UUID())])
            try c.run("INSERT INTO pages(id, sort_key, title, created_at, updated_at) VALUES(?, 'a0', 'Давняя страница', 1, 1), (?, 'a1', 'Цель', 1, 1)", [SQLValue(page), SQLValue(other)])
            try c.run("INSERT INTO blocks(id, page_id, sort_key, type, content_v, content_json, plain_text, created_at, updated_at) VALUES(?,?,'a0','paragraph',1,?,'см. страницу',1,1)", [SQLValue(block), SQLValue(page), .text(json)])
            c.close()
            let ws = try SQLiteWorkspace.open(at: w)
            let titles = try await ws.search("давняя")
            checkEqual(titles.first?.pageID, page, "заголовок в индексе")
            let texts = try await ws.search("страницу")
            checkEqual(texts.first?.blockID, block)
            let links = try await ws.backlinks(to: other)
            checkEqual(links.map(\.blockID), [block], "ссылки собраны")
            ws.close()
        }
    }

    await test("Обратные ссылки: появление, снятие, корзина источника, цель в корзине") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            let target = try await ws.createPage(parent: nil, title: "Цель", id: UUID(), now: 1)
            let source = try await ws.createPage(parent: nil, title: "Источник", id: UUID(), now: 1)
            var block = para(source.id, "a0", "ссылка", marks: [PageLink.mark(target.id)])
            try await commit(ws, [block])
            var links = try await ws.backlinks(to: target.id)
            checkEqual(links.first?.title, "Источник")
            checkEqual(links.first?.text, "ссылка")
            try await commit(ws, [], titles: [target.id: "Переименованная"])
            links = try await ws.backlinks(to: target.id)
            checkEqual(links.count, 1, "переименование цели не ломает ссылку")
            let batch = UUID()
            try await ws.trashPage(source.id, batch: batch, now: 2)
            links = try await ws.backlinks(to: target.id)
            check(links.isEmpty, "ссылка из корзины не показывается")
            _ = try await ws.restoreTrash(batch: batch)
            block.setContent(BlockContent(text: "без ссылки"))
            try await commit(ws, [block])
            links = try await ws.backlinks(to: target.id)
            check(links.isEmpty, "ссылка снята")
            ws.close()
        }
    }

    await test("Дублирование: новые UUID, поддерево, внутренние ссылки переназначены, внешние сохранены") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let root = try await ws.createPage(parent: nil, title: "Проект", id: UUID(), now: 1)
            let child = try await ws.createPage(parent: root.id, title: "Часть", id: UUID(), now: 1)
            let outside = try await ws.createPage(parent: nil, title: "Снаружи", id: UUID(), now: 1)
            let tag = try await ws.createTag(name: "Важно", color: nil, now: 1)
            try await ws.setTag(tag.id, on: root.id, true)
            try await ws.setPageIcon(root.id, icon: "🐻")
            let inner = para(root.id, "a0", "на часть", marks: [PageLink.mark(child.id)])
            let outer = para(root.id, "a1", "наружу", marks: [PageLink.mark(outside.id)])
            let nested = Block(id: UUID(), pageID: root.id, parentID: inner.id, sortKey: "a0", content: BlockContent(text: "вложенный"), createdAt: 1)
            try await commit(ws, [inner, outer, nested, para(child.id, "a0", "текст части")])
            let copy = try await ws.duplicatePage(root.id, title: "Проект (копия)", ids: RandomIDs(), now: 5)
            let pages = try await ws.allPages()
            let copyPage = pages.first { $0.id == copy }!
            checkEqual(copyPage.title, "Проект (копия)")
            checkEqual(copyPage.icon, "🐻")
            check(copyPage.sortKey > root.sortKey && copyPage.sortKey < outside.sortKey, "сразу за исходной")
            let copyChild = pages.first { $0.parentID == copy }!
            checkEqual(copyChild.title, "Часть")
            check(copyChild.id != child.id, "новый UUID")
            let blocks = try await ws.blocks(ofPage: copy)
            checkEqual(blocks.count, 3)
            check(Set(blocks.map(\.id)).isDisjoint(with: [inner.id, outer.id, nested.id]), "новые UUID блоков")
            let cin = blocks.first { $0.plainText == "на часть" }!
            checkEqual(PageLink.targets(of: cin), [copyChild.id], "внутренняя ссылка на копию")
            let cout = blocks.first { $0.plainText == "наружу" }!
            checkEqual(PageLink.targets(of: cout), [outside.id], "внешняя ссылка прежняя")
            checkEqual(blocks.first { $0.plainText == "вложенный" }?.parentID, cin.id, "вложенность блоков")
            let tags = try await ws.pageTags()
            checkEqual(tags[copy], [tag.id], "теги скопированы")
            let found = try await ws.search("текст части")
            checkEqual(found.count, 2, "копия в поиске")
            let links = try await ws.backlinks(to: outside.id)
            checkEqual(links.count, 2, "ссылки копии учтены")
            try await ws.setFavorite(root.id, true)
            try await ws.setFavorite(copy, true)
            var fav = try await ws.allPages()
            let keys = fav.filter { $0.favoriteKey != nil }.sorted { $0.favoriteKey! < $1.favoriteKey! }.map(\.id)
            checkEqual(keys, [root.id, copy], "порядок избранного")
            try await ws.setFavorite(root.id, false)
            fav = try await ws.allPages()
            checkEqual(fav.first { $0.id == root.id }?.favoriteKey, nil)
            ws.close()
        }
    }
}
