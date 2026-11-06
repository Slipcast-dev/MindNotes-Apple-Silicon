import CryptoKit
import Foundation

/// What an update patch does to the installed application: for every file of the new version it says whether the file
/// stays as it is, is new, or is rebuilt from the old one with a binary delta. Files that are not listed are removed.
struct PatchManifest: Codable, Equatable {
    static let formatVersion = 1

    struct Entry: Codable, Equatable {
        /// Relative to `Grizzly.app`.
        var path: String
        /// SHA-256 of the file in the new version; checked after the patch is applied.
        var sha256: String
        /// POSIX permission bits (executables keep theirs).
        var mode: Int
        /// "keep", "add" (the blob is the whole file) or "delta" (the blob rebuilds the file from the old one).
        var op: String
        var oldSHA256: String?
        /// Name inside the patch archive's `blobs` folder.
        var blob: String?
    }

    var format: Int
    var bundleID: String
    var from: String
    var to: String
    var files: [Entry]
}

struct PatchError: Error { let message: String }

enum AppPatch {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A manifest path may only point inside the application folder.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != ".." && $0 != "." && !$0.isEmpty }
    }

    /// Every regular file under `root`, as relative paths. A symbolic link is refused: patches only know plain files.
    static func listFiles(in root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else {
            throw PatchError(message: "cannot read \(root.path)")
        }
        let base = root.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { throw PatchError(message: "symbolic link in the bundle: \(url.path)") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            result.append(String(full.dropFirst(base.count + 1)))
        }
        return result.sorted()
    }

    static func bundleInfo(_ app: URL) throws -> (id: String, version: String) {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let id = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String else {
            throw PatchError(message: "no Info.plist in \(app.path)")
        }
        return (id, version)
    }

    private static func run(_ path: String, _ args: [String], in directory: URL? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = directory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Building (release tooling)

    /// Compares two builds of the application and packs the difference into `output` (a zip archive).
    static func build(oldApp: URL, newApp: URL, output: URL) throws {
        let fm = FileManager.default
        let old = try bundleInfo(oldApp), new = try bundleInfo(newApp)
        guard old.id == new.id else { throw PatchError(message: "the two bundles are different applications") }
        let work = fm.temporaryDirectory.appendingPathComponent("grizzly-patch-\(UUID().uuidString)")
        let blobs = work.appendingPathComponent("blobs")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let oldFiles = Set(try listFiles(in: oldApp))
        var entries: [PatchManifest.Entry] = []
        for (n, path) in try listFiles(in: newApp).enumerated() {
            let newURL = newApp.appendingPathComponent(path)
            let data = try Data(contentsOf: newURL)
            let mode = ((try fm.attributesOfItem(atPath: newURL.path))[.posixPermissions] as? Int) ?? 0o644
            var entry = PatchManifest.Entry(path: path, sha256: sha256(data), mode: mode, op: "add")
            if oldFiles.contains(path) {
                let oldData = try Data(contentsOf: oldApp.appendingPathComponent(path))
                entry.oldSHA256 = sha256(oldData)
                if entry.oldSHA256 == entry.sha256 {
                    entry.op = "keep"
                } else {
                    let delta = BinaryDelta.make(old: oldData, new: data)
                    // A delta that saves little is not worth the risk of a mismatch: send the file itself.
                    if delta.count < data.count * 9 / 10 {
                        entry.op = "delta"
                        entry.blob = "\(n)"
                        try delta.write(to: blobs.appendingPathComponent("\(n)"))
                    }
                }
            }
            if entry.op == "add" {
                entry.blob = "\(n)"
                try data.write(to: blobs.appendingPathComponent("\(n)"))
            }
            if entry.op != "delta" { entry.oldSHA256 = nil }
            entries.append(entry)
        }
        let manifest = PatchManifest(format: PatchManifest.formatVersion, bundleID: new.id, from: old.version, to: new.version, files: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: work.appendingPathComponent("manifest.json"))

        try? fm.removeItem(at: output)
        guard run("/usr/bin/zip", ["-qr", "-X", "-9", output.path, "manifest.json", "blobs"], in: work) else {
            throw PatchError(message: "zip failed")
        }
    }

    // MARK: Applying (in the app)

    /// Builds the new version of the application next to the installed one: the installed copy is duplicated and the
    /// patch is applied to the duplicate. Every file of the result is checked against the manifest, so a patch that does
    /// not fit this installation (or a damaged one) is refused instead of producing a broken application.
    static func apply(patch archive: URL, to installed: URL, from currentVersion: String, to expectedVersion: String,
                      bundleID: String, work: URL) throws -> URL {
        let fm = FileManager.default
        let unpacked = work.appendingPathComponent("patch")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) else { throw PatchError(message: "cannot unpack the patch") }

        let manifest = try JSONDecoder().decode(PatchManifest.self, from: Data(contentsOf: unpacked.appendingPathComponent("manifest.json")))
        guard manifest.format == PatchManifest.formatVersion, manifest.bundleID == bundleID,
              UpdateCheck.normalized(manifest.from) == UpdateCheck.normalized(currentVersion),
              UpdateCheck.normalized(manifest.to) == UpdateCheck.normalized(expectedVersion) else {
            throw PatchError(message: "the patch is for another version")
        }
        guard Set(manifest.files.map(\.path)).count == manifest.files.count, manifest.files.allSatisfy({ isSafe($0.path) }) else {
            throw PatchError(message: "unsafe paths in the patch")
        }

        let staged = work.appendingPathComponent("Grizzly.app")
        try? fm.removeItem(at: staged)
        guard run("/usr/bin/ditto", [installed.path, staged.path]) else { throw PatchError(message: "cannot copy the installed application") }

        for entry in manifest.files where entry.op != "keep" {
            let target = staged.appendingPathComponent(entry.path)
            var data: Data
            switch entry.op {
            case "add":
                guard let blob = entry.blob, let d = blobData(blob, in: unpacked) else { throw PatchError(message: "missing data for \(entry.path)") }
                data = d
            case "delta":
                guard let blob = entry.blob, let delta = blobData(blob, in: unpacked), let oldHash = entry.oldSHA256,
                      let old = try? Data(contentsOf: target), sha256(old) == oldHash else {
                    throw PatchError(message: "the installed \(entry.path) is not the expected one")
                }
                data = try BinaryDelta.apply(old: old, delta: delta)
            default:
                throw PatchError(message: "unknown operation")
            }
            guard sha256(data) == entry.sha256 else { throw PatchError(message: "wrong result for \(entry.path)") }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try data.write(to: target)
        }

        // Files the new version no longer has.
        let wanted = Set(manifest.files.map(\.path))
        for path in try listFiles(in: staged) where !wanted.contains(path) { try fm.removeItem(at: staged.appendingPathComponent(path)) }
        if let walker = fm.enumerator(at: staged, includingPropertiesForKeys: [.isDirectoryKey]) {
            let dirs = (walker.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) where (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
            }
        }

        // Final check of the whole result.
        for entry in manifest.files {
            let url = staged.appendingPathComponent(entry.path)
            guard let data = try? Data(contentsOf: url), sha256(data) == entry.sha256 else {
                throw PatchError(message: "the result differs from the release at \(entry.path)")
            }
            try fm.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: url.path)
        }
        return staged
    }

    private static func blobData(_ name: String, in unpacked: URL) -> Data? {
        guard !name.isEmpty, name.allSatisfy(\.isNumber) else { return nil }
        return try? Data(contentsOf: unpacked.appendingPathComponent("blobs/\(name)"))
    }
}
