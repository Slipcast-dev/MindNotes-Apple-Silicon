import Foundation
import CryptoKit

/// Собирает архив вручную, чтобы проверить чтение враждебных данных.
func craftArchive(_ url: URL, entries: [(String, Data)], manifest: BackupManifest? = nil, typeflag: UInt8? = nil) throws {
    var out = Data()
    for (path, data) in entries {
        var header = try Tar.header(path: path, size: Int64(data.count), mtime: 0)
        if let typeflag {
            header[156] = typeflag
            // Пересчёт контрольной суммы, чтобы проверялся именно тип записи.
            for i in 148..<156 { header[i] = 32 }
            let sum = header.reduce(0) { $0 + Int($1) }
            let s = String(format: "%06o", sum)
            header.replaceSubrange(148..<154, with: Data(s.utf8))
            header[154] = 0
            header[155] = 32
        }
        out.append(header)
        out.append(data)
        out.append(Data(count: Tar.padding(Int64(data.count))))
    }
    if let manifest {
        let m = try manifest.encoded()
        out.append(try Tar.header(path: BackupService.manifestName, size: Int64(m.count), mtime: 0))
        out.append(m); out.append(Data(count: Tar.padding(Int64(m.count))))
        let h = Data(Tar.hex(SHA256.hash(data: m)).utf8)
        out.append(try Tar.header(path: BackupService.manifestHashName, size: Int64(h.count), mtime: 0))
        out.append(h); out.append(Data(count: Tar.padding(Int64(h.count))))
    }
    out.append(Data(count: Tar.blockSize * 2))
    try out.write(to: url)
}

func emptyManifest(_ files: [BackupManifest.File] = []) -> BackupManifest {
    BackupManifest(format: 1, schema_version: 1, workspace_id: UUID().uuidString, app_version: "t", created_at: 0, files: files, missing: [])
}

