import Foundation
import CryptoKit

struct BackupManifest: Codable, Equatable {
    struct File: Codable, Equatable {
        var path: String
        var size: Int64
        var sha256: String
    }
    var format: Int
    var schema_version: Int
    var workspace_id: String
    var app_version: String
    var created_at: Int64
    var files: [File]
    var missing: [String]

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

struct BackupResult: Equatable {
    var url: URL
    var manifest: BackupManifest
    /// Копия с отсутствующими вложениями не считается полной.
    var isComplete: Bool { manifest.missing.isEmpty }
}

/// Полный архив пространства: согласованный снимок базы, вложения по снимку ссылок, манифест с SHA-256.
enum BackupService {
    static let formatVersion = 1
    static let databaseName = "workspace.sqlite"
    static let manifestName = "manifest.json"
    static let manifestHashName = "manifest.sha256"

    /// Создаёт архив атомарно: пишется `.partial`, манифест идёт последним, затем rename и проверка чтением.
    @discardableResult
    static func create(workspaceRoot: URL, snapshotter: DatabaseSnapshotter, inspector: SnapshotInspector,
                       destination: URL, appVersion: String, now: Int64) throws -> BackupResult {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = parent.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let snapshot = work.appendingPathComponent(databaseName)
        try snapshotter.snapshotDatabase(to: snapshot)
        let info = try inspector.inspect(snapshot)

        let partial = destination.appendingPathExtension("partial")
        fm.createFile(atPath: partial.path, contents: nil)
        var keepPartial = false
        defer { if !keepPartial { try? fm.removeItem(at: partial) } }
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close() }

        var files: [BackupManifest.File] = []
        var missing: [String] = []
        files.append(try write(file: snapshot, as: databaseName, to: out, mtime: now / 1000))

        // Вложения по списку из снимка: файлы неизменяемы, уборка на время копирования не выполняется.
        for asset in info.assets.sorted(by: { $0.relPath < $1.relPath }) {
            // Недопустимый путь или ссылка наружу — ошибка, а не «отсутствующее вложение»: чужой файл не попадает в копию.
            let file: URL
            do { file = try AssetPath.resolve(asset.relPath, id: asset.id, in: workspaceRoot) }
            catch { throw WorkspaceError.backupInvalid("недопустимый путь вложения: \(asset.relPath)") }
            guard fm.fileExists(atPath: file.path), let actual = try? sha256(of: file), actual == asset.sha256 else {
                missing.append(asset.relPath)
                continue
            }
            files.append(try write(file: file, as: asset.relPath, to: out, mtime: now / 1000))
        }

        let manifest = BackupManifest(format: formatVersion, schema_version: info.schemaVersion,
                                      workspace_id: info.workspaceID.uuidString.lowercased(), app_version: appVersion,
                                      created_at: now, files: files, missing: missing)
        let manifestData = try manifest.encoded()
        try write(data: manifestData, as: manifestName, to: out, mtime: now / 1000)
        try write(data: Data(Tar.hex(SHA256.hash(data: manifestData)).utf8), as: manifestHashName, to: out, mtime: now / 1000)
        try out.write(contentsOf: Data(count: Tar.blockSize * 2))
        try out.synchronize()
        try out.close()

        // «Копия создана» означает, что она читается и совпадает с манифестом. Проверка до замены: прежний архив не теряется.
        _ = try RestoreService.verify(archive: partial)
        guard rename(partial.path, destination.path) == 0 else {
            throw WorkspaceError.storage(code: errno, detail: String(cString: strerror(errno)))
        }
        keepPartial = true
        return BackupResult(url: destination, manifest: manifest)
    }

    private static func write(file: URL, as path: String, to out: FileHandle, mtime: Int64) throws -> BackupManifest.File {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let size = Int64(try input.seekToEnd())
        try input.seek(toOffset: 0)
        try out.write(contentsOf: try Tar.header(path: path, size: size, mtime: mtime))
        var hash = SHA256()
        var written: Int64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            try out.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
        guard written == size else { throw WorkspaceError.backupInvalid("файл изменился при копировании: \(path)") }
        try out.write(contentsOf: Data(count: Tar.padding(size)))
        return BackupManifest.File(path: path, size: size, sha256: Tar.hex(hash.finalize()))
    }

    private static func write(data: Data, as path: String, to out: FileHandle, mtime: Int64) throws {
        try out.write(contentsOf: try Tar.header(path: path, size: Int64(data.count), mtime: mtime))
        try out.write(contentsOf: data)
        try out.write(contentsOf: Data(count: Tar.padding(Int64(data.count))))
    }

    static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return Tar.hex(hash.finalize())
    }
}
