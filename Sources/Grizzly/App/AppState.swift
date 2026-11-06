import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// User mode: the document as it reads, formatting code hidden. Developer mode: the text exactly as in the file.
enum ReadMode: String { case user, developer }
enum Pane { case left, right }

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
}

final class AppState: ObservableObject {
    static let shared = AppState()

    let library = LibraryStore()

    /// Open tabs, in order. Both panes pick their document from this list.
    @Published var documents: [Document] = []
    /// Document shown in the left (or only) pane.
    @Published var selection: UUID?
    /// Document shown in the right pane while split view is on.
    @Published var rightSelection: UUID?
    @Published var isSplit = false
    @Published var focusedPane: Pane = .left
    /// Library entry highlighted in the sidebar; follows the focused pane.
    @Published var selectedFileID: UUID?
    /// The mode of each pane: in split view one pane can be in User mode while the other shows the code.
    @Published var paneModes: [Pane: ReadMode] = [.left: .user, .right: .developer]
    /// The mode of the focused pane (the one the toolbar and the menus act on).
    var mode: ReadMode {
        get { paneModes[isSplit ? focusedPane : .left] ?? .user }
        set { paneModes[isSplit ? focusedPane : .left] = newValue }
    }
    func mode(of pane: Pane) -> ReadMode { paneModes[pane] ?? .user }
    /// A short message at the bottom of the window ("Saved", "Tag created", ...).
    @Published private(set) var toast: Toast?
    /// Tags picked in the sidebar: the list shows the files that carry all of them.
    @Published var selectedTags: [String] = []
    /// Bumped when the sidebar should switch to the file list (a tag was clicked in a document).
    @Published var sidebarRevealToken = 0
    @Published var errorMessage: String?
    /// The folder, archive or disk image whose contents are being looked at (shown as a sheet).
    @Published var contentsPreview: ContentsPreviewModel?
    /// Open documents whose file changed on disk after they were read.
    @Published private(set) var changedOnDisk: Set<UUID> = []
    /// Edited text per open document, kept only while it differs from the file.
    @Published private(set) var drafts: [UUID: String] = [:]
    /// Folded sections (Title and Heading lines) per open document, by `MarkdownParser.sectionKeys`.
    @Published private(set) var collapsedSections: [UUID: Set<String>] = [:]
    private var watcher: Timer?

    /// Polls open files once a second; called once the app has launched.
    func startWatching() {
        guard watcher == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkFiles() }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    // Find
    @Published var isFindVisible = false
    @Published var findQuery = "" { didSet { recomputeMatches(reset: true) } }
    @Published private(set) var matches: [SearchMatch] = []
    @Published private(set) var matchIndex = 0
    @Published var findFocusToken = 0
    /// Asks the target pane to scroll a row into view (find hits and bookmarks).
    @Published var scrollTarget: ScrollTarget?

    func docID(in pane: Pane) -> UUID? { pane == .left ? selection : rightSelection }
    func doc(in pane: Pane) -> Document? { documents.first { $0.id == docID(in: pane) } }
    var current: Document? { doc(in: isSplit ? focusedPane : .left) }

    // MARK: Notifications

