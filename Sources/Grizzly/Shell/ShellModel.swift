import AppKit
import ImageIO
import SwiftUI

enum ShellSection: Equatable {
    case welcome
    case home
    case files
    case page(UUID)
    case backups
    case settings
    case trash
    case tag(UUID)
}

/// Пространство, которое уже открывали на этом Mac.
struct KnownWorkspace: Codable, Equatable, Identifiable {
    var path: String
    var name: String
    var id: String { path }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Сборка зависимостей и состояние оболочки. Принадлежит AppDelegate, новых singleton нет.
@MainActor
final class ShellModel: ObservableObject {
    @Published var section: ShellSection = .welcome {
        didSet {
            guard oldValue != section, !restoringHistory else { return }
            if oldValue != .welcome { backStack.append(oldValue) }
            forwardStack = []
        }
    }
    @Published private(set) var backStack: [ShellSection] = []
    @Published private(set) var forwardStack: [ShellSection] = []
    private var restoringHistory = false
    @Published var showsSearch = false
    @Published private(set) var backlinks: [Backlink] = []
    @Published private(set) var workspaceName = ""
    @Published private(set) var pages: [Page] = []
    @Published private(set) var saveStatus: SaveStatus = .saved
    @Published private(set) var editor: PageEditorModel? {
        didSet { if oldValue !== editor { oldValue?.closePanels() } }
    }
    @Published var errorMessage: String?
    @Published private(set) var recentFiles: [URL] = []
    @Published private(set) var look = WorkspaceLook()
    @Published var showsLookSheet = false
    @Published private(set) var knownWorkspaces: [KnownWorkspace] = []
    @Published private(set) var tags: [Tag] = []
    /// Теги страниц в порядке имён.
    @Published private(set) var pageTags: [UUID: [UUID]] = [:]
    @Published var preview: FilePreview?
    @Published private(set) var trashItems: [TrashItem] = []
    @Published private(set) var backups: [BackupItem] = []
    @Published private(set) var busyMessage: String?
    @Published var notice: String?

    private var session: WorkspaceSession?
    private var store: SQLiteWorkspace?
    private var navigation: Task<Void, Never>?
    private let lastWorkspaceKey = "lastWorkspacePath"
    private let lastPageKey = "lastPageID"
    private let knownWorkspacesKey = "knownWorkspaces"
    private var imageCache: [UUID: NSImage] = [:]

    var isOpen: Bool { session != nil }
    var workspaceRoot: URL? { store?.layout.root }

    struct BackupItem: Identifiable, Equatable {
        var url: URL
        var date: Date
        var size: Int64
        var id: URL { url }
    }

    // MARK: Пространства

    func loadKnownWorkspaces() {
        guard let data = UserDefaults.standard.data(forKey: knownWorkspacesKey),
              let list = try? JSONDecoder().decode([KnownWorkspace].self, from: data) else { return }
        knownWorkspaces = list
    }

    private func saveKnownWorkspaces() {
        if let data = try? JSONEncoder().encode(knownWorkspaces) { UserDefaults.standard.set(data, forKey: knownWorkspacesKey) }
    }

    /// Последнее открытое — первым.
    private func rememberWorkspace(path: String, name: String) {
        let canonical = Self.canonical(path)
        knownWorkspaces.removeAll { Self.canonical($0.path) == canonical }
        knownWorkspaces.insert(KnownWorkspace(path: canonical, name: name), at: 0)
        saveKnownWorkspaces()
    }

    /// Один каталог в разных написаниях (симлинк, /private, косая на конце) — одно пространство.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func isCurrent(_ item: KnownWorkspace) -> Bool {
        workspaceRoot.map { Self.canonical($0.path) == Self.canonical(item.path) } ?? false
    }

    /// Убирает из списка; папка и данные остаются на месте.
    func forgetWorkspace(_ item: KnownWorkspace) {
        knownWorkspaces.removeAll { $0.path == item.path }
        saveKnownWorkspaces()
    }

    func switchWorkspace(_ item: KnownWorkspace) {
        guard !isCurrent(item) else { return }
        guard item.exists else {
            errorMessage = String(format: L("Папка пространства не найдена: %@"), item.path)
            return
        }
        open(at: URL(fileURLWithPath: item.path))
    }

