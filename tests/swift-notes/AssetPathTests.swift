import Foundation
import CryptoKit

/// Пути вложений из SQLite не должны выводить за пределы пространства (аудит: workspace-asset-path-traversal).
/// Все файлы — внутри временного каталога теста; «внешний» маркер лежит рядом с пространством.
func runAssetPathTests() async {
    let fm = FileManager.default
    let marker = Data("контрольный-маркер".utf8)

    /// Пространство `w` и соседняя папка `outside` с маркером `secret.txt`.
    func setup(_ dir: URL) throws -> (w: URL, outside: URL, secret: URL) {
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try marker.write(to: secret)
        return (dir.appendingPathComponent("w"), outside, secret)
    }

    func insertAsset(_ db: SQLiteConnection, id: UUID, rel: String, name: String = "файл.txt") throws {
        try db.run("INSERT INTO assets(id, rel_path, original_name, byte_size, sha256, created_at) VALUES(?,?,?,?,?,?)",
                   [SQLValue(id), .text(rel), .text(name), .int(1), .text("00"), .int(1)])
    }

    await test("Вложения: форма пути и совпадение с идентификатором") {
        let id = UUID()
        let lower = id.uuidString.lowercased()
        check(AssetPath.isValid("assets/\(lower.prefix(2))/\(lower).png", for: id))
        check(AssetPath.isValid("assets/ab/\(lower)", for: id), "подкаталог не обязан совпадать с префиксом (как в прежних данных)")
        check(!AssetPath.isValid("assets/ab/\(UUID().uuidString.lowercased()).png", for: id), "чужой UUID в имени")
        for bad in ["../outside.txt", "/etc/hosts", "assets/ab/../../x", "assets//\(lower)", "assets/ab/\(lower)/x",
                    "assets2/ab/\(lower)", "./assets/ab/\(lower)", "assets/ab/\(lower).p/g", "assets/ab/\(lower).", ""] {
            check(!AssetPath.isValid(bad, for: id), "отклонён: \(bad)")
        }
    }

    await test("Вложения: корректные и отсутствующие файлы работают, недопустимый rel_path не открывается") {
        try await withTempDir { dir in
            let (w, _, secret) = try setup(dir)
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let src = dir.appendingPathComponent("фото.png")
            try Data("png".utf8).write(to: src)
            let good = try await ws.addAsset(copying: src, now: 1)
            let ghost = UUID()
            let ghostRel = "assets/\(ghost.uuidString.lowercased().prefix(2))/\(ghost.uuidString.lowercased()).bin"
            try ws.maintenanceWrite { try insertAsset($0, id: ghost, rel: ghostRel) }
            ws.close()

            // Штатные данные: пространство открывается, существующее и отсутствующее вложения разрешаются внутри него.
            let re = try SQLiteWorkspace.open(at: w)
            let goodURL = try await re.assetURL(good.id)
            checkEqual(goodURL?.standardizedFileURL.path, w.appendingPathComponent(good.relPath).standardizedFileURL.path)
            checkEqual(try re.assetFileURLSync(good.id)?.lastPathComponent, goodURL?.lastPathComponent)
            let ghostURL = try await re.assetURL(ghost)
            check(ghostURL != nil && !fm.fileExists(atPath: ghostURL!.path), "отсутствующее корректное вложение остаётся допустимым")
            try await re.deleteAsset(good.id)
            check(!fm.fileExists(atPath: goodURL!.path), "штатное удаление работает")
            re.close()

            let id = UUID()
            for bad in ["../outside/secret.txt", secret.path, "assets/../../outside/secret.txt",
                        "assets/ab/\(UUID().uuidString.lowercased()).txt"] {
                let db = try SQLiteConnection(path: w.appendingPathComponent("workspace.sqlite").path)
                try insertAsset(db, id: id, rel: bad)
                db.close()
                let error = await checkThrows("открытие с rel_path \(bad)") { try SQLiteWorkspace.open(at: w) }
                if case .corrupted(let detail)? = error as? WorkspaceError {
                    check(detail.contains("недопустимый путь вложения"), "понятная причина: \(detail)")
                } else { check(false, "ожидалась ошибка повреждения: \(String(describing: error))") }
                let fix = try SQLiteConnection(path: w.appendingPathComponent("workspace.sqlite").path)
                try fix.run("DELETE FROM assets WHERE id=?", [SQLValue(id)])
                fix.close()
            }
            checkEqual(try Data(contentsOf: secret), marker, "внешний маркер не тронут")
            _ = try SQLiteWorkspace.open(at: w)
        }
    }

    await test("Вложения: ссылки внутри assets не дают читать, экспортировать и удалять внешние файлы") {
        enum Link: CaseIterable { case file, subdir, assetsDir }
        for link in Link.allCases {
            try await withTempDir { dir in
                let (w, outside, secret) = try setup(dir)
                let ws = try SQLiteWorkspace.create(at: w, name: "A")
                let id = UUID()
                let name = id.uuidString.lowercased() + ".txt"
                let rel = "assets/ab/\(name)"
                switch link {
                case .file:
                    try fm.createDirectory(at: w.appendingPathComponent("assets/ab"), withIntermediateDirectories: true)
                    try fm.createSymbolicLink(at: w.appendingPathComponent(rel), withDestinationURL: secret)
                case .subdir:
                    try marker.write(to: outside.appendingPathComponent(name))
                    try fm.createSymbolicLink(at: w.appendingPathComponent("assets/ab"), withDestinationURL: outside)
                case .assetsDir:
                    try fm.createDirectory(at: outside.appendingPathComponent("ab"), withIntermediateDirectories: true)
                    try marker.write(to: outside.appendingPathComponent("ab/\(name)"))
                    try fm.removeItem(at: w.appendingPathComponent("assets"))
                    try fm.createSymbolicLink(at: w.appendingPathComponent("assets"), withDestinationURL: outside)
                }
                let outsideFile = link == .file ? secret : (link == .subdir ? outside.appendingPathComponent(name) : outside.appendingPathComponent("ab/\(name)"))
                try ws.maintenanceWrite { try insertAsset($0, id: id, rel: rel) }
                let record = AssetRecord(id: id, relPath: rel, originalName: "файл.txt", mime: nil, byteSize: 1, sha256: "00", createdAt: 1)
                let page = UUID()
                _ = try await ws.createPage(parent: nil, title: "Стр", id: page, now: 1)
                let fragment = AtomData.attachment(type: .file, asset: record)
                var batch = SaveBatch()
                let block = Block(id: UUID(), pageID: page, parentID: nil, sortKey: "a0", type: .file, contentVersion: 1,
                                  contentJSON: fragment.json, plainText: fragment.plain, createdAt: 1, updatedAt: 1)
                batch.upserts[block.id] = block
                try await ws.commit(batch)

                await checkThrows("\(link): assetURL") { try await ws.assetURL(id) }
                await checkThrows("\(link): assetFileURLSync") { try ws.assetFileURLSync(id) }
                await checkThrows("\(link): deleteAsset") { try await ws.deleteAsset(id) }
                checkEqual(try ws.maintenanceWrite { try $0.scalarText("SELECT rel_path FROM assets WHERE id=?", [SQLValue(id)]) }, Optional(rel),
                           "\(link): запись не удалена до файловой операции")

                let out = dir.appendingPathComponent("export")
                let summary = try await WorkspaceExport.exportAll(source: ws, to: out, untitled: "Без названия")
                checkEqual(summary.assets, 0, "\(link): внешний файл не скопирован")
                checkEqual(summary.missingAssets, 1, "\(link): вложение учтено как отсутствующее")
                let copied = (fm.enumerator(at: out, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .contains { (try? Data(contentsOf: $0)) == marker }
                check(!copied, "\(link): маркера нет в экспорте")

                await checkThrows("\(link): резервная копия") {
                    try BackupService.create(workspaceRoot: w, snapshotter: ws, inspector: SQLiteSnapshotInspector(),
                                             destination: dir.appendingPathComponent("b.mindnotesbackup"), appVersion: "t", now: 1)
                }
                checkEqual(try Data(contentsOf: outsideFile), marker, "\(link): внешний файл не изменён")
                checkEqual(try Data(contentsOf: secret), marker, "\(link): маркер не изменён")
                check(fm.fileExists(atPath: outside.path), "\(link): внешний каталог на месте")
                ws.close()
            }
        }
    }

    await test("Restore: недопустимый путь в assets или в manifest.missing не восстанавливается") {
        try await withTempDir { dir in
            let (w, _, secret) = try setup(dir)
            let ws = try SQLiteWorkspace.create(at: w, name: "A")
            let okID = UUID()
            let okRel = "assets/\(okID.uuidString.lowercased().prefix(2))/\(okID.uuidString.lowercased()).bin"
            try ws.maintenanceWrite { try insertAsset($0, id: okID, rel: okRel) }
            let cleanDB = dir.appendingPathComponent("clean.sqlite")
            try ws.snapshotDatabase(to: cleanDB)
            let evilID = UUID()
            try ws.maintenanceWrite { try insertAsset($0, id: evilID, rel: "../outside/secret.txt") }
            let evilDB = dir.appendingPathComponent("evil.sqlite")
            try ws.snapshotDatabase(to: evilDB)
            ws.close()

            func archive(_ db: URL, missing: [String], name: String) throws -> URL {
                let data = try Data(contentsOf: db)
                let file = BackupManifest.File(path: BackupService.databaseName, size: Int64(data.count), sha256: Tar.hex(SHA256.hash(data: data)))
                let manifest = BackupManifest(format: BackupService.formatVersion, schema_version: Migrations.supportedVersion,
                                              workspace_id: UUID().uuidString.lowercased(), app_version: "t", created_at: 1,
                                              files: [file], missing: missing)
                let url = dir.appendingPathComponent(name)
                try craftArchive(url, entries: [(BackupService.databaseName, data)], manifest: manifest)
                return url
            }

            let target = dir.appendingPathComponent("restored")
            for (label, url) in [
                ("путь только в SQLite и в missing", try archive(evilDB, missing: [okRel, "../outside/secret.txt"], name: "a1.tar")),
                ("лишний путь в missing", try archive(cleanDB, missing: [okRel, "../outside/secret.txt"], name: "a2.tar")),
                ("абсолютный путь в missing", try archive(cleanDB, missing: [okRel, secret.path], name: "a3.tar")),
            ] {
                await checkThrows(label) { try RestoreService.restore(archive: url, to: target, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 1) }
                check(!fm.fileExists(atPath: target.path) && !fm.fileExists(atPath: target.path + ".restoring"), "\(label): каталог не появился")
            }

            // Корректное отсутствующее вложение по-прежнему допустимо.
            try RestoreService.restore(archive: try archive(cleanDB, missing: [okRel], name: "ok.tar"), to: target,
                                       inspector: SQLiteSnapshotInspector(), newID: UUID(), now: 1)
            let re = try SQLiteWorkspace.open(at: target)
            let url = try await re.assetURL(okID)
            check(url != nil && !fm.fileExists(atPath: url!.path), "отсутствующий файл восстановлен как отсутствующий")
            re.close()
            checkEqual(try Data(contentsOf: secret), marker, "внешний маркер не тронут")
        }
    }
}
