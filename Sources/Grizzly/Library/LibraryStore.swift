import Foundation

struct LibraryFile: Identifiable, Codable, Hashable {
    var id = UUID()
    var bookmark: Data
    var path: String
    var name: String
    var folderID: UUID?
    var isFavorite = false
    var lastOpened: Date?
    /// 1-based line numbers the reader has bookmarked.
    var bookmarks: [Int] = []
    var tags: [String] = []
    /// #hashtags found in the file's own text; refreshed whenever the file is read.
    var inlineTags: [String] = []

    var type: FileType { FileType(url: URL(fileURLWithPath: path)) }

    enum CodingKeys: String, CodingKey {
        case id, bookmark, path, name, folderID, isFavorite, lastOpened, bookmarks, tags, inlineTags
    }
}

extension LibraryFile {
    // Written by hand so libraries saved before bookmarks existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bookmark = try c.decode(Data.self, forKey: .bookmark)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        bookmarks = try c.decodeIfPresent([Int].self, forKey: .bookmarks) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        inlineTags = try c.decodeIfPresent([String].self, forKey: .inlineTags) ?? []
    }
}

/// What a smart folder collects: the files of the library that carry its tags and are of its types. The folder holds no
/// files of its own; its content is worked out from the rule, so a file lands in it the moment a tag appears in its text.
struct SmartRule: Codable, Hashable {
    enum Sort: String, Codable, CaseIterable { case name, type, opened }

    /// Tags without the leading "#". Empty: tags are not considered.
    var tags: [String] = []
    /// True: a file needs every tag; false: any one of them is enough.
    var matchAllTags = true
    /// `FileType` raw values. Empty: the type is not considered.
    var types: [String] = []
    var sort: Sort = .name

    init(tags: [String] = [], matchAllTags: Bool = true, types: [String] = [], sort: Sort = .name) {
        self.tags = tags; self.matchAllTags = matchAllTags; self.types = types; self.sort = sort
    }

    // Written by hand so a rule saved by a later version with other keys still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        matchAllTags = try c.decodeIfPresent(Bool.self, forKey: .matchAllTags) ?? true
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        sort = (try? c.decodeIfPresent(Sort.self, forKey: .sort)) ?? .name
    }

    /// A rule with no condition matches nothing (rather than every file).
    var isEmpty: Bool { tags.isEmpty && types.isEmpty }

    func matches(_ file: LibraryFile) -> Bool {
        guard !isEmpty else { return false }
        if !tags.isEmpty {
            let own = file.tags + file.inlineTags
            let has: (String) -> Bool = { tag in own.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            if matchAllTags ? !tags.allSatisfy(has) : !tags.contains(where: has) { return false }
        }
        if !types.isEmpty, !types.contains(file.type.rawValue) { return false }
        return true
    }
}

struct LibraryFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var isExpanded = true
    /// Directory on disk this folder mirrors; nil for a purely virtual folder.
    var sourcePath: String?
    /// The folder this one lives in; nil for a folder at the top level of the library.
    var parentID: UUID?
    /// Set for a smart folder, which collects files by tag and type instead of holding them.
    var smart: SmartRule?

    var isSmart: Bool { smart != nil }
}

/// A file the reader opened. Lives apart from the library, so removing a file from the sidebar keeps its history.
struct HistoryEntry: Identifiable, Codable, Hashable {
    var path: String
    var name: String
    var bookmark: Data
    var date: Date

    var id: String { path }
    var type: FileType { FileType(url: URL(fileURLWithPath: path)) }
}

private struct LibraryData: Codable {
    var files: [LibraryFile] = []
    var folders: [LibraryFolder] = []
    var history: [HistoryEntry] = []
    /// Tags created by the user, also those no file carries yet.
    var tags: [String] = []

    enum CodingKeys: String, CodingKey { case files, folders, history, tags }

    init() {}