func runBackupTests() async {
    await test("Backup: архив с вложением, параллельная запись, чтение штатным tar") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let page = UUID()
            _ = try await ws.createPage(parent: nil, title: "С", id: page, now: 1)
            let body = Data("вложение 📎".utf8)
            let assetID = UUID()
            let rel = "assets/ab/\(assetID.uuidString.lowercased()).txt"
            try FileManager.default.createDirectory(at: w.appendingPathComponent("assets/ab"), withIntermediateDirectories: true)
            try body.write(to: w.appendingPathComponent(rel))
            let hash = Tar.hex(SHA256.hash(data: body))
            let ghost = UUID()
            try ws.maintenanceWrite { db in
                try db.run("INSERT INTO assets(id, rel_path, original_name, byte_size, sha256, created_at) VALUES(?,?,?,?,?,?)",
                           [SQLValue(assetID), .text(rel), .text("Файл.txt"), .int(Int64(body.count)), .text(hash), .int(1)])
            }
            let task = Task {
                for i in 0..<20 {
                    var b = SaveBatch()
                    let id = UUID()
                    b.upserts[id] = Block(id: id, pageID: page, sortKey: "a\(i)", content: BlockContent(text: "строка \(i)"), createdAt: 1)
                    try await ws.commit(b)
                }
            }
            let archive = dir.appendingPathComponent("copy.grizzlybackup")
            let r = try BackupService.create(workspaceRoot: w, snapshotter: ws, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 1000)
            try await task.value
            check(r.isComplete, "копия полна")
            checkEqual(Set(r.manifest.files.map(\.path)), [BackupService.databaseName, rel])
            let list = Process()
            list.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            list.arguments = ["-tf", archive.path]
            let pipe = Pipe()
            list.standardOutput = pipe
            try list.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            list.waitUntilExit()
            checkEqual(list.terminationStatus, 0, "штатный tar читает архив")
            check(output.contains(rel) && output.contains("manifest.json"), "содержимое видно: \(output)")
            check(!FileManager.default.fileExists(atPath: archive.path + ".partial"), "нет временного файла")

            // Потерянное вложение отмечается, такая копия не называется полной.
            try ws.maintenanceWrite { db in
                let lost = "assets/cd/\(ghost.uuidString.lowercased()).bin"
                try db.run("INSERT INTO assets(id, rel_path, original_name, byte_size, sha256, created_at) VALUES(?,?,?,?,?,?)",
                           [SQLValue(ghost), .text(lost), .text("Нет.bin"), .int(1), .text("00"), .int(1)])
            }
            let partial = try BackupService.create(workspaceRoot: w, snapshotter: ws, inspector: SQLiteSnapshotInspector(), destination: dir.appendingPathComponent("p.grizzlybackup"), appVersion: "t", now: 2000)
            check(!partial.isComplete, "отсутствующее вложение отмечено")
            checkEqual(partial.manifest.missing.count, 1)

            // Восстановление с вложением и новая идентичность.
            let target = dir.appendingPathComponent("restored")
            let newID = UUID()
            try RestoreService.restore(archive: archive, to: target, inspector: SQLiteSnapshotInspector(), newID: newID, now: 5)
            let re = try SQLiteWorkspace.open(at: target)
            let reid = try await re.workspaceID()
            checkEqual(reid, newID, "новый идентификатор")
            checkEqual(try Data(contentsOf: target.appendingPathComponent(rel)), body, "вложение совпадает")
            let original = try await ws.workspaceID()
            checkEqual(try re.maintenanceWrite { try $0.scalarText("SELECT value FROM workspace_meta WHERE key='restored_from'") }, Optional(original.uuidString.lowercased()))
            re.close()
            ws.close()
        }
    }

    await test("Restore: враждебные архивы отклоняются, ничего не создаётся") {
        try await withTempDir { dir in
            let inspector = SQLiteSnapshotInspector()
            let target = dir.appendingPathComponent("t")
            let attempts: [(String, [(String, Data)], BackupManifest?, UInt8?)] = [
                ("выход за каталог", [("../evil.txt", Data("x".utf8))], emptyManifest(), nil),
                ("абсолютный путь", [("/tmp/evil.txt", Data("x".utf8))], emptyManifest(), nil),
                ("вложенный выход", [("assets/ab/../../evil", Data("x".utf8))], emptyManifest(), nil),
                ("лишний файл", [("readme.txt", Data("x".utf8))], emptyManifest(), nil),
                ("симлинк", [(BackupService.databaseName, Data())], emptyManifest(), UInt8(ascii: "2")),
                ("дубликат", [(BackupService.databaseName, Data("a".utf8)), (BackupService.databaseName, Data("b".utf8))], emptyManifest(), nil),
                ("нет манифеста", [(BackupService.databaseName, Data("a".utf8))], nil, nil),
                ("состав не совпадает", [(BackupService.databaseName, Data("a".utf8))], emptyManifest(), nil),
                ("хэш не совпадает", [(BackupService.databaseName, Data("a".utf8))],
                 emptyManifest([.init(path: BackupService.databaseName, size: 1, sha256: "00")]), nil),
                ("база не SQLite", [(BackupService.databaseName, Data("a".utf8))],
                 emptyManifest([.init(path: BackupService.databaseName, size: 1, sha256: Tar.hex(SHA256.hash(data: Data("a".utf8))))]), nil),
            ]
            for (i, (name, entries, manifest, flag)) in attempts.enumerated() {
                let url = dir.appendingPathComponent("evil\(i).tar")
                try craftArchive(url, entries: entries, manifest: manifest, typeflag: flag)
                await checkThrows(name) { try RestoreService.restore(archive: url, to: target, inspector: inspector, newID: UUID(), now: 1) }
                check(!FileManager.default.fileExists(atPath: target.path), "\(name): каталог не появился")
                check(!FileManager.default.fileExists(atPath: target.path + ".restoring"), "\(name): нет следов")
            }
            check(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil.txt").path), "файл вне каталога не создан")
        }
    }

    await test("Backup: обрезка и повреждение обнаруживаются, цель должна быть пустой") {
        try await withTempDir { dir in
            let w = dir.appendingPathComponent("w")
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let archive = dir.appendingPathComponent("a.grizzlybackup")
            try BackupService.create(workspaceRoot: w, snapshotter: ws, inspector: SQLiteSnapshotInspector(), destination: archive, appVersion: "t", now: 1)
            ws.close()
            let bytes = try Data(contentsOf: archive)
            for cut in [100, Tar.blockSize, bytes.count / 2, bytes.count - Tar.blockSize * 3] {
                let t = dir.appendingPathComponent("cut\(cut)")
                try bytes.prefix(cut).write(to: t)
                await checkThrows("обрезка \(cut)") { try RestoreService.verify(archive: t) }
            }
            var flipped = bytes
            flipped[Tar.blockSize + 2000] ^= 0xFF
            let f = dir.appendingPathComponent("flip")
            try flipped.write(to: f)
            await checkThrows("повреждённый байт") { try RestoreService.verify(archive: f) }

            let busy = dir.appendingPathComponent("busy")
            try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
            try Data("личное".utf8).write(to: busy.appendingPathComponent("заметка.txt"))
            let error = await checkThrows("непустая цель") { try RestoreService.restore(archive: archive, to: busy, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 1) }
            expectError(error, .restoreTargetNotEmpty(busy.path))
            check(FileManager.default.fileExists(atPath: busy.appendingPathComponent("заметка.txt").path), "файлы не тронуты")
        }
    }

    await test("Запрещённые имена вложений") {
        check(RestoreService.isAllowedAssetPath("assets/ab/\(UUID().uuidString).png"))
        check(RestoreService.isAllowedAssetPath("assets/0f/\(UUID().uuidString)"))
        check(!RestoreService.isAllowedAssetPath("assets/zz/\(UUID().uuidString)"), "не hex")
        check(!RestoreService.isAllowedAssetPath("assets/ab/../../x"))
        check(!RestoreService.isAllowedAssetPath("assets/ab/x.png"))
        check(!RestoreService.isAllowedAssetPath("assets/ab/\(UUID().uuidString)./x"))
    }
}
