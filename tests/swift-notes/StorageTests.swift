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
            checkEqual(mode, "wal"); checkEqual(fk, 1); checkEqual(sync, 2); checkEqual(version, 1)
            checkEqual(app, Migrations.applicationID)
            let live = try ws.maintenanceWrite { try schemaDump($0) }
            let fixture = try SQLiteConnection(path: dir.appendingPathComponent("f.sqlite").path, create: true)
            try fixture.execute(try String(contentsOfFile: "tests/fixtures/notes/schema_v1.sql"))
            checkEqual(try schemaDump(fixture), live, "fixture и миграция дают одну схему")
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
            expectError(await checkThrows { try SQLiteWorkspace.open(at: w) }, .schemaTooNew(found: 99, supported: 1))
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
            bad.migrations = Migrations.all + [Migration(version: 2, name: "ошибка") { db in
                try db.execute("ALTER TABLE pages ADD COLUMN mood TEXT")
                try db.execute("THIS IS NOT SQL")
            }]
            let failure = await checkThrows { try SQLiteWorkspace.open(at: w, options: bad) }
            if case .migrationFailed(let v, _)? = failure as? WorkspaceError { checkEqual(v, 2) } else { check(false, "\(String(describing: failure))") }
            let still = try SQLiteWorkspace.open(at: w)
            checkEqual(try still.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM pragma_table_info('pages') WHERE name='mood'") }, 0, "колонка откатилась")
            still.close()

            var good = SQLiteWorkspace.Options()
            var backedUp = false
            good.beforeMigration = { snapshotter, _ in
                let copy = dir.appendingPathComponent("pre.sqlite")
                try snapshotter.snapshotDatabase(to: copy)
                let info = try SQLiteSnapshotInspector().inspect(copy)
                checkEqual(info.schemaVersion, 1, "копия снята до миграции")
                backedUp = true
            }
            good.migrations = Migrations.all + [Migration(version: 2, name: "настроение") { try $0.execute("ALTER TABLE pages ADD COLUMN mood TEXT") }]
            let v2 = try SQLiteWorkspace.open(at: w, options: good)
            check(backedUp, "копия сделана")
            checkEqual(try v2.maintenanceWrite { try $0.scalarInt("PRAGMA user_version") }, 2)
            checkEqual(try v2.maintenanceWrite { try $0.scalarInt("SELECT count(*) FROM schema_migrations") }, 2)
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
