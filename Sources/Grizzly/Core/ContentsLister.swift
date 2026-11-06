import Foundation

/// One line of a contents listing: a file or a folder, with everything below a folder in `children`.
struct ContentEntry: Identifiable, Hashable {
    /// Path inside the listed container; unique within a listing.
    var id: String
    var name: String
    var isDirectory: Bool
    /// Bytes; for a folder the sum of what is below it. Nil when unknown (a package, a virtual entry).
    var size: Int64?
    /// Nil for a file (what `List(_:children:)` expects), the entries below for a folder.
    var children: [ContentEntry]?
}

struct ContentsListing {
    var entries: [ContentEntry] = []
    var files = 0
    var folders = 0
    var size: Int64 = 0
    /// The container holds more than was read; only the first part is listed.
    var truncated = false
}

struct ContentsError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Lists what is inside a folder, an archive (zip, tar, 7z, rar ...) or a disk image (dmg, iso) without opening it:
/// nothing is extracted and nothing is shown in Finder. Archives are read with the system's `bsdtar` in list mode;
/// a disk image is attached read-only and hidden, listed, and detached again.
enum ContentsLister {
    enum Kind { case folder, archive, diskImage }

    static let archiveExtensions: Set<String> = [
        "zip", "jar", "war", "apk", "epub", "tar", "tgz", "tbz", "tbz2", "txz", "7z", "rar", "cpio", "xar", "pkg", "lha", "lzh", "cab",
    ]
    static let imageExtensions: Set<String> = ["dmg", "iso", "cdr"]

    static let archiveLimit = 20_000
    static let folderLimit = 10_000