    /// Shows a short notification; it fades after a couple of seconds (a newer one replaces it).
    func notify(_ text: String, symbol: String = "checkmark.circle.fill") {
        let t = Toast(text: text, symbol: symbol)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    // MARK: Opening

    /// Files handed over by the system (Finder, Dock, `open -a`) before the app finished launching.
    private var pendingExternal: [URL] = []
    private var isReady = false

    /// Entry point for files that arrive from outside. Whichever route delivers them first (the app delegate,
    /// SwiftUI's `onOpenURL`, the command line) opens them; a file delivered twice is not opened twice.
    func openExternal(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        if isReady { open(urls: files) } else { pendingExternal.append(contentsOf: files) }
    }

    /// Called once the app has launched: opens whatever arrived while it was starting.
    func markReady() {
        isReady = true
        restoreSessionIfAny()
        let queued = pendingExternal
        pendingExternal = []
        if !queued.isEmpty { open(urls: queued) }
    }

    /// Opens files from disk (Open panel, drag and drop, Finder) and adds them to the library.
    func open(urls: [URL], inRight: Bool = false) {
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                importFolder(url)
                continue
            }
            // An archive or a disk image is not a document: show what is inside instead of opening it.
            if ContentsLister.isContainer(url) {
                previewContents(of: url)
                continue
            }
            let entry = library.add(url: url)
            show(entry.id, url: url, pane: inRight ? .right : nil)
        }
    }

    // MARK: Contents of folders, archives and disk images

    /// Lists what is inside an archive, a disk image or a folder on disk, without opening or unpacking it.
    func previewContents(of url: URL) {
        contentsPreview = ContentsPreviewModel(url: url)
    }

    /// Lists a folder of the sidebar: the directory it mirrors, or, for a folder that exists only in the library, what the
    /// library keeps in it (for a smart folder, the files it has collected).
    func previewFolder(_ id: UUID) {
        guard let folder = library.folder(id) else { return }
        if let url = library.folderURL(id) {
            contentsPreview = ContentsPreviewModel(url: url, title: folder.name)
            return
        }
        var listing = ContentsListing()
        func entries(in parent: UUID) -> [ContentEntry] {
            let subfolders = library.folders(in: parent).map { sub -> ContentEntry in
                listing.folders += 1
                return ContentEntry(id: sub.id.uuidString, name: sub.name, isDirectory: true, size: nil, children: entries(in: sub.id))
            }
            let files = library.files(in: parent).map { file -> ContentEntry in
                listing.files += 1
                return ContentEntry(id: "\(parent.uuidString)/\(file.id.uuidString)", name: file.name, isDirectory: false, size: nil, children: nil)
            }
            return subfolders + files
        }
        listing.entries = entries(in: id)
        contentsPreview = ContentsPreviewModel(title: folder.name, symbol: folder.isSmart ? SmartFolderIcon.symbol : "folder", listing: listing)
    }

    // MARK: Session kept across an update restart

    private static let sessionKey = "sessionForRestart"

    /// The text views of the window, left to right (the sidebar has none).
    private func textScrollViews() -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.documentView is NSTextView, s.frame.width > 120 { found.append(s) }
            v.subviews.forEach(walk)
        }
        if let root = (NSApp.keyWindow ?? NSApp.windows.first)?.contentView { walk(root) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// Writes what is open (tabs, panes, mode, scroll) so that the next launch can put it back.
    func saveSessionForRestart() {
        func index(_ id: UUID?) -> Int { documents.firstIndex { $0.id == id } ?? -1 }
        let scrolls = textScrollViews().map { v -> Double in
            let room = (v.documentView?.frame.height ?? 0) - v.contentView.bounds.height
            return room > 1 ? Double(v.contentView.bounds.origin.y / room) : 0
        }
        let session: [String: Any] = [
            "paths": documents.map { $0.url.path },
            "left": index(selection), "right": index(rightSelection),
            "split": isSplit, "mode": mode(of: .left).rawValue, "modeRight": mode(of: .right).rawValue, "scroll": scrolls,
            "date": Date().timeIntervalSince1970,
        ]
        UserDefaults.standard.set(session, forKey: Self.sessionKey)
    }

    /// Reopens the tabs saved before an update restart (only a fresh record is used, once).
    private func restoreSessionIfAny() {
        let defaults = UserDefaults.standard
        guard let s = defaults.dictionary(forKey: Self.sessionKey) else { return }
        defaults.removeObject(forKey: Self.sessionKey)
        guard let paths = s["paths"] as? [String], !paths.isEmpty,
              Date().timeIntervalSince1970 - (s["date"] as? Double ?? 0) < 600 else { return }

        var ids: [Int: UUID] = [:]
        for (i, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            show(library.file(atPath: url.standardizedFileURL.path)?.id, url: url, pane: .left)
            if let doc = documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { ids[i] = doc.id }
        }
        if let m = s["mode"] as? String, let mode = ReadMode(rawValue: m) { paneModes[.left] = mode }
        if let m = s["modeRight"] as? String, let mode = ReadMode(rawValue: m) { paneModes[.right] = mode }
        let left = ids[s["left"] as? Int ?? -1] ?? documents.first?.id
        let right = ids[s["right"] as? Int ?? -1]
        selection = left
        if (s["split"] as? Bool) == true, let right, right != left {
            rightSelection = right
            isSplit = true
        }
        if let id = selection { selectedFileID = documents.first { $0.id == id }?.libraryID }

        // The text views appear a moment later; put each back at its saved position.
        let scrolls = s["scroll"] as? [Double] ?? []
        for delay in [0.4, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                for (view, fraction) in zip(self.textScrollViews(), scrolls) where fraction > 0 {
                    let room = (view.documentView?.frame.height ?? 0) - view.contentView.bounds.height
                    guard room > 1 else { continue }
                    view.contentView.scroll(to: NSPoint(x: 0, y: fraction * room))
                    view.reflectScrolledClipView(view.contentView)
                }
            }
        }
    }

    /// Opens a file from the history. It is shown in a tab without being added back to the sidebar.
    func openHistory(_ entry: HistoryEntry, inRight: Bool = false) {
        guard let url = library.resolve(entry) else {
            errorMessage = L("Файл «%@» не найден. Возможно, он перемещён или удалён.", entry.name)
            return
        }
        let pane: Pane = inRight ? .right : (isSplit ? focusedPane : .left)
        if let known = library.file(atPath: url.standardizedFileURL.path) {
            show(known.id, url: url, pane: pane)
        } else {
            show(nil, url: url, pane: pane)
        }
    }

    /// Opens a file that is already in the library (sidebar click).
    func openLibraryFile(_ id: UUID?, inRight: Bool = false) {
        guard let id, library.file(id) != nil else { return }
        let pane: Pane = inRight ? .right : (isSplit ? focusedPane : .left)

        if let existing = documents.first(where: { $0.libraryID == id }) {
            if docID(in: pane) != existing.id || focusedPane != pane { assign(existing.id, to: pane) }
            return
        }
        guard let url = library.resolve(id) else {
            let name = library.file(id)?.name ?? ""
            errorMessage = L("Файл «%@» не найден. Возможно, он перемещён или удалён.", name)
            return
        }
        show(id, url: url, pane: pane)
    }

    private func show(_ libraryID: UUID?, url: URL, pane: Pane?) {
        let target = pane ?? (isSplit ? focusedPane : .left)

        let same: (Document) -> Bool = { libraryID != nil ? $0.libraryID == libraryID : $0.url.standardizedFileURL == url.standardizedFileURL }
        if let existing = documents.first(where: same) {
            assign(existing.id, to: target)
            library.recordOpened(url)
            return
        }
        do {
            var doc = try Document(url: url)
            doc.libraryID = libraryID
            noteTags(in: doc)
            documents.append(doc)
            assign(doc.id, to: target)
            library.recordOpened(url)
        } catch {
            errorMessage = L("Не удалось открыть «%@».", url.lastPathComponent)
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        // Folders can be picked too: one is added to the sidebar with the supported files in it, the rest is ignored.
        // (A list of allowed file types would grey the folders out, so the panel itself filters nothing.)
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = L("Выберите файлы, папки или архивы")
        panel.prompt = L("Открыть")
        let supported = Set(FileType.allExtensions)
        let filter = OpenPanelFilter { url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return true }
            return supported.contains(url.pathExtension.lowercased()) || ContentsLister.isContainer(url)
        }
        panel.delegate = filter
        let result = withExtendedLifetime(filter) { panel.runModal() }
        if result == .OK { open(urls: panel.urls) }
    }

    func presentFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { importFolder(url) } }
    }

    /// Directories that hold generated or downloaded files, not documents: they are skipped when a folder is added.
    private static let skippedDirectories: Set<String> = ["node_modules", "Pods", "DerivedData", "__pycache__", "venv", "bower_components", ".build"]
    private static let importLimit = 5000

    /// Lists the supported files under a directory (off the main thread: a folder can hold thousands of files).
    private func scan(_ root: URL, completion: @escaping ([URL], Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let supported = Set(FileType.allExtensions)
            var found: [URL] = []
            var truncated = false
            if let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in walker {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if values?.isDirectory == true {
                        if Self.skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                        continue
                    }
                    guard values?.isRegularFile == true, supported.contains(url.pathExtension.lowercased()) else { continue }
                    if found.count >= Self.importLimit { truncated = true; break }
                    found.append(url)
                }
            }
            DispatchQueue.main.async { completion(found, truncated) }
        }
    }

    /// Mirrors a directory into the library: its supported files become entries in folders named after the directories,
    /// subdirectories included (folders inside folders). Nothing is opened in a tab: the folder just appears in the sidebar.
    func importFolder(_ url: URL) {
        notify(L("Читаем папку «%@»…", url.lastPathComponent), symbol: "folder.badge.plus")
        scan(url) { [weak self] files, truncated in
            guard let self else { return }
            let result = self.library.importTree(root: url, files: files)
            self.selectedTags = []
            self.sidebarRevealToken += 1
            let name = self.library.folder(result.folderID)?.name ?? url.lastPathComponent
            self.notify(truncated ? L("Папка «%@» добавлена: первые %lld файлов.", name, Self.importLimit)
                                  : L("Папка «%@» добавлена: файлов %lld.", name, result.added),
                        symbol: "folder.badge.plus")
            self.scanTagsInLibrary()
        }
    }

    /// Re-scans a folder that was added from disk and adds files that appeared since.
    func syncFolder(_ id: UUID, root: URL? = nil) {
        guard let rootURL = root ?? library.folderURL(id) else { return }
        scan(rootURL) { [weak self] files, _ in
            guard let self else { return }
            let result = self.library.importTree(root: rootURL, files: files)
            self.notify(L("Папка обновлена: новых файлов %lld.", result.added), symbol: "arrow.triangle.2.circlepath")
            self.scanTagsInLibrary()
        }
    }

    // MARK: Hashtags in text

    func isTagSelected(_ tag: String) -> Bool { selectedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }

    func toggleTagSelection(_ tag: String) {
        if let i = selectedTags.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { selectedTags.remove(at: i) }
        else { selectedTags.append(tag) }
    }

    /// A click on a #tag inside a document: the sidebar lists the files with that tag.
    func showTag(_ tag: String) {
        selectedTags = [tag]
        sidebarRevealToken += 1
    }

    /// Files (and their locations) whose text contains the tag; RTF is left out because rewriting it would drop its formatting.
    private func filesWithTagInText(_ tag: String) -> [(LibraryFile, URL)] {
        library.allFiles
            .filter { f in Self.proseTypes.contains(f.type) && f.type != .rtf && f.inlineTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            .compactMap { f in library.resolve(f.id).map { (f, $0) } }
    }

    /// Rewrites `#old` in the text of the files that use it. Returns the names of the files that could not be changed.
    private func rewriteTag(_ old: String, to new: String?) -> [String] {
        var skipped: [String] = []
        for (file, url) in filesWithTagInText(old) {
            if let doc = documents.first(where: { $0.libraryID == file.id }), isDirty(doc.id) { skipped.append(file.name); continue }
            guard let loaded = try? FileLoader.read(url) else { skipped.append(file.name); continue }
            let updated = LibraryStore.replaceTag(old, with: new, in: loaded.text)
            guard updated != loaded.text else { continue }
            do { try FileLoader.write(updated, to: url, encoding: loaded.encoding) } catch { skipped.append(file.name); continue }
            if let doc = documents.first(where: { $0.libraryID == file.id }) { reload(doc.id) }
            else { library.setInlineTags(file.id, LibraryStore.extractTags(from: updated)) }
        }
        return skipped
    }

    private func reportSkipped(_ skipped: [String]) {
        if !skipped.isEmpty { errorMessage = L("Не удалось изменить файлы: %@. Сохраните или отмените правки в них и повторите.", skipped.joined(separator: ", ")) }
    }

    func renameTag(_ old: String, to raw: String) {
        let new = LibraryStore.cleanTag(raw)
        guard !new.isEmpty, new != old else { return }
        let affected = filesWithTagInText(old).count
        if affected > 0 {
            let alert = NSAlert()
            alert.messageText = L("Переименовать #%@ в #%@?", old, new)
            alert.informativeText = L("Тег записан в тексте файлов (%lld). Он будет изменён и там.", affected)
            alert.addButton(withTitle: L("Переименовать"))
            alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        reportSkipped(rewriteTag(old, to: new))
        library.renameTag(old, to: new)
        selectedTags = selectedTags.map { $0.caseInsensitiveCompare(old) == .orderedSame ? new : $0 }
        notify(L("Тег переименован: #%@", new), symbol: "tag.fill")
    }

    func deleteTag(_ tag: String) {
        let affected = filesWithTagInText(tag).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Удалить тег #%@?", tag)
        alert.informativeText = affected > 0
            ? L("Тег будет убран из списка и из текста файлов (%lld).", affected)
            : L("Тег будет убран из списка и у всех файлов.")
        alert.addButton(withTitle: L("Удалить тег"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reportSkipped(rewriteTag(tag, to: nil))
        library.deleteTag(tag)
        selectedTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        notify(L("Тег удалён: #%@", tag), symbol: "tag.slash.fill")
    }

    static let proseTypes: Set<FileType> = [.markdown, .text, .rtf, .tex]

    /// Hashtags written in a document become tags of its library file.
    private func noteTags(in doc: Document) {
        guard let id = doc.libraryID, Self.proseTypes.contains(doc.type) else { return }
        library.setInlineTags(id, LibraryStore.extractTags(from: doc.normalized))
    }

    private var tagTimers: [UUID: Timer] = [:]

    /// Tags typed into the text show up in the sidebar after a short pause, without saving the file.
    /// (A pause rather than every key press: "#р", "#ра", "#раб" must not become three tags.)
    private func scheduleTagRefresh(for doc: Document, text: String) {
        guard doc.libraryID != nil, Self.proseTypes.contains(doc.type) else { return }
        tagTimers[doc.id]?.invalidate()
        tagTimers[doc.id] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, let id = doc.libraryID else { return }
            self.tagTimers[doc.id] = nil
            self.library.setInlineTags(id, LibraryStore.extractTags(from: text))
        }
    }

    private var tagScanned = Set<UUID>()

    /// Reads the prose files of the library that were not read yet, so tags written in the texts show up in the sidebar.
    func scanTagsInLibrary() {
        // Paths are resolved here (the library is main-thread state); only the reading happens in the background.
        let files = library.allFiles.filter { Self.proseTypes.contains($0.type) && !tagScanned.contains($0.id) }
            .map { ($0.id, URL(fileURLWithPath: $0.path)) }
        tagScanned.formUnion(files.map(\.0))
        guard !files.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [(UUID, [String])] = []
            for (id, url) in files {
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size < 2_000_000,
                      let loaded = try? FileLoader.read(url) else { continue }
                found.append((id, LibraryStore.extractTags(from: loaded.text)))
            }
            DispatchQueue.main.async { self?.library.setInlineTags(found) }
        }
    }

    // MARK: File watching

    private func checkFiles() {
        for doc in documents where !changedOnDisk.contains(doc.id) {
            guard let now = Document.modificationDate(doc.url), now != doc.modified else { continue }
            // Never replace text the user is editing; offer the banner instead.
            if Preferences.shared.autoReload && drafts[doc.id] == nil { reload(doc.id) } else { changedOnDisk.insert(doc.id) }
        }
    }

    /// Re-reads a document from disk, keeping its tab, library entry and bookmarks.
    func reload(_ id: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        let old = documents[i]
        do {
            var fresh = try Document(url: old.url)
            fresh.id = old.id
            fresh.libraryID = old.libraryID
            noteTags(in: fresh)
            documents[i] = fresh
            drafts[id] = nil
            changedOnDisk.remove(id)
            recomputeMatches(reset: false)
        } catch {
            changedOnDisk.remove(id)
            errorMessage = L("Не удалось обновить «%@».", old.name)
        }
    }

    /// User-initiated reload: asks first when it would throw away unsaved edits.
    func refresh(_ id: UUID) {
        if confirmDiscard([id]) {
            reload(id)
            notify(L("Файл обновлён с диска."), symbol: "arrow.triangle.2.circlepath")
        }
    }

    /// Hides the banner until the file changes again.
    func ignoreChange(_ id: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[i].modified = Document.modificationDate(documents[i].url)
        changedOnDisk.remove(id)
    }

    // MARK: Editing

    func isDirty(_ id: UUID) -> Bool { drafts[id] != nil }
    func text(for doc: Document) -> String { drafts[doc.id] ?? doc.normalized }

    func setDraft(_ text: String, for doc: Document) {
        let value: String? = text == doc.normalized ? nil : text
        if drafts[doc.id] != value { drafts[doc.id] = value }
        scheduleTagRefresh(for: doc, text: text)
        // Hits move while the text is being typed; recount them without jumping the caret.
        if isFindVisible, !findQuery.isEmpty { recomputeMatches(reset: false, reveal: false) }
    }

    func discardDraft(_ id: UUID) {
        drafts[id] = nil
        if let doc = documents.first(where: { $0.id == id }) { noteTags(in: doc) }
    }

    /// Writes the edited text to the file in its original encoding, then re-reads it.
    @discardableResult
    func save(_ id: UUID) -> Bool {
        guard let doc = documents.first(where: { $0.id == id }), let draft = drafts[id] else { return true }
        let text = doc.text.contains("\r\n") ? draft.replacingOccurrences(of: "\n", with: "\r\n") : draft
        do {
            do {
                try FileLoader.write(text, to: doc.url, encoding: doc.encoding)
            } catch let error as CocoaError where error.code == .fileWriteInapplicableStringEncoding {
                // Emoji and other characters outside an 8-bit encoding: offer UTF-8 instead of losing them.
                guard confirmUTF8(for: doc) else { return false }
                try FileLoader.write(text, to: doc.url, encoding: "UTF-8")
            }
        } catch {
            errorMessage = L("Не удалось сохранить «%@».", doc.name)
            return false
        }
        reload(id)
        let saved = drafts[id] == nil
        if saved {
            notify(L("Сохранено: %@", doc.name))
            if doc.type == .rtf { notify(L("Файл RTF сохранён без форматирования."), symbol: "info.circle.fill") }
        }
        return saved
    }

    private func confirmUTF8(for doc: Document) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("В тексте есть символы (например, эмодзи), которых нет в кодировке %@.", doc.encoding)
        alert.informativeText = L("Сохранить файл «%@» в кодировке UTF-8?", doc.name)
        alert.addButton(withTitle: L("Сохранить в UTF-8"))
        alert.addButton(withTitle: L("Отмена"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Save As

    /// Formats offered by "Save As…": one per supported extension, Markdown first.
    static let exportExtensions: [String] = {
        let first = ["md", "txt", "json", "yaml", "csv", "log", "xml", "html", "ini", "toml", "tex", "rtf",
                     "py", "swift", "cpp", "cs", "js", "ts", "css", "php"]
        return first + FileType.allExtensions.filter { !first.contains($0) }
    }()

    /// Save panel with a format popup. The name field holds only the name: the format is picked in the popup and
    /// appended, so the extension never has to be erased by hand. A supported extension typed by hand wins.
    private func runFormatPanel(title: String, directory: URL?, base: String, selecting ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = title
        if let directory { panel.directoryURL = directory }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for ext in Self.exportExtensions {
            popup.addItem(withTitle: ".\(ext) — \(FileType.extensions[ext]?.title ?? ext)")
        }
        popup.selectItem(at: Self.exportExtensions.firstIndex(of: ext) ?? 0)
        let label = NSTextField(labelWithString: L("Формат:"))
        let stack = NSStackView(views: [label, popup])
        stack.spacing = 10
        stack.alignment = .centerY
        // A fixed-width container keeps the row centered under the panel's own fields instead of hugging the left edge.
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 44))
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        panel.accessoryView = box

        panel.nameFieldStringValue = base
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if FileType.extensions[url.pathExtension.lowercased()] == nil {
            url.appendPathExtension(Self.exportExtensions[popup.indexOfSelectedItem])
        }
        return url
    }

    /// Puts the whole text of the current document on the pasteboard.
    func copyAllText() {
        guard let doc = current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: doc), forType: .string)
        notify(L("Весь текст скопирован."), symbol: "doc.on.doc.fill")
    }

    /// Saves a copy of the current document (with unsaved edits) in a chosen format and place.
    /// The open document is left as it is.
    func presentSaveAsPanel() {
        guard let doc = current else { return }
        guard let url = runFormatPanel(
            title: L("Сохранить как…"), directory: doc.url.deletingLastPathComponent(),
            base: doc.url.deletingPathExtension().lastPathComponent, selecting: doc.url.pathExtension.lowercased()) else { return }
        export(doc, to: url)
    }

    /// Creates a new file: the user picks name, place and format, the file is written with a small starter
    /// template and opened in a tab, ready to edit.
    func presentNewFilePanel() {
        let lastDir = UserDefaults.standard.string(forKey: "newFileDirectory").map { URL(fileURLWithPath: $0) }
        guard let url = runFormatPanel(
            title: L("Новый файл"), directory: lastDir ?? current?.url.deletingLastPathComponent(),
            base: L("Без названия"), selecting: "md") else { return }
        let ext = url.pathExtension.lowercased()
        do {
            try FileLoader.write(FileType.template(forExtension: ext), to: url, encoding: ext == "rtf" ? "RTF" : "UTF-8")
        } catch {
            errorMessage = L("Не удалось создать «%@».", url.lastPathComponent)
            return
        }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "newFileDirectory")
        open(urls: [url])
        notify(L("Файл создан: %@", url.lastPathComponent), symbol: "doc.badge.plus")
    }

    private func export(_ doc: Document, to url: URL) {
        var body = text(for: doc)
        if doc.text.contains("\r\n") { body = body.replacingOccurrences(of: "\n", with: "\r\n") }
        let toRTF = url.pathExtension.lowercased() == "rtf"
        // Keep the source encoding for text formats; RTF is its own container, and RTF sources become UTF-8.
        var encoding = toRTF ? "RTF" : (doc.encoding == "RTF" ? "UTF-8" : doc.encoding)
        do {
            do { try FileLoader.write(body, to: url, encoding: encoding) }
            catch let error as CocoaError where error.code == .fileWriteInapplicableStringEncoding && encoding != "UTF-8" {
                encoding = "UTF-8"
                try FileLoader.write(body, to: url, encoding: encoding)
            }
        } catch {
            errorMessage = L("Не удалось сохранить «%@».", url.lastPathComponent)
            return
        }
        notify(L("Копия сохранена: %@", url.lastPathComponent), symbol: "square.and.arrow.down.fill")
    }

    /// Asks about every unsaved document among `ids`; false means the user cancelled.
    func confirmDiscard(_ ids: [UUID]) -> Bool {
        for id in ids {
            guard drafts[id] != nil, let doc = documents.first(where: { $0.id == id }) else { continue }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Сохранить изменения в «%@»?", doc.name)
            alert.informativeText = L("Изменения будут потеряны, если их не сохранить.")
            alert.addButton(withTitle: L("Сохранить"))
            alert.addButton(withTitle: L("Не сохранять"))
            alert.addButton(withTitle: L("Отмена"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: if !save(id) { return false }
            case .alertSecondButtonReturn: noteTags(in: doc)   // the edits are dropped: tags go back to the file's text
            default: return false
            }
        }
        return true
    }

    // MARK: Folded sections and check lists (Reading mode)

    /// The arrow next to a Title or Heading folds everything up to the next heading of the same or a higher level.
    func toggleSection(_ docID: UUID, key: String) {
        var set = collapsedSections[docID] ?? []
        if !set.insert(key).inserted { set.remove(key) }
        collapsedSections[docID] = set.isEmpty ? nil : set
    }

    // MARK: Find and bookmarks

    var currentMatch: SearchMatch? { matches.indices.contains(matchIndex) ? matches[matchIndex] : nil }

    func showFind() {
        isFindVisible = true
        findFocusToken += 1
        recomputeMatches(reset: false)
    }

    func hideFind() {
        isFindVisible = false
        matches = []
        matchIndex = 0
    }

    /// Hits are counted in the focused pane's document; every pane paints the same query.
    func recomputeMatches(reset: Bool, reveal: Bool = true) {
        guard isFindVisible, !findQuery.isEmpty, let doc = current else {
            matches = []
            matchIndex = 0
            return
        }
        // The editor is searched as it is right now, unsaved changes included.
        matches = Searcher.matches(query: findQuery, inLines: text(for: doc).components(separatedBy: "\n"))
        matchIndex = reset ? 0 : min(matchIndex, max(0, matches.count - 1))
        if reveal { revealCurrentMatch() }
    }

    func stepMatch(_ delta: Int) {
        guard isFindVisible else { showFind(); return }
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        revealCurrentMatch()
    }

    private func revealCurrentMatch() {
        if let m = currentMatch { scrollTarget = ScrollTarget(unit: m.unit) }
    }

    /// Jumps to a bookmarked line (0-based) in the source view.
    func goToLine(_ line: Int) {
        mode = .developer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scrollTarget = ScrollTarget(unit: line)
        }
    }

    // MARK: Tabs and panes

    func assign(_ docID: UUID, to pane: Pane) {
        if pane == .right {
            isSplit = true
            rightSelection = docID
        } else {
            selection = docID
        }
        focusedPane = pane
        selectedFileID = documents.first { $0.id == docID }?.libraryID
    }

    func selectTab(_ id: UUID, inRight: Bool = false) {
        assign(id, to: inRight ? .right : (isSplit ? focusedPane : .left))
    }

    func focus(_ pane: Pane) {
        guard isSplit, focusedPane != pane else { return }
        focusedPane = pane
        selectedFileID = current?.libraryID
    }

    func toggleSplit() {
        isSplit.toggle()
        if isSplit {
            // Code on the right, the result on the left: edit in one, see it in the other.
            paneModes[.right] = .developer
            if rightSelection == nil || doc(in: .right) == nil {
                rightSelection = documents.first { $0.id != selection }?.id
            }
        } else {
            focusedPane = .left
            selectedFileID = current?.libraryID
        }
    }

    func cycleTab(_ delta: Int) {
        guard documents.count > 1 else { return }
        let pane: Pane = isSplit ? focusedPane : .left
        let index = documents.firstIndex { $0.id == docID(in: pane) } ?? 0
        let next = (index + delta + documents.count) % documents.count
        assign(documents[next].id, to: pane)
    }

    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard confirmDiscard([id]) else { return false }
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return true }
        let closed = documents[i]
        documents.remove(at: i)
        changedOnDisk.remove(id)
        drafts[id] = nil
        collapsedSections[id] = nil
        tagTimers[id]?.invalidate()
        tagTimers[id] = nil
        noteTags(in: closed)

        let neighbour = documents.indices.contains(i) ? documents[i].id : documents.last?.id
        if selection == id { selection = neighbour }
        if rightSelection == id { rightSelection = neighbour }

        if documents.isEmpty {
            isSplit = false
            focusedPane = .left
        }
        selectedFileID = current?.libraryID
        return true
    }

    /// The window's close button: asks about every unsaved document, then drops the edits that were not saved.
    func confirmCloseWindow() -> Bool {
        guard documents.contains(where: { isDirty($0.id) }) else { return true }
        guard confirmDiscard(documents.map(\.id)) else { return false }
        drafts = [:]
        documents.forEach { noteTags(in: $0) }
        return true
    }

    func closeOthers(keeping id: UUID) {
        guard confirmDiscard(documents.map(\.id).filter { $0 != id }) else { return }
        drafts = drafts.filter { $0.key == id }
        documents.filter { $0.id != id }.forEach { noteTags(in: $0) }
        documents.removeAll { $0.id != id }
        selection = id
        rightSelection = nil
        isSplit = false
        focusedPane = .left
        selectedFileID = current?.libraryID
    }

    /// Removes a folder from the sidebar together with its subfolders and files (the files on disk stay).
    func deleteFolder(_ id: UUID) { removeFromLibrary(folders: [id], files: []) }

    /// Removes folders (with everything in them) and files from the sidebar; the files on disk stay. Asks first unless it is
    /// a single file or an empty folder, and closes the tabs of the files that go away.
    func removeFromLibrary(folders: Set<UUID>, files: Set<UUID>) {
        var doomedFolders = Set<UUID>()
        for id in folders { doomedFolders.formUnion(library.subtreeIDs(of: id)) }
        let loose = files.filter { id in !(library.file(id)?.folderID.map(doomedFolders.contains) ?? false) }
        let inFolders = doomedFolders.isEmpty ? 0 : library.allFiles.filter { $0.folderID.map(doomedFolders.contains) ?? false }.count
        let total = inFolders + loose.count
        guard !folders.isEmpty || !files.isEmpty else { return }
        if folders.count + files.count > 1 || total > 0 && !folders.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            if folders.count == 1, files.isEmpty, let name = library.folder(folders.first!)?.name {
                alert.messageText = L("Удалить папку «%@»?", name)
            } else {
                alert.messageText = L("Убрать выбранное из боковой панели?")
            }
            alert.informativeText = L("Будут убраны папки (%lld, вместе со всеми вложенными) и файлы (%lld). Сами файлы на диске не удаляются.", doomedFolders.count, total)
            alert.addButton(withTitle: L("Убрать"))
            alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let leaving = Set(library.allFiles.filter { f in f.folderID.map(doomedFolders.contains) ?? false }.map(\.id)).union(loose)
        for doc in documents where doc.libraryID.map(leaving.contains) ?? false {
            guard close(doc.id) else { return }
        }
        for id in folders { library.deleteFolder(id) }
        library.remove(loose)
        notify(L("Убрано из боковой панели: %lld.", folders.count + files.count), symbol: "trash.fill")
    }

    /// Removes a file from the library (the file on disk stays) and closes it if open.
    func removeFromLibrary(_ id: UUID) {
        if let doc = documents.first(where: { $0.libraryID == id }), !close(doc.id) { return }
        library.remove(id)
    }
}


/// Lets the Open panel show folders and the file types Grizzly reads, and grey out everything else.
final class OpenPanelFilter: NSObject, NSOpenSavePanelDelegate {
    private let allows: (URL) -> Bool
    init(_ allows: @escaping (URL) -> Bool) { self.allows = allows }
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { allows(url) }
}
