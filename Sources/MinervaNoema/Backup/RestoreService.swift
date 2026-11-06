import Foundation
import CryptoKit

/// Восстановление всегда идёт в новый каталог; исходное пространство не затрагивается.
enum RestoreService {
    /// `assets/<2hex>/<uuid>[.ext]`. Имена проверяются до любого обращения к файловой системе.
    static func isAllowedAssetPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "assets", parts[1].count == 2,
              parts[1].allSatisfy({ $0.isHexDigit }) else { return false }
        let file = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(file.count), UUID(uuidString: String(file[0])) != nil else { return false }
        if file.count == 2 { return !file[1].isEmpty && file[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        return true
    }

    private static func isAllowed(_ path: String) -> Bool {
        path == BackupService.databaseName || path == BackupService.manifestName || path == BackupService.manifestHashName || isAllowedAssetPath(path)
    }

    /// Читает архив целиком: проверяет имена, хэши и состав. `extractTo` — куда распаковать; nil — только проверка.
    @discardableResult
    static func verify(archive: URL, extractTo: URL? = nil) throws -> BackupManifest {
        let fm = FileManager.default
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: archive) }
        catch { throw WorkspaceError.backupInvalid("не удалось открыть архив") }
        defer { try? input.close() }
        let total = Int64(try input.seekToEnd())
        try input.seek(toOffset: 0)

        var seen: [String: (size: Int64, sha: String)] = [:]
        var manifestData: Data?
        var manifestHash: Data?
        var offset: Int64 = 0
        var sawEnd = false

        while offset < total {
            guard let block = try input.read(upToCount: Tar.blockSize), block.count == Tar.blockSize else {
                throw WorkspaceError.backupInvalid("архив обрезан")
            }
            offset += Int64(Tar.blockSize)
            guard let entry = try Tar.parse(block) else { sawEnd = true; break }
            guard isAllowed(entry.path) else { throw WorkspaceError.backupInvalid("недопустимый путь: \(entry.path)") }
            guard seen[entry.path] == nil else { throw WorkspaceError.backupInvalid("повторяющаяся запись: \(entry.path)") }
            guard entry.size >= 0, entry.size <= total - offset else { throw WorkspaceError.backupInvalid("архив обрезан") }

            let keepInMemory = entry.path == BackupService.manifestName || entry.path == BackupService.manifestHashName
            if keepInMemory && entry.size > 64 << 20 { throw WorkspaceError.backupInvalid("манифест слишком большой") }
            var out: FileHandle?
            if let extractTo, !keepInMemory {
                let target = extractTo.appendingPathComponent(entry.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: target.path, contents: nil)
                out = try FileHandle(forWritingTo: target)
            }
            defer { try? out?.close() }

            var hash = SHA256()
            var memory = Data()
            var left = entry.size
            while left > 0 {
                guard let chunk = try input.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty else {
                    throw WorkspaceError.backupInvalid("архив обрезан")
                }
                hash.update(data: chunk)
                if keepInMemory { memory.append(chunk) }
                try out?.write(contentsOf: chunk)
                left -= Int64(chunk.count)
            }
            try out?.synchronize()
            offset += entry.size
            let pad = Tar.padding(entry.size)
            if pad > 0 {
                guard let skip = try input.read(upToCount: pad), skip.count == pad else { throw WorkspaceError.backupInvalid("архив обрезан") }
                offset += Int64(pad)
            }
            seen[entry.path] = (entry.size, Tar.hex(hash.finalize()))
            if entry.path == BackupService.manifestName { manifestData = memory }
            if entry.path == BackupService.manifestHashName { manifestHash = memory }
        }

        guard sawEnd else { throw WorkspaceError.backupInvalid("архив обрезан") }
        guard let manifestData, let manifestHash else { throw WorkspaceError.backupInvalid("нет манифеста: архив неполон") }
        guard String(decoding: manifestHash, as: UTF8.self) == Tar.hex(SHA256.hash(data: manifestData)) else {
            throw WorkspaceError.backupInvalid("манифест повреждён")
        }
        let manifest: BackupManifest
        do { manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData) }
        catch { throw WorkspaceError.backupInvalid("манифест не читается") }
        guard manifest.format <= BackupService.formatVersion else { throw WorkspaceError.backupInvalid("архив новее этой версии приложения") }

        let listed = Set(manifest.files.map(\.path))
        let present = Set(seen.keys).subtracting([BackupService.manifestName, BackupService.manifestHashName])
        guard listed == present else { throw WorkspaceError.backupInvalid("состав архива не совпадает с манифестом") }
        for file in manifest.files {
            guard let got = seen[file.path], got.size == file.size, got.sha == file.sha256 else {
                throw WorkspaceError.backupInvalid("контрольная сумма не совпала: \(file.path)")
            }
        }
        return manifest
    }

    /// Восстанавливает в новый или пустой каталог. Работа идёт рядом, каталог появляется только после всех проверок.
    @discardableResult
    static func restore(archive: URL, to target: URL, inspector: SnapshotInspector, newID: UUID, now: Int64) throws -> BackupManifest {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
            let items = isDir.boolValue ? ((try? fm.contentsOfDirectory(atPath: target.path)) ?? []) : ["файл"]
            guard items.filter({ $0 != ".DS_Store" }).isEmpty else { throw WorkspaceError.restoreTargetNotEmpty(target.path) }
        }
        let work = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".restoring", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var done = false
        defer { if !done { try? fm.removeItem(at: work) } }

        let manifest = try verify(archive: archive, extractTo: work)
        let db = work.appendingPathComponent(BackupService.databaseName)
        let info = try inspector.inspect(db)
        guard info.schemaVersion == manifest.schema_version else { throw WorkspaceError.backupInvalid("версия схемы не совпадает с манифестом") }
        guard info.schemaVersion <= inspector.supportedSchemaVersion else {
            throw WorkspaceError.schemaTooNew(found: info.schemaVersion, supported: inspector.supportedSchemaVersion)
        }
        let files = Set(manifest.files.map(\.path)), missing = Set(manifest.missing)
        for asset in info.assets where !files.contains(asset.relPath) && !missing.contains(asset.relPath) {
            throw WorkspaceError.backupInvalid("нет вложения: \(asset.originalName)")
        }
        try inspector.assignNewIdentity(db, newID: newID, now: now)
        try fm.createDirectory(at: work.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: work, to: target)
        done = true
        return manifest
    }
}
