import CryptoKit
import Foundation

/// Сценарии приёмки ТЗ, которые не покрыты отдельными тестами: AT-03, AT-05, AT-12.
func runAcceptanceTests() async {
    await test("AT-03 и AT-12: смешанное содержимое, база, ссылки и вложения переживают архив и восстановление") {
        try await withTempDir { dir in
            let source = dir.appendingPathComponent("src")
            let ws = try SQLiteWorkspace.create(at: source, name: "Исходное")
            let project = UUID(), child = UUID(), other = UUID()
            _ = try await ws.createPage(parent: nil, title: "Мой проект", id: project, now: 1)
            _ = try await ws.createPage(parent: project, title: "Подстраница", id: child, now: 1)
            _ = try await ws.createPage(parent: nil, title: "Справка", id: other, now: 1)

            let png = dir.appendingPathComponent("схема.png"), clip = dir.appendingPathComponent("ролик.mov")
            try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).write(to: png)
            try Data(repeating: 7, count: 4096).write(to: clip)
            let image = try await ws.addAsset(copying: png, now: 1), video = try await ws.addAsset(copying: clip, now: 1)

            // Текст, списки, задача, код, картинка, видео, таблица, ссылка на страницу — в одном порядке.
            var batch = SaveBatch()
            var blocks: [Block] = []
            func add(_ block: Block) { blocks.append(block); batch.upserts[block.id] = block }
            let keys = SortKey.keys(after: nil, before: nil, count: 9)
            add(Block(id: UUID(), pageID: project, sortKey: keys[0], content: BlockContent(runs: [TextRun("Жирный", marks: ["b"]), TextRun(" и ёлка 🎄")]), createdAt: 1))
            let list = Block(id: UUID(), pageID: project, sortKey: keys[1], type: .bullet, content: BlockContent(text: "пункт"), createdAt: 1)
            add(list)
            add(Block(id: UUID(), pageID: project, parentID: list.id, sortKey: "a0", type: .bullet, content: BlockContent(text: "вложенный"), createdAt: 1))
            add(Block(id: UUID(), pageID: project, sortKey: keys[2], type: .task, content: BlockContent(runs: [TextRun("сделано")], checked: true), createdAt: 1))
            add(Block(id: UUID(), pageID: project, sortKey: keys[3], type: .code, content: BlockContent(text: "let x = 1\nprint(x)"), createdAt: 1))
            for (key, fragment) in [(keys[4], AtomData.attachment(type: .image, asset: image)), (keys[5], AtomData.attachment(type: .video, asset: video)),
                                    (keys[6], AtomData.table([["А", "Б"], ["1", "2"]]))] {
                add(Block(id: UUID(), pageID: project, parentID: nil, sortKey: key, type: BlockType(rawValue: fragment.type), contentVersion: fragment.contentVersion,
                          contentJSON: fragment.json, plainText: fragment.plain, createdAt: 1, updatedAt: 1))
            }
            add(Block(id: UUID(), pageID: project, sortKey: keys[7], content: BlockContent(runs: [TextRun("см. справку", marks: [PageLink.mark(other)])]), createdAt: 1))
            batch.touchedPages = [project]
            try await ws.commit(batch)

            let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус",
                                       statusOptions: ["Запланировано", "Готово"], dateProperty: "Срок", viewName: "Таблица")
            let database = try await ws.createDatabase(parent: project, template: template, ids: RandomIDs(), now: 2)
            let status = database.properties.first { $0.type == .status }!, date = database.properties.first { $0.type == .date }!
            let record = UUID()
            try await ws.createRecord(database: database.id, title: "Задача", id: record, now: 2)
            try await ws.setValue(pages: [record], property: status.id, value: .options([status.options[1].id]), now: 3)
            try await ws.setValue(pages: [record], property: date.id, value: .date(DateValue(start: .day(LocalDate(year: 2026, month: 3, day: 8)!))), now: 3)

            let archive = dir.appendingPathComponent("копия.mindnotesbackup")
            let result = try BackupService.create(workspaceRoot: source, snapshotter: ws, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 5)
            check(result.isComplete, "копия полная")
            let originalPages = try await ws.allPages()
            let originalValues = try await ws.recordValues(page: record, database: database)
            ws.close()

            let target = dir.appendingPathComponent("restored")
            _ = try RestoreService.restore(archive: archive, to: target, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 6)
            let back = try SQLiteWorkspace.open(at: target)
            defer { back.close() }
            let pages = try await back.allPages()
            checkEqual(pages.map(\.id).sorted { $0.uuidString < $1.uuidString }, originalPages.map(\.id).sorted { $0.uuidString < $1.uuidString }, "те же страницы")
            checkEqual(Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.parentID) }), Dictionary(uniqueKeysWithValues: originalPages.map { ($0.id, $0.parentID) }), "то же дерево")
            let restored = BlockDocument(pageID: project, blocks: try await back.blocks(ofPage: project)).blocks
            let original = BlockDocument(pageID: project, blocks: blocks).blocks
            checkEqual(restored.map(\.id), original.map(\.id), "порядок блоков")
            checkEqual(restored.map(\.type), original.map(\.type), "типы блоков")
            checkEqual(try restored.map { try $0.contentJSON() }, try original.map { try $0.contentJSON() }, "содержимое блоков побайтно")
            checkEqual(restored.first?.plainText, "Жирный и ёлка 🎄", "Unicode")
            for asset in [image, video] {
                let url = try await back.assetURL(asset.id)!
                checkEqual(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(), asset.sha256, "вложение \(asset.originalName) совпадает")
            }
            let restoredDatabase = try await back.database(database.id)!
            checkEqual(try await back.recordValues(page: record, database: restoredDatabase), originalValues, "свойства записи")
            checkEqual(try await back.backlinks(to: other).map(\.pageID), [project], "ссылка между страницами")
        }
    }

    await test("AT-05: переименование страницы, на которую ссылаются, не ломает ссылку и обратную ссылку") {
        try await withTempDir { dir in
            let ws = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "A")
            defer { ws.close() }
            let from = UUID(), to = UUID()
            _ = try await ws.createPage(parent: nil, title: "Откуда", id: from, now: 1)
            _ = try await ws.createPage(parent: nil, title: "Цель", id: to, now: 1)
            var batch = SaveBatch()
            let link = Block(id: UUID(), pageID: from, sortKey: "a0", content: BlockContent(runs: [TextRun("Цель", marks: [PageLink.mark(to)])]), createdAt: 1)
            batch.upserts[link.id] = link
            try await ws.commit(batch)
            var rename = SaveBatch()
            rename.titles[to] = "Новая цель"
            try await ws.commit(rename)
            checkEqual(try await ws.page(to)?.title, "Новая цель")
            checkEqual(try await ws.backlinks(to: to).map(\.pageID), [from], "обратная ссылка после переименования")
            let marks = try await ws.blocks(ofPage: from).first?.content?.runs.flatMap(\.marks) ?? []
            check(marks.contains(PageLink.mark(to)), "ссылка ведёт по UUID, а не по заголовку")
            let hits = try await ws.search("Новая")
            check(hits.contains { $0.pageID == to }, "новый заголовок находится")
        }
    }
}