    // MARK: Вид пространства

    func image(for asset: UUID?) -> NSImage? {
        guard let asset else { return nil }
        return imageCache[asset]
    }

    private func cacheImages(for look: WorkspaceLook) async {
        guard let store else { return }
        for id in [look.logoAsset, look.coverAsset].compactMap({ $0 }) where imageCache[id] == nil {
            if let url = try? await store.assetURL(id) { imageCache[id] = await Self.loadImage(url) }
        }
        objectWillChange.send()
    }

    /// Уменьшенная копия вне главного потока: полноразмерная картинка не нужна логотипу и обложке.
    private static func loadImage(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 2400]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
    }

    /// `candidates` — картинки, выбранные в окне настройки: невыбранные удаляются, как и заменённые.
    func saveLook(_ new: WorkspaceLook, name: String, candidates: Set<UUID>) {
        enqueue {
            guard let store = self.store else { return }
            let unused = candidates.union([self.look.logoAsset, self.look.coverAsset].compactMap { $0 })
                .subtracting([new.logoAsset, new.coverAsset].compactMap { $0 })
            try await store.setLook(new)
            self.look = new
            await self.cacheImages(for: new)
            for id in unused { try? await store.deleteAsset(id); self.imageCache[id] = nil }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, clean != self.workspaceName {
                try await store.rename(to: clean)
                self.workspaceName = clean
                self.rememberWorkspace(path: store.layout.root.path, name: clean)
            }
        }
    }

    /// Окно настройки закрыто без сохранения: выбранные картинки не нужны.
    func discardAssets(_ ids: Set<UUID>) {
        enqueue {
            guard let store = self.store else { return }
            for id in ids {
                try? await store.deleteAsset(id)
                self.imageCache[id] = nil
            }
        }
    }

    /// Копирует изображение в пространство: архив и восстановление его сохранят. nil — выбор отменён или не удался.
    func pickImage(_ done: @escaping (UUID?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = L("Выбрать")
        guard panel.runModal() == .OK, let url = panel.url, let owner = store else { return done(nil) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 64 * 1024 * 1024 else {
            errorMessage = L("Изображение слишком большое: до 64 МБ.")
            return done(nil)
        }
        Task { @MainActor in
            guard let image = await Self.loadImage(url) else {
                self.errorMessage = L("Не удалось прочитать изображение.")
                return done(nil)
            }
            // За время выбора пространство могло смениться: чужой файл в него не попадёт.
            guard self.store === owner else { return done(nil) }
            do {
                let asset = try await owner.addAsset(copying: url, now: SystemClock().nowMillis())
                self.imageCache[asset.id] = image
                done(asset.id)
            } catch {
                self.errorMessage = Self.describe(error)
                done(nil)
            }
        }
    }

    // MARK: Теги

    private func reloadTags() async throws {
        guard let store else { return }
        tags = try await store.tags()
        pageTags = try await store.pageTags()
    }

    func tagsOf(page: UUID) -> [Tag] {
        (pageTags[page] ?? []).compactMap { id in tags.first { $0.id == id } }
    }

    func toggleTag(_ tag: UUID, on page: UUID) {
        enqueue {
            guard let store = self.store else { return }
            try await store.setTag(tag, on: page, self.pageTags[page]?.contains(tag) != true)
            try await self.reloadTags()
        }
    }

    func addTag(named name: String, to page: UUID) {
        enqueue {
            guard let store = self.store else { return }
            let tag = try await store.createTag(name: name, color: nil, now: SystemClock().nowMillis())
            try await store.setTag(tag.id, on: page, true)
            try await self.reloadTags()
        }
    }

    func renameTag(_ id: UUID, to name: String) {
        enqueue {
            guard let store = self.store, !Tag.key(name).isEmpty else { return }
            try await store.renameTag(id, to: name)
            try await self.reloadTags()
            // Тег мог объединиться с другим: экран старого показывать нельзя.
            if !self.tags.contains(where: { $0.id == id }) { self.section = .home }
        }
    }

    func setTagColor(_ id: UUID, _ color: String?) {
        enqueue {
            guard let store = self.store else { return }
            try await store.setTagColor(id, color: color)
            try await self.reloadTags()
        }
    }

    func deleteTag(_ id: UUID) {
        let alert = NSAlert()
        alert.messageText = String(format: L("Удалить тег «%@»?"), tags.first { $0.id == id }?.name ?? "")
        alert.informativeText = L("Тег исчезнет со всех страниц. Сами страницы останутся.")
        alert.addButton(withTitle: L("Удалить"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        enqueue {
            guard let store = self.store else { return }
            try await store.deleteTag(id)
            try await self.reloadTags()
            if self.section == .tag(id) { self.section = .home }
        }
    }

    func goTag(_ id: UUID) {
        leavePage { self.section = .tag(id) }
    }

    /// Обычные настройки приложения; не пространство. Каталог отдельный от оригинального Grizzly.
    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppEdition.supportDirectoryName, isDirectory: true)
    }

    private func backupDirectory(for id: UUID) -> URL {
        supportDirectory.appendingPathComponent("Backups/\(id.lowercasedString)", isDirectory: true)
    }

    // MARK: Пространство

    func restoreLastWorkspace() {
        loadRecentFiles()
        guard let path = UserDefaults.standard.string(forKey: lastWorkspaceKey),
              FileManager.default.fileExists(atPath: path) else { return }
        open(at: URL(fileURLWithPath: path))
    }

    func presentCreate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Создать")
        panel.message = L("Выберите пустую папку на локальном диске. Не используйте папки облачной синхронизации.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enqueue {
            let name = L("Моё пространство")
            // Не на главном потоке: проверка базы и миграция могут быть долгими.
            let store = try await Task.detached(priority: .userInitiated) { try SQLiteWorkspace.create(at: url, name: name) }.value
            try await self.adopt(store)
        }
    }

    func presentOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = L("Открыть")
        panel.message = L("Выберите папку пространства Grizzly Notes.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(at: url)
    }

    private func open(at url: URL) {
        enqueue {
            var options = SQLiteWorkspace.Options()
            let root = self.supportDirectory.appendingPathComponent("Backups/before-migration", isDirectory: true)
            // Проверенная копия обязательна до изменения формата (ТЗ §8).
            options.beforeMigration = { snapshotter, dir in
                let stamp = Self.stamp(Date())
                try BackupService.create(workspaceRoot: dir, snapshotter: snapshotter, inspector: SQLiteSnapshotInspector(),
                                         destination: root.appendingPathComponent("\(dir.lastPathComponent)-\(stamp).grizzlybackup"),
                                         appVersion: options.appVersion, now: options.clock.nowMillis())
            }
            let opts = options
            let store = try await Task.detached(priority: .userInitiated) { try SQLiteWorkspace.open(at: url, options: opts) }.value
            try await self.adopt(store)
        }
    }

    /// Сначала готовит новое пространство целиком, и только затем закрывает прежнее:
    /// сбой открытия оставляет пользователя в том пространстве, где он работал.
    private func adopt(_ store: SQLiteWorkspace) async throws {
        do {
            let name = try await store.workspaceName()
            let loadedLook = try await store.look()
            let session = WorkspaceSession(store: store, name: name)
            session.coordinator.onStatusChange = { [weak self] in self?.saveStatus = $0 }
            try await session.refreshPages()
            let loadedTags = try await store.tags()
            let loadedPageTags = try await store.pageTags()
            try await closeSession()
            self.store = store
            self.session = session
            workspaceName = name
            imageCache = [:]
            look = loadedLook
            tags = loadedTags
            pageTags = loadedPageTags
            pages = session.pages
            saveStatus = .saved
            await cacheImages(for: loadedLook)
            rememberWorkspace(path: store.layout.root.path, name: name)
            if section != .files { section = .home }
            UserDefaults.standard.set(store.layout.root.path, forKey: lastWorkspaceKey)
            try await reloadBackups()
            // После перезапуска пользователь возвращается к той же странице.
            if section != .files, let raw = UserDefaults.standard.string(forKey: lastPageKey), let id = UUID(uuidString: raw), pages.contains(where: { $0.id == id }) {
                try await show(id)
            }
        } catch {
            if self.store !== store { store.close() } // Блокировка нового пространства не должна остаться.
            throw error
        }
    }

    func closeWorkspace() {
        enqueue {
            try await self.closeSession()
            UserDefaults.standard.removeObject(forKey: self.lastWorkspaceKey)
            self.section = .welcome
        }
    }

    private func closeSession() async throws {
        // Модель редактора живёт до подтверждённой записи: при отказе нужен аварийный экспорт.
        if let session { try await session.close() }
        editor = nil
        session = nil
        store = nil
        pages = []
        workspaceName = ""
        look = WorkspaceLook()
        tags = []
        pageTags = [:]
    }

    // MARK: Страницы

    func createPage(parent: UUID? = nil) {
        enqueue {
            guard let session = self.session else { return }
            let page = try await session.createPage(parent: parent, title: L("Без названия"))
            self.pages = session.pages
            try await self.show(page.id)
        }
    }

    /// Папка в пространстве — страница со значком папки: у неё такие же подстраницы и UUID, файловой папки нет.
    func createFolder(parent: UUID? = nil) {
        enqueue {
            guard let session = self.session else { return }
            let page = try await session.createFolder(parent: parent, title: L("Новая папка"))
            self.pages = session.pages
            try await self.show(page.id)
        }
    }

    func openPage(_ id: UUID) {
        enqueue { try await self.show(id) }
    }

    /// Навигация последовательна: двойной клик или быстрая смена страниц не должны открыть две сессии разом.
    private func enqueue(_ body: @escaping @MainActor () async throws -> Void) {
        let previous = navigation
        navigation = Task { @MainActor in
            await previous?.value
            do { try await body() }
            catch { self.errorMessage = Self.describe(error) }
        }
    }

    private func show(_ id: UUID) async throws {
        guard let session else { return }
        let editorSession = try await session.open(id)
        pages = session.pages
        installEditor(editorSession, id: id)
    }

    private func installEditor(_ editorSession: EditorSession, id: UUID) {
        let style = BlockTextStyle(ink: Tokens.inkNS, muted: Tokens.mutedNS, accent: Tokens.accentNS, line: Tokens.lineNS, soft: Tokens.softNS)
        editor = PageEditorModel(session: editorSession, style: style) { [weak self] in self?.errorMessage = $0 }
        editor?.controller.pageSearch = { [weak self] in self?.linkCandidates($0) ?? [] }
        editor?.controller.onOpenPage = { [weak self] in self?.followLink(to: $0) }
        backlinks = []
        section = .page(id)
        UserDefaults.standard.set(id.uuidString, forKey: lastPageKey)
    }

    func goHome() {
        UserDefaults.standard.removeObject(forKey: lastPageKey)
        leavePage { self.section = self.isOpen ? .home : .welcome }
    }

    // MARK: История переходов

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(section)
        restore(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(section)
        restore(target)
    }

    private func restore(_ target: ShellSection) {
        enqueue {
            self.restoringHistory = true
            defer { self.restoringHistory = false }
            if case .page(let id) = target {
                // Страница могла уйти в корзину: на неё не переходим.
                if self.pages.contains(where: { $0.id == id }) { try await self.show(id) } else { self.section = .home }
            } else {
                try await self.session?.closeEditor()
                self.editor = nil
                self.section = target
            }
        }
    }

    // MARK: Поиск и ссылки

    func search(_ query: String) async -> [SearchHit] {
        (try? await store?.search(query)) ?? []
    }

    /// Страницы для ссылки «[[»: по заголовку, без текущей корзины.
    func linkCandidates(_ query: String) -> [(id: UUID, title: String)] {
        let key = SearchText.normalize(query.trimmingCharacters(in: .whitespaces))
        let list = pages.filter { key.isEmpty || SearchText.normalize($0.title).contains(key) }
        return Array(list.prefix(12)).map { ($0.id, $0.title) }
    }

    func reloadBacklinks(for page: UUID) {
        enqueue {
            guard let session = self.session, let store = self.store else { return }
            try await session.coordinator.flush() // Ссылки считаются по записанному тексту.
            self.backlinks = try await store.backlinks(to: page)
        }
    }

    /// Переход по ссылке. Страница в корзине не подменяется другой (FR-04).
    func followLink(to id: UUID) {
        if pages.contains(where: { $0.id == id }) {
            openPage(id)
        } else {
            notice = L("Страница, на которую ведёт ссылка, в корзине.")
        }
    }

    func openPage(_ id: UUID, block: UUID?) {
        enqueue {
            try await self.show(id)
            if let block { self.editor?.controller.reveal(block) }
        }
    }

    // MARK: Действия со страницей

    func toggleFavorite(_ id: UUID) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            let isFavorite = self.pages.first { $0.id == id }?.favoriteKey != nil
            try await store.setFavorite(id, !isFavorite)
            try await session.refreshPages()
            self.pages = session.pages
        }
    }

    func setIcon(_ id: UUID, _ icon: String?) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await store.setPageIcon(id, icon: icon)
            try await session.refreshPages()
            self.pages = session.pages
        }
    }

    func toggleFullWidth(_ id: UUID) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await store.setPageFullWidth(id, self.pages.first { $0.id == id }?.fullWidth != true)
            try await session.refreshPages()
            self.pages = session.pages
        }
    }

    func duplicatePage(_ id: UUID) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await session.coordinator.flush()
            let title = self.pages.first { $0.id == id }?.title ?? ""
            let copy = try await store.duplicatePage(id, title: String(format: L("%@ (копия)"), title), ids: RandomIDs(), now: SystemClock().nowMillis())
            try await session.refreshPages()
            self.pages = session.pages
            try await self.reloadTags()
            try await self.show(copy)
        }
    }

    var favorites: [Page] {
        pages.filter { $0.favoriteKey != nil }.sorted { ($0.favoriteKey ?? "") < ($1.favoriteKey ?? "") }
    }

    func goSettings() {
        leavePage { self.section = .settings }
    }

    func goTrash() {
        leavePage {
            self.section = .trash
            self.enqueue { try await self.reloadTrash() }
        }
    }

    // MARK: Корзина

    private func reloadTrash() async throws {
        trashItems = (try await session?.store.trashItems()) ?? []
    }

    /// Удаление мягкое: страницу можно вернуть из корзины.
    func trash(_ id: UUID) {
        enqueue {
            guard let session = self.session else { return }
            try await session.trash(id)
            self.pages = session.pages
            if session.editor == nil, self.editor != nil {
                self.editor = nil
                UserDefaults.standard.removeObject(forKey: self.lastPageKey)
                if case .page = self.section { self.section = .home }
            }
            try await self.reloadTrash()
            try await self.reloadTags()
            self.notice = L("Страница перемещена в корзину.")
        }
    }

    func restoreFromTrash(_ item: TrashItem) {
        enqueue {
            guard let session = self.session else { return }
            let moved = try await session.restore(batch: item.batchID)
            self.pages = session.pages
            try await self.reloadTrash()
            try await self.reloadTags()
            self.notice = moved ? L("Прежняя родительская страница недоступна: страница восстановлена в корень.") : L("Страница восстановлена.")
        }
    }

    /// Окончательное удаление только после явного подтверждения.
    func purgeFromTrash(_ item: TrashItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("Удалить «%@» навсегда?"), item.page.title.isEmpty ? L("Без названия") : item.page.title)
        alert.informativeText = item.descendants > 0
            ? String(format: L("Вместе с подстраницами (%d). Это действие нельзя отменить."), item.descendants)
            : L("Это действие нельзя отменить.")
        alert.addButton(withTitle: L("Удалить навсегда"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        enqueue {
            try await self.session?.store.purgeTrash(batch: item.batchID)
            try await self.reloadTrash()
        }
    }

    func goBackups() {
        leavePage {
            self.section = .backups
            Task { try? await self.reloadBackups() }
        }
    }

    func goFiles() {
        leavePage { self.section = .files }
    }

    /// Уход со страницы: правка уже в очереди записи; снимок истории делается после неё.
    private func leavePage(_ then: @escaping () -> Void) {
        then()
        guard let session, session.editor != nil else { return }
        enqueue {
            try await session.closeEditor()
            self.editor = nil
            self.pages = session.pages
        }
    }

    func rename(_ id: UUID, to title: String) {
        guard let session else { return }
        session.rename(id, title: title)
        pages = session.pages
    }

    func move(_ id: UUID, toParent parent: UUID?) {
        act {
            guard let session = self.session else { return }
            try await session.move(id, toParent: parent, afterSibling: nil)
            self.pages = session.pages
        }
    }

    // MARK: Файлы на диске

    private let recentFilesKey = "recentFiles"

    func presentOpenFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Открыть")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        previewFile(url)
    }

    /// Показывает файл без изменений и без импорта.
    func previewFile(_ url: URL) {
        do {
            let file = try TextFileReader.read(url)
            rememberFile(url)
            leavePage { self.section = .files }
            preview = FilePreview(url: url, text: file.text, encoding: file.encoding)
        } catch {
            errorMessage = String(format: L("Не удалось прочитать файл: %@"), Self.describe(error))
        }
    }

    private func rememberFile(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(20))
        UserDefaults.standard.set(paths, forKey: recentFilesKey)
        loadRecentFiles()
    }

    /// Убирает строку из списка; файл на диске не трогается.
    func forgetFile(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: recentFilesKey)
        loadRecentFiles()
    }

    func loadRecentFiles() {
        recentFiles = (UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Импорт в новую страницу. Оригинал только читается.
    func importFile(_ url: URL) {
        enqueue {
            guard let session = self.session else { return }
            // Чтение и разбор вне главного потока; страница появляется только после успешного разбора.
            let fragments = try await Task.detached(priority: .userInitiated) {
                MarkdownImport.fragments(from: try TextFileReader.read(url).text)
            }.value
            let title = url.deletingPathExtension().lastPathComponent
            let page = try await session.createPage(parent: nil, title: title)
            self.pages = session.pages
            let opened = try await session.open(page.id)
            if let first = opened.document.blocks.first, !fragments.isEmpty {
                try opened.perform(.replaceRange(BlockSelection(block: first.id, offset: 0), fragments), recordUndo: false)
            }
            self.pages = session.pages
            self.installEditor(opened, id: page.id)
            self.notice = String(format: L("Импортировано блоков: %d. Файл не изменён."), fragments.count)
        }
    }

    func retrySave() { session?.coordinator.retryNow() }

    /// Текст открытой страницы из памяти, когда записать его в базу не получается.
    func emergencyExport() {
        guard let editor, let title = pages.first(where: { $0.id == editor.pageID })?.title else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try editor.emergencyText(title: title).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = Self.describe(error) }
    }

    // MARK: Резервные копии

    func reloadBackups() async throws {
        guard let store else { backups = []; return }
        let dir = backupDirectory(for: try await store.workspaceID())
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        backups = urls.filter { $0.pathExtension == "grizzlybackup" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return BackupItem(url: url, date: values?.contentModificationDate ?? .distantPast, size: Int64(values?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    func makeBackup() {
        act {
            guard let store = self.store else { return }
            let dir = self.backupDirectory(for: try await store.workspaceID())
            try await self.runBackup(to: dir.appendingPathComponent("\(Self.stamp(Date())).grizzlybackup"))
        }
    }

    func makeBackupAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(workspaceName)-\(Self.stamp(Date())).grizzlybackup"
        panel.message = L("Для защиты от отказа диска выберите другой носитель.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        act { try await self.runBackup(to: url) }
    }

    private func runBackup(to url: URL) async throws {
        guard let store, let session else { return }
        try await session.coordinator.flush()
        busyMessage = L("Подготовка архива…")
        defer { busyMessage = nil }
        let root = store.layout.root
        let result = try await Task.detached(priority: .userInitiated) {
            try BackupService.create(workspaceRoot: root, snapshotter: store, inspector: SQLiteSnapshotInspector(), destination: url,
                                     appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev",
                                     now: SystemClock().nowMillis())
        }.value
        notice = result.isComplete ? L("Копия создана, проверка пройдена.")
                                   : String(format: L("Копия создана, но не полна: нет вложений (%d)."), result.manifest.missing.count)
        try await reloadBackups()
    }

    func presentRestore(archive: URL? = nil) {
        var source = archive
        if source == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "grizzlybackup") ?? .data]
            panel.prompt = L("Выбрать")
            panel.message = L("Выберите архив резервной копии.")
            guard panel.runModal() == .OK else { return }
            source = panel.url
        }
        guard let source else { return }
        let target = NSOpenPanel()
        target.canChooseFiles = false
        target.canChooseDirectories = true
        target.canCreateDirectories = true
        target.prompt = L("Восстановить сюда")
        target.message = L("Выберите новую пустую папку. Текущее пространство не изменится.")
        guard target.runModal() == .OK, let url = target.url else { return }
        act {
            self.busyMessage = L("Восстановление…")
            defer { self.busyMessage = nil }
            try await Task.detached(priority: .userInitiated) {
                try RestoreService.restore(archive: source, to: url, inspector: SQLiteSnapshotInspector(), newID: UUID(), now: SystemClock().nowMillis())
            }.value
            self.offerToOpen(url)
        }
    }

    private func offerToOpen(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L("Пространство восстановлено.")
        alert.informativeText = url.path
        alert.addButton(withTitle: L("Открыть"))
        alert.addButton(withTitle: L("Не сейчас"))
        if alert.runModal() == .alertFirstButtonReturn { open(at: url) }
    }

    // MARK: Завершение

    /// Завершение дожидается записи; если запись не идёт, пользователь выбирает, что делать, а не теряет правки молча.
    func prepareToTerminate(reply: @escaping (Bool) -> Void) {
        guard let session else { return reply(true) }
        Task {
            let finished = await Self.finishes(within: 5) { try await session.close() }
            if finished {
                self.session = nil
                self.store = nil
                return reply(true)
            }
            let alert = NSAlert()
            alert.messageText = L("Не удалось сохранить правки")
            alert.informativeText = L("Правки остаются в приложении. Повторите запись, сохраните текст в файл или выйдите без сохранения.")
            alert.addButton(withTitle: L("Повторить"))
            alert.addButton(withTitle: L("Аварийный экспорт"))
            alert.addButton(withTitle: L("Выйти без сохранения"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: self.prepareToTerminate(reply: reply)
            case .alertSecondButtonReturn:
                self.emergencyExport()
                reply(false)
            default: reply(true)
            }
        }
    }

    private static func finishes(within seconds: UInt64, _ work: @escaping @MainActor () async throws -> Void) async -> Bool {
        // Группа задач ждала бы проигравшую ветку, поэтому гонка без неё: зависшая запись не блокирует диалог.
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var finished = false
            let finish: @MainActor (Bool) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                do { try await work(); finish(true) } catch { finish(false) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                finish(false)
            }
        }
    }

    // MARK: Служебное

    /// Ошибка показывается пользователю; пустое пространство её не маскирует.
    private func act(_ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await body() }
            catch { self.errorMessage = Self.describe(error) }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    func children(of parent: UUID?) -> [Page] {
        pages.filter { $0.parentID == parent }
    }

    func path(of id: UUID) -> [Page] {
        var out: [Page] = []
        var current = pages.first { $0.id == id }?.parentID
        while let c = current, let page = pages.first(where: { $0.id == c }) {
            out.insert(page, at: 0)
            current = page.parentID
        }
        return out
    }

    /// Куда можно переместить страницу: не в неё саму и не в потомков.
    func moveTargets(for id: UUID) -> [Page] {
        var banned: Set<UUID> = [id]
        var added = true
        while added {
            added = false
            for p in pages where p.parentID.map({ banned.contains($0) }) == true && !banned.contains(p.id) {
                banned.insert(p.id)
                added = true
            }
        }
        return pages.filter { !banned.contains($0.id) }
    }

    var recent: [Page] {
        pages.filter { $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? 0) > ($1.lastOpenedAt ?? 0) }.prefix(5).map { $0 }
    }
}