    // Libraries saved before the history existed have no "history" key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([LibraryFile].self, forKey: .files) ?? []
        folders = try c.decodeIfPresent([LibraryFolder].self, forKey: .folders) ?? []
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        // First launch with a history: seed it from the "last opened" dates of the library files.
        if history.isEmpty {
            history = files.compactMap { f in
                f.lastOpened.map { HistoryEntry(path: f.path, name: f.name, bookmark: f.bookmark, date: $0) }
            }.sorted { $0.date > $1.date }
        }
    }
}

/// Virtual library: files stay where they are on disk, folders only group references to them.
final class LibraryStore: ObservableObject {
    static let recentLimit = 20
    /// More is stored than shown, so clearing the oldest entries never happens by surprise.
    static let historyStored = 200

    @Published private var data = LibraryData()
    @Published private(set) var missing: Set<UUID> = []

    private let storeURL: URL

    /// What changed in a `mutate`, so that only the lookups that can be stale are rebuilt. A library of thousands of
    /// files is asked the same questions on every redraw of the sidebar.
    enum Change { case structure, tags, other }

    private final class Cache {
        var built = false
        var positions: [UUID: Int] = [:]
        var folderPositions: [UUID: Int] = [:]
        var pathIndex: [String: UUID] = [:]
        var filesIn: [UUID?: [UUID]] = [:]
        var foldersIn: [UUID?: [UUID]] = [:]
        var counts: [UUID: Int] = [:]
        var tagsBuilt = false
        var allTags: [String] = []
        var tagCounts: [String: Int] = [:]
        /// Members of each smart folder, worked out on first use and dropped on any change of the library.
        var smart: [UUID: [UUID]] = [:]
    }
    private let cache = Cache()