    /// What a path is, judged by its name: nil for an ordinary file.
    static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .diskImage }
        if archiveExtensions.contains(ext) || name.contains(".tar.") { return .archive }
        return nil
    }

    static func isContainer(_ url: URL) -> Bool { kind(of: url) != nil }

    /// Reads the contents. Blocks (a disk image can take seconds): call it off the main thread.
    static func list(_ url: URL) throws -> ContentsListing {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ContentsError("The file was not found.") }
        if isDir.boolValue { return listFolder(url) }
        switch kind(of: url) {
        case .diskImage:
            // An ISO is plain data that bsdtar reads without mounting; anything else (or an ISO it cannot read) is attached.
            if url.pathExtension.lowercased() != "dmg", let listing = try? listArchive(url), listing.files + listing.folders > 0 { return listing }
            return try listImage(url)
        case .archive, .folder, nil:
            return try listArchive(url)
        }
    }

    // MARK: Folders

    static func listFolder(_ root: URL, limit: Int = folderLimit) -> ContentsListing {
        let base = root.standardizedFileURL.path
        var items: [Item] = []
        var truncated = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                if items.count >= limit { truncated = true; break }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(base + "/") else { continue }
                let relative = String(full.dropFirst(base.count + 1))
                let isPackage = values?.isPackage == true
                let isDir = values?.isDirectory == true && !isPackage
                items.append(Item(path: relative, isDirectory: isDir, size: isDir ? nil : values?.fileSize.map(Int64.init)))
            }
        }
        var listing = tree(from: items)
        listing.truncated = truncated
        return listing
    }

    // MARK: Archives

    static func listArchive(_ url: URL, limit: Int = archiveLimit) throws -> ContentsListing {
        let result = try run("/usr/bin/bsdtar", ["-tvf", url.path], timeout: 30, lineLimit: limit + 1)
        let items = parseTarListing(String(decoding: result.out, as: UTF8.self))
        if items.isEmpty {
            if result.status != 0 { throw ContentsError(result.err.isEmpty ? "The archive could not be read." : result.err) }
        }
        var listing = tree(from: Array(items.prefix(limit)))
        listing.truncated = result.cut || items.count > limit
        return listing
    }

    /// Lines of `bsdtar -tv`: `-rw-r--r--  0 user group  1234 Oct 31 12:00 path/to/file`. The size is the number right before
    /// the date, so owner names with spaces do not matter; a symlink's ` -> target` is dropped.
    static func parseTarListing(_ text: String) -> [Item] {
        guard let regex = try? NSRegularExpression(
            pattern: "^([-dlhcbps])[rwxsStT-]{9}[+@.]?\\s+\\d+\\s+.*?\\s(\\d+)\\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\s+\\d{1,2}\\s+(?:\\d{1,2}:\\d{2}|\\d{4})\\s(.*)$") else { return [] }
        var items: [Item] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            let ns = s as NSString
            guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            let type = ns.substring(with: m.range(at: 1))
            var path = ns.substring(with: m.range(at: 3))
            if type == "l", let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
            while path.hasPrefix("./") { path.removeFirst(2) }
            let isDir = type == "d" || path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }
            if path.isEmpty || path == "." { continue }
            let size = Int64(ns.substring(with: m.range(at: 2)))
            items.append(Item(path: path, isDirectory: isDir, size: isDir ? nil : size))
        }
        return items
    }

    // MARK: Disk images

    static func listImage(_ url: URL) throws -> ContentsListing {
        let fm = FileManager.default
        let mountRoot = fm.temporaryDirectory.appendingPathComponent("grizzly-peek-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mountRoot) }

        // Read-only, not shown in Finder, no checksum pass, no auto-open. Input is closed, so an image that asks for a
        // password or for acceptance of a license fails at once instead of waiting for an answer.
        let attach = try run("/usr/bin/hdiutil",
                             ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-plist", "-mountroot", mountRoot.path, url.path],
                             timeout: 90)
        let entities = ((try? PropertyListSerialization.propertyList(from: attach.out, options: [], format: nil)) as? [String: Any])?["system-entities"] as? [[String: Any]] ?? []
        let devices = Set(entities.compactMap { ($0["dev-entry"] as? String).flatMap(wholeDisk) })
        defer { for device in devices { _ = try? run("/usr/bin/hdiutil", ["detach", device, "-force"], timeout: 60) } }

        let mounts = entities.compactMap { $0["mount-point"] as? String }
        guard attach.status == 0, !mounts.isEmpty else {
            throw ContentsError(attach.err.isEmpty ? "The image could not be read (it may need a password)." : attach.err)
        }
        if mounts.count == 1 { return listFolder(URL(fileURLWithPath: mounts[0])) }
        var combined = ContentsListing()
        for mount in mounts {
            let part = listFolder(URL(fileURLWithPath: mount))
            let name = (mount as NSString).lastPathComponent
            combined.entries.append(ContentEntry(id: name, name: name, isDirectory: true, size: part.size, children: part.entries))
            combined.files += part.files
            combined.folders += part.folders + 1
            combined.size += part.size
            combined.truncated = combined.truncated || part.truncated
        }
        return combined
    }

    /// `/dev/disk4s1` → `/dev/disk4`.
    private static func wholeDisk(_ entry: String) -> String? {
        guard let r = entry.range(of: "^/dev/disk\\d+", options: .regularExpression) else { return nil }
        return String(entry[r])
    }

    // MARK: Tree

    struct Item { var path: String; var isDirectory: Bool; var size: Int64? }

    private final class Node {
        var name: String
        var isDirectory: Bool
        var size: Int64?
        var children: [String: Node] = [:]
        init(name: String, isDirectory: Bool, size: Int64? = nil) { self.name = name; self.isDirectory = isDirectory; self.size = size }
    }

    /// Builds nested entries from flat paths. A folder that only appears as part of a path (zip files often have no entries
    /// for their folders) is created on the way.
    static func tree(from items: [Item]) -> ContentsListing {
        let root = Node(name: "", isDirectory: true)
        for item in items {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            for (i, part) in parts.enumerated() {
                let last = i == parts.count - 1
                if let next = node.children[part] {
                    if last { next.isDirectory = item.isDirectory || next.isDirectory; if !item.isDirectory { next.size = item.size } }
                    node = next
                } else {
                    let next = Node(name: part, isDirectory: last ? item.isDirectory : true, size: last && !item.isDirectory ? item.size : nil)
                    node.children[part] = next
                    node = next
                }
            }
        }
        var listing = ContentsListing()
        func convert(_ node: Node, path: String) -> ContentEntry {
            if !node.isDirectory {
                listing.files += 1
                listing.size += node.size ?? 0
                return ContentEntry(id: path, name: node.name, isDirectory: false, size: node.size, children: nil)
            }
            listing.folders += 1
            let kids = sorted(node.children.values.map { convert($0, path: path + "/" + $0.name) })
            let total = kids.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            return ContentEntry(id: path, name: node.name, isDirectory: true, size: total, children: kids)
        }
        listing.entries = sorted(root.children.values.map { convert($0, path: $0.name) })
        return listing
    }

    /// Folders first, then by name the way Finder sorts (numbers by value).
    private static func sorted(_ entries: [ContentEntry]) -> [ContentEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Running tools

    struct RunResult { var out: Data; var err: String; var status: Int32; var cut: Bool }

    /// Runs a system tool with its input closed and a time limit. Output is read as it comes; with `lineLimit` the tool
    /// is stopped once that many lines arrived (a huge archive is listed in part rather than waited for).
    static func run(_ path: String, _ args: [String], timeout: TimeInterval, lineLimit: Int? = nil, byteLimit: Int = 64_000_000) throws -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        // UTF-8 keeps non-ASCII names readable (the C locale prints them as octal escapes); the month names stay English.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw ContentsError("Could not start \((path as NSString).lastPathComponent).") }

        var errText = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = err.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if errText.count < 4000 { errText.append(chunk) }
            }
            errDone.signal()
        }
        var timedOut = false
        let killer = DispatchWorkItem { timedOut = true; if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        var data = Data()
        var lines = 0
        var cut = false
        while true {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if let lineLimit {
                lines += chunk.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
                if lines >= lineLimit { cut = true; break }
            }
            if data.count > byteLimit { cut = true; break }
        }
        if cut, p.isRunning { p.terminate() }
        p.waitUntilExit()
        killer.cancel()
        errDone.wait()
        if timedOut { throw ContentsError("Reading took too long and was stopped.") }
        let message = String(decoding: errText, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return RunResult(out: data, err: message, status: cut ? 0 : p.terminationStatus, cut: cut)
    }
}