    private static func before(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .numeric, .diacriticInsensitive]) == .orderedAscending
    }

    private func structure() -> Cache {
        let c = cache
        if c.built { return c }
        c.positions = [:]; c.folderPositions = [:]; c.pathIndex = [:]; c.filesIn = [:]; c.foldersIn = [:]; c.counts = [:]
        c.positions.reserveCapacity(data.files.count)
        for (i, f) in data.files.enumerated() {
            c.positions[f.id] = i
            c.pathIndex[f.path] = f.id
            c.filesIn[f.folderID, default: []].append(f.id)
        }
        for (i, f) in data.folders.enumerated() {
            c.folderPositions[f.id] = i
            c.foldersIn[f.parentID, default: []].append(f.id)
        }
        let files = data.files, folders = data.folders
        for key in Array(c.filesIn.keys) {
            c.filesIn[key]?.sort { Self.before(files[c.positions[$0]!].name, files[c.positions[$1]!].name) }
        }
        for key in Array(c.foldersIn.keys) {
            c.foldersIn[key]?.sort { Self.before(folders[c.folderPositions[$0]!].name, folders[c.folderPositions[$1]!].name) }
        }
        for f in files {
            var current = f.folderID
            var depth = 0
            while let id = current, depth < 64 {
                c.counts[id, default: 0] += 1
                current = c.folderPositions[id].map { folders[$0].parentID } ?? nil
                depth += 1
            }
        }
        c.built = true
        return c
    }

    private func tagCache() -> Cache {
        let c = cache
        if c.tagsBuilt { return c }
        var seen = Set<String>()
        var result: [String] = []
        c.tagCounts = [:]
        for tag in data.tags where seen.insert(tag.lowercased()).inserted { result.append(tag) }
        for f in data.files {
            var own = Set<String>()
            for tag in f.tags + f.inlineTags {
                let key = tag.lowercased()
                if seen.insert(key).inserted { result.append(tag) }
                if own.insert(key).inserted { c.tagCounts[key, default: 0] += 1 }
            }
        }
        c.allTags = result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        c.tagsBuilt = true
        return c
    }

    private func invalidate(_ change: Change) {
        cache.smart = [:]
        switch change {
        case .structure: cache.built = false; cache.tagsBuilt = false
        case .tags: cache.tagsBuilt = false
        case .other: break
        }
    }

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let base = support.appendingPathComponent("Grizzly", isDirectory: true)
            // The app used to be called MD Reader: carry its library over once.
            let old = support.appendingPathComponent("MDReader", isDirectory: true)
            if !FileManager.default.fileExists(atPath: base.path), FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.moveItem(at: old, to: base)
            }
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("library.json")
        }
        load()
        refreshMissing()
    }

    /// Writes any change that is still waiting (the library is saved a moment after the last change).
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        writeNow(data)
    }

    // MARK: Queries

    var folders: [LibraryFolder] {
        data.folders.sorted { Self.before($0.name, $1.name) }
    }

    var allFiles: [LibraryFile] { data.files }

    func file(_ id: UUID) -> LibraryFile? { structure().positions[id].map { data.files[$0] } }

    func files(in folderID: UUID?) -> [LibraryFile] {
        if let folderID, folder(folderID)?.isSmart == true {
            return smartMembers(folderID).compactMap { structure().positions[$0].map { data.files[$0] } }
        }
        return (structure().filesIn[folderID] ?? []).compactMap { structure().positions[$0].map { data.files[$0] } }
    }

    /// The files a smart folder collects, in the order its rule asks for.
    private func smartMembers(_ id: UUID) -> [UUID] {
        if let hit = cache.smart[id] { return hit }
        guard let rule = folder(id)?.smart else { return [] }
        let ids = ordered(data.files.filter(rule.matches), by: rule.sort).map(\.id)
        cache.smart[id] = ids
        return ids
    }

    private func ordered(_ files: [LibraryFile], by sort: SmartRule.Sort) -> [LibraryFile] {
        switch sort {
        case .name:
            return files.sorted { Self.before($0.name, $1.name) }
        case .type:
            return files.sorted { a, b in
                a.type == b.type ? Self.before(a.name, b.name) : Self.before(a.type.title, b.type.title)
            }
        case .opened:
            return files.sorted { a, b in
                switch (a.lastOpened, b.lastOpened) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return Self.before(a.name, b.name)
                }
            }
        }
    }

    /// How many files a rule would collect right now (the settings of a smart folder show it while being edited).
    func smartMatchCount(_ rule: SmartRule) -> Int { rule.isEmpty ? 0 : data.files.filter(rule.matches).count }

    /// Opened files, newest first, whether or not they are still in the library.
    var recents: [HistoryEntry] {
        Array(data.history.sorted { $0.date > $1.date }.prefix(Self.recentLimit))
    }

    func file(atPath path: String) -> LibraryFile? { structure().pathIndex[path].flatMap(file) }

    var favorites: [LibraryFile] {
        data.files
            .filter(\.isFavorite)
            .sorted { Self.before($0.name, $1.name) }
    }

    /// Whether a folder with this name already exists next to the others in `parent` (nil: the top level).
    func folderExists(_ name: String, in parent: UUID? = nil, ignoring ignored: UUID? = nil) -> Bool {
        data.folders.contains { $0.parentID == parent && $0.id != ignored && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func folder(_ id: UUID) -> LibraryFolder? { structure().folderPositions[id].map { data.folders[$0] } }

    /// The folders directly inside `parent` (nil: the top level), by name.
    func folders(in parent: UUID?) -> [LibraryFolder] {
        (structure().foldersIn[parent] ?? []).compactMap { structure().folderPositions[$0].map { data.folders[$0] } }
    }

    /// The folder and everything below it, as folder ids.
    func subtreeIDs(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in data.folders where child.parentID == next && result.insert(child.id).inserted { queue.append(child.id) }
        }
        return result
    }

    /// Number of files in a folder and all the folders inside it.
    func fileCount(in id: UUID) -> Int {
        folder(id)?.isSmart == true ? smartMembers(id).count : (structure().counts[id] ?? 0)
    }

    /// "Work / 2026 / Reports": where a folder lives, for menus that list every folder.
    func folderPath(_ id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        var guardCount = 0
        while let c = current, let f = folder(c), guardCount < 64 {
            names.insert(f.name, at: 0)
            current = f.parentID
            guardCount += 1
        }
        return names.joined(separator: " / ")
    }

    /// Every folder with its path, sorted by path: the targets of "Move to…".
    /// Smart folders are left out: files cannot be put into them.
    var folderChoices: [(folder: LibraryFolder, path: String)] {
        data.folders.filter { !$0.isSmart }.map { ($0, folderPath($0.id)) }.sorted { Self.before($0.1, $1.1) }
    }

    func isMissing(_ id: UUID) -> Bool { missing.contains(id) }

    // MARK: Files

    @discardableResult
    func add(url: URL) -> LibraryFile {
        let path = url.standardizedFileURL.path
        if let existing = file(atPath: path) { return existing }
        let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        let entry = LibraryFile(bookmark: bookmark, path: path, name: url.lastPathComponent)
        mutate { $0.files.append(entry) }
        return entry
    }

    /// Finds the file on disk, following moves and renames through the bookmark. Nil if it is gone.
    func resolve(_ id: UUID) -> URL? {
        guard let entry = file(id) else { return nil }
        let fm = FileManager.default

        var stale = false
        if !entry.bookmark.isEmpty,
           let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
           fm.fileExists(atPath: url.path) {
            if stale || url.path != entry.path { refresh(id, url: url) }
            setMissing(id, false)
            return url
        }
        if fm.fileExists(atPath: entry.path) {
            setMissing(id, false)
            let url = URL(fileURLWithPath: entry.path)
            // Files added with a whole folder get their bookmark the first time they are opened.
            if entry.bookmark.isEmpty, let made = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                mutate(.other) { d in
                    if let i = d.files.firstIndex(where: { $0.id == id }) { d.files[i].bookmark = made }
                }
            }
            return url
        }
        setMissing(id, true)
        return nil
    }

    /// Puts a file at the top of the history (once per path).
    func recordOpened(_ url: URL) {
        let path = url.standardizedFileURL.path
        let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        mutate(.other) { d in
            d.history.removeAll { $0.path == path }
            d.history.append(HistoryEntry(path: path, name: url.lastPathComponent, bookmark: bookmark, date: Date()))
            if d.history.count > Self.historyStored {
                d.history = Array(d.history.sorted { $0.date > $1.date }.prefix(Self.historyStored))
            }
            if let i = d.files.firstIndex(where: { $0.path == path }) { d.files[i].lastOpened = Date() }
        }
    }

    /// Finds a history file on disk, following moves and renames through the bookmark.
    func resolve(_ entry: HistoryEntry) -> URL? {
        let fm = FileManager.default
        var stale = false
        if !entry.bookmark.isEmpty,
           let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
           fm.fileExists(atPath: url.path) { return url }
        return fm.fileExists(atPath: entry.path) ? URL(fileURLWithPath: entry.path) : nil
    }

    func isMissing(_ entry: HistoryEntry) -> Bool { resolve(entry) == nil }

    func removeFromHistory(_ path: String) {
        mutate(.other) { $0.history.removeAll { $0.path == path } }
    }

    func clearRecents() {
        mutate(.other) { d in
            d.history = []
            for i in d.files.indices { d.files[i].lastOpened = nil }
        }
    }

    func toggleFavorite(_ id: UUID) {
        mutate(.other) { d in
            if let i = d.files.firstIndex(where: { $0.id == id }) { d.files[i].isFavorite.toggle() }
        }
    }

    func bookmarks(for id: UUID?) -> [Int] {
        guard let id else { return [] }
        return file(id)?.bookmarks ?? []
    }

    func toggleBookmark(_ id: UUID?, line: Int) {
        guard let id else { return }
        mutate(.other) { d in
            guard let i = d.files.firstIndex(where: { $0.id == id }) else { return }
            if let at = d.files[i].bookmarks.firstIndex(of: line) {
                d.files[i].bookmarks.remove(at: at)
            } else {
                d.files[i].bookmarks.append(line)
                d.files[i].bookmarks.sort()
            }
        }
    }

    /// Removes the reference only; the file on disk is never touched.
    func remove(_ id: UUID) {
        mutate { $0.files.removeAll { $0.id == id } }
        missing.remove(id)
    }

    /// Removes several references at once.
    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate { $0.files.removeAll { ids.contains($0.id) } }
        missing.subtract(ids)
    }

    func move(_ fileID: UUID, to folderID: UUID?) {
        if let folderID, folder(folderID)?.isSmart == true { return }
        mutate { d in
            guard let i = d.files.firstIndex(where: { $0.id == fileID }), d.files[i].folderID != folderID else { return }
            d.files[i].folderID = folderID
            if let folderID, let f = d.folders.firstIndex(where: { $0.id == folderID }) {
                d.folders[f].isExpanded = true
            }
        }
    }

    /// Adds a scanned directory tree in one step: a library folder for the directory and for every directory below it
    /// (folders inside folders), a reference for every file. Only the top folder starts open. Files already in the library
    /// are left where they are.
    @discardableResult
    func importTree(root: URL, files: [URL]) -> (folderID: UUID, added: Int) {
        let rootPath = root.standardizedFileURL.path
        var rootID = UUID()
        var added = 0
        mutate { d in
            var byPath: [String: UUID] = [:]
            for f in d.folders { if let p = f.sourcePath { byPath[p] = f.id } }
            var position: [String: Int] = [:]
            for (i, f) in d.files.enumerated() { position[f.path] = i }
            func folderID(for dirPath: String) -> UUID {
                if let id = byPath[dirPath] { return id }
                let isRoot = dirPath == rootPath || !dirPath.hasPrefix(rootPath)
                let parent: UUID? = isRoot ? nil : folderID(for: (dirPath as NSString).deletingLastPathComponent)
                let name = (dirPath as NSString).lastPathComponent
                var unique = name
                var n = 2
                while d.folders.contains(where: { $0.parentID == parent && $0.name.caseInsensitiveCompare(unique) == .orderedSame }) {
                    unique = "\(name) (\(n))"
                    n += 1
                }
                var folder = LibraryFolder(name: unique)
                folder.sourcePath = dirPath
                folder.parentID = parent
                folder.isExpanded = isRoot
                d.folders.append(folder)
                byPath[dirPath] = folder.id
                return folder.id
            }
            rootID = folderID(for: rootPath)
            for url in files {
                let path = url.standardizedFileURL.path
                let target = folderID(for: (path as NSString).deletingLastPathComponent)
                if let i = position[path] {
                    if d.files[i].folderID == nil { d.files[i].folderID = target }
                } else {
                    d.files.append(LibraryFile(bookmark: Data(), path: path, name: url.lastPathComponent, folderID: target))
                    position[path] = d.files.count - 1
                    added += 1
                }
            }
        }
        return (rootID, added)
    }

    /// Stores the hashtags found in the texts of many files at once.
    func setInlineTags(_ updates: [(UUID, [String])]) {
        mutate(.tags) { d in
            var position: [UUID: Int] = [:]
            for (i, f) in d.files.enumerated() { position[f.id] = i }
            for (id, tags) in updates {
                if let i = position[id], d.files[i].inlineTags != tags { d.files[i].inlineTags = tags }
            }
        }
    }

    // MARK: Tags

    /// Characters a tag may contain: letters, digits, marks, `_`, `-` and emoji (so `#🍕` and `#идея💡` are tags).
    static let tagBody = "\\p{L}\\p{N}\\p{M}_\\-\\p{Extended_Pictographic}\\u200D\\uFE0F"

    /// `#14b1f2` in a README is a color, not a tag.
    static func isNoise(_ tag: String) -> Bool {
        guard [3, 4, 6, 8].contains(tag.count), tag.allSatisfy({ $0.isHexDigit }) else { return false }
        return tag.contains { $0.isLetter } && tag.contains { $0.isNumber }
    }

    /// Tag text as stored: trimmed, without a leading "#".
    static func cleanTag(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every known tag, alphabetically: the ones created by the user plus any a file still carries.
    var allTags: [String] { tagCache().allTags }

    /// How many files carry the tag (a count kept ready: the sidebar asks for every tag on each redraw).
    func tagCount(_ tag: String) -> Int { tagCache().tagCounts[tag.lowercased()] ?? 0 }

    func files(withTag tag: String) -> [LibraryFile] {
        data.files
            .filter { f in (f.tags + f.inlineTags).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Files that carry every one of the tags (several selected tags narrow the list down, as in Apple Notes).
    func files(withAllTags tags: [String]) -> [LibraryFile] {
        guard !tags.isEmpty else { return [] }
        return data.files
            .filter { f in tags.allSatisfy { tag in (f.tags + f.inlineTags).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func tagExists(_ tag: String) -> Bool { tagCache().tagCounts[tag.lowercased()] != nil || allTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }

    /// Creates a tag (and returns its stored spelling); an existing tag is returned as it is. Nil for an empty name.
    @discardableResult
    func createTag(_ raw: String) -> String? {
        let tag = Self.cleanTag(raw)
        guard !tag.isEmpty else { return nil }
        if let existing = allTags.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return existing }
        mutate(.tags) { $0.tags.append(tag) }
        return tag
    }

    /// True for tags set by hand and for #hashtags written in the file's text.
    func hasTag(_ fileID: UUID, _ tag: String) -> Bool {
        file(fileID).map { ($0.tags + $0.inlineTags).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } } ?? false
    }

    /// `#word` tags in prose: a hash right before a letter or digit, not part of a word, link or entity.
    static func extractTags(from text: String) -> [String] {
        guard text.contains("#"),
              let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_#&/=:])#([" + tagBody + "]+)") else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var result: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            if !tag.isEmpty, !isNoise(tag), seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        return result
    }

    /// Matches `#tag` the way `extractTags` reads tags, for one specific tag.
    private static func tagRegex(_ tag: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_#&/=:])#" + NSRegularExpression.escapedPattern(for: tag) + "(?![" + tagBody + "])",
                                 options: [.caseInsensitive])
    }

    /// Number of `#tag` occurrences in a text.
    static func countTag(_ tag: String, in text: String) -> Int {
        tagRegex(tag)?.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
    }

    /// `#old` becomes `#new`; with `new == nil` the tag is removed from the text (with the space after it).
    static func replaceTag(_ old: String, with new: String?, in text: String) -> String {
        guard let regex = tagRegex(old) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var end = m.range.location + m.range.length
            if let new { out += "#" + new } else if end < ns.length, ns.character(at: end) == 32 { end += 1 }
            last = end
        }
        return out + ns.substring(from: last)
    }

    /// Where the `#tags` are in a text (range includes the `#`), for coloring them.
    static func tagMatches(in text: String) -> [(range: NSRange, tag: String)] {
        guard text.contains("#"),
              let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_#&/=:])#([" + tagBody + "]+)") else { return [] }
        let ns = text as NSString
        var result: [(NSRange, String)] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var word = ns.substring(with: m.range(at: 1))
            var range = m.range
            while let last = word.last, last == "-" || last == "_" { word.removeLast(); range.length -= 1 }
            if !word.isEmpty, !isNoise(word) { result.append((range, word)) }
        }
        return result
    }

    /// Stores the hashtags found in a file's text (only prose is scanned by the callers).
    func setInlineTags(_ id: UUID, _ tags: [String]) {
        guard let current = file(id)?.inlineTags, current != tags else { return }
        mutate(.tags) { d in
            if let i = d.files.firstIndex(where: { $0.id == id }) { d.files[i].inlineTags = tags }
        }
    }

    func toggleTag(_ fileID: UUID, _ tag: String) {
        mutate(.tags) { d in
            guard let i = d.files.firstIndex(where: { $0.id == fileID }) else { return }
            if let at = d.files[i].tags.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                d.files[i].tags.remove(at: at)
            } else {
                d.files[i].tags.append(tag)
            }
        }
    }

    func renameTag(_ old: String, to raw: String) {
        let new = Self.cleanTag(raw)
        guard !new.isEmpty else { return }
        func swap(_ list: inout [String]) {
            var out: [String] = []
            for t in list {
                let value = t.caseInsensitiveCompare(old) == .orderedSame ? new : t
                if !out.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { out.append(value) }
            }
            list = out
        }
        mutate(.tags) { d in
            swap(&d.tags)
            for i in d.files.indices { swap(&d.files[i].tags); swap(&d.files[i].inlineTags) }
            for i in d.folders.indices where d.folders[i].smart != nil { swap(&d.folders[i].smart!.tags) }
        }
    }

    func deleteTag(_ tag: String) {
        mutate(.tags) { d in
            d.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            for i in d.files.indices { d.files[i].inlineTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            for i in d.files.indices { d.files[i].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            for i in d.folders.indices where d.folders[i].smart != nil {
                d.folders[i].smart!.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            }
        }
    }

    // MARK: Folders

    func folderURL(_ id: UUID) -> URL? {
        guard let path = data.folders.first(where: { $0.id == id })?.sourcePath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Finds or creates the library folder that mirrors a directory on disk (inside `parent`; nil: the top level).
    func folder(forDirectory url: URL, name: String, parent: UUID? = nil) -> LibraryFolder {
        let path = url.standardizedFileURL.path
        if let existing = data.folders.first(where: { $0.sourcePath == path }) { return existing }
        var unique = name
        var n = 2
        while folderExists(unique, in: parent) { unique = "\(name) (\(n))"; n += 1 }
        var folder = LibraryFolder(name: unique)
        folder.sourcePath = path
        folder.parentID = parent
        mutate { $0.folders.append(folder) }
        return folder
    }

    @discardableResult
    func createFolder(_ name: String, parent: UUID? = nil) -> LibraryFolder {
        // Nothing lives inside a smart folder: a folder meant for it goes next to it instead.
        let parent = parent.flatMap { self.folder($0)?.isSmart == true ? self.folder($0)?.parentID : $0 }
        var folder = LibraryFolder(name: name)
        folder.parentID = parent
        mutate { d in
            d.folders.append(folder)
            if let parent, let p = d.folders.firstIndex(where: { $0.id == parent }) { d.folders[p].isExpanded = true }
        }
        return folder
    }

    @discardableResult
    func createSmartFolder(_ name: String, rule: SmartRule, parent: UUID? = nil) -> LibraryFolder {
        var folder = LibraryFolder(name: name)
        folder.parentID = parent.flatMap { self.folder($0)?.isSmart == true ? nil : $0 }
        folder.smart = rule
        mutate { $0.folders.append(folder) }
        return folder
    }

    /// Changes the name and the rule of a smart folder.
    func updateSmartFolder(_ id: UUID, name: String, rule: SmartRule) {
        mutate { d in
            guard let i = d.folders.firstIndex(where: { $0.id == id }), d.folders[i].smart != nil else { return }
            d.folders[i].name = name
            d.folders[i].smart = rule
        }
    }

    func renameFolder(_ id: UUID, to name: String) {
        mutate { d in
            if let i = d.folders.firstIndex(where: { $0.id == id }) { d.folders[i].name = name }
        }
    }

    /// Puts a folder (with everything in it) inside another one, or back at the top level. A folder cannot go into itself
    /// or into one of its own subfolders, and the name must be free at the destination.
    @discardableResult
    func moveFolder(_ id: UUID, to parent: UUID?) -> Bool {
        guard let folder = folder(id), folder.parentID != parent else { return false }
        if let parent, subtreeIDs(of: id).contains(parent) || self.folder(parent)?.isSmart == true { return false }
        if folderExists(folder.name, in: parent, ignoring: id) { return false }
        mutate { d in
            guard let i = d.folders.firstIndex(where: { $0.id == id }) else { return }
            d.folders[i].parentID = parent
            if let parent, let p = d.folders.firstIndex(where: { $0.id == parent }) { d.folders[p].isExpanded = true }
        }
        return true
    }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        mutate(.other) { d in
            if let i = d.folders.firstIndex(where: { $0.id == id }) { d.folders[i].isExpanded = expanded }
        }
    }

    /// Removes the folder with everything in it: its subfolders and the references to the files inside them.
    /// Nothing is deleted from the disk. Returns the ids of the files that left the library.
    @discardableResult
    func deleteFolder(_ id: UUID) -> [UUID] {
        let doomed = subtreeIDs(of: id)
        let files = data.files.filter { $0.folderID.map(doomed.contains) ?? false }.map(\.id)
        mutate { d in
            d.files.removeAll { $0.folderID.map(doomed.contains) ?? false }
            d.folders.removeAll { doomed.contains($0.id) }
        }
        missing.subtract(files)
        return files
    }

    // MARK: Internals

    /// Checks in the background which files are gone (a library of thousands of files must not block the launch).
    /// A file that moved is found again through its bookmark.
    func refreshMissing() {
        let entries = data.files.map { ($0.id, $0.path, $0.bookmark) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var gone = Set<UUID>()
            var moved: [(UUID, URL)] = []
            for (id, path, bookmark) in entries where !fm.fileExists(atPath: path) {
                var stale = false
                if !bookmark.isEmpty,
                   let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                   fm.fileExists(atPath: url.path) {
                    moved.append((id, url))
                } else {
                    gone.insert(id)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.missing != gone { self.missing = gone }
                for (id, url) in moved { self.refresh(id, url: url) }
            }
        }
    }

    private func setMissing(_ id: UUID, _ value: Bool) {
        // Assigning to the published set announces a change even when nothing changed.
        if value, !missing.contains(id) { missing.insert(id) } else if !value, missing.contains(id) { missing.remove(id) }
    }

    private func refresh(_ id: UUID, url: URL) {
        let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        mutate { d in
            if let i = d.files.firstIndex(where: { $0.id == id }) {
                d.files[i].path = url.path
                d.files[i].name = url.lastPathComponent
                if !bookmark.isEmpty { d.files[i].bookmark = bookmark }
            }
        }
    }

    private func mutate(_ kind: Change = .structure, _ change: (inout LibraryData) -> Void) {
        var copy = data
        change(&copy)
        data = copy
        invalidate(kind)
        scheduleSave()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode(LibraryData.self, from: raw) else { return }
        data = decoded
        invalidate(.structure)
    }

    private var saveWork: DispatchWorkItem?
    private static let writer = DispatchQueue(label: "grizzly.library.writer", qos: .utility)

    /// The library is written a moment after the last change, off the main thread: a burst of changes (opening a folder,
    /// reading the tags of every file) makes one write, not one per change.
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = data
        let work = DispatchWorkItem { [weak self] in self?.writeNow(snapshot) }
        saveWork = work
        Self.writer.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeNow(_ snapshot: LibraryData) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let raw = try? encoder.encode(snapshot) else { return }
        try? raw.write(to: storeURL, options: .atomic)
    }
}
