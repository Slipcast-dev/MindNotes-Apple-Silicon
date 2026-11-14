import CryptoKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ShellSection: Equatable {
    case welcome
    case home
    case files
    case page(UUID)
    case database(UUID)
    case backups
    case settings
    case trash
    case templates
    /// Календарь: события и задачи из Календаря и Напоминаний macOS.
    case calendar
    case tag(UUID)
    /// Страница под паролем (ADR-0017): вместо содержимого — окно ввода пароля.
    case locked(UUID)
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
            guard oldValue != section, oldValue != .welcome, section != .welcome else { return }
            backStack.append(oldValue)
            forwardStack = []
        }
    }
    @Published private(set) var backStack: [ShellSection] = []
    @Published private(set) var forwardStack: [ShellSection] = []
    @Published var showsSearch = false
    @Published private(set) var backlinks: [Backlink] = []
    @Published private(set) var workspaceName = ""
    @Published private(set) var pages: [Page] = [] {
        didSet { refreshPageIndex() }
    }
    @Published private(set) var saveStatus: SaveStatus = .saved
    @Published private(set) var editor: PageEditorModel? {
        didSet { if oldValue !== editor { oldValue?.closePanels() } }
    }
    @Published var errorMessage: String?
    @Published private(set) var recentFiles: [URL] = []
    /// Боковая панель (M14): свёрнута ли и её ширина; запоминаются для этого Mac.
    @Published var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }
    @Published var sidebarWidth: Double = ShellModel.savedSidebarWidth
    static let sidebarWidths: ClosedRange<Double> = 200...480
    private static var savedSidebarWidth: Double {
        let v = UserDefaults.standard.double(forKey: "sidebarWidth")
        return v == 0 ? Double(Tokens.sidebarWidth) : min(sidebarWidths.upperBound, max(sidebarWidths.lowerBound, v))
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed.toggle() }
    }

    func setSidebarWidth(_ width: Double, save: Bool) {
        sidebarWidth = min(Self.sidebarWidths.upperBound, max(Self.sidebarWidths.lowerBound, width.rounded()))
        if save { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
    }

    /// Своё название раздела «Страницы» у открытого пространства; nil — стандартное.
    @Published private(set) var pagesTitle: String?
    /// Свои разделы боковой панели и раздел каждой страницы верхнего уровня (схема v9).
    @Published private(set) var sections: [PageSection] = []
    @Published private(set) var sectionOf: [UUID: UUID] = [:]
    /// Замки страниц (ADR-0017) и открытые в этом сеансе: сон экрана, выход и смена пространства закрывают снова.
    @Published var pageLocks: [UUID: PageLock] = [:]
    @Published var unlockedPages: Set<UUID> = []
    private static let pagesTitleKey = "ui.pagesSectionTitle"
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

    /// Страницы-базы: страница → база.
    @Published private(set) var databaseIndex: [UUID: UUID] = [:] {
        didSet { refreshPageIndex() }
    }
    /// Базы не в корзине. Считается заранее: дерево спрашивает об этом для каждой страницы.
    private var liveDatabases: Set<UUID> = []
    /// Производные от `pages`: интерфейс читает их при каждой перерисовке, поэтому они считаются один раз на изменение.
    private(set) var pageTree = PageTree()
    private(set) var favorites: [Page] = []
    private(set) var recent: [Page] = []
    /// Страница, для которой открыт выбор нового места.
    @Published var pageToMove: Page?
    /// Страница, для которой открыта история версий.
    @Published var historyPage: Page?
    /// Видео, открытое в проигрывателе.
    @Published var playingVideo: PlayingVideo?
    /// CSV, ожидающий предпросмотра.
    @Published var csvImport: CSVImportRequest?
    @Published private(set) var databaseModel: DatabaseModel?
    @Published private(set) var userTemplates: [PageTemplate] = []
    /// Справочник людей пространства (M10): варианты свойства «Человек».
    @Published private(set) var people: [Person] = []
    /// Предпросмотр на блок: данные блока рядом, изменившийся блок читается заново.
    private var embedCache: [UUID: (json: String, summary: EmbedSummary)] = [:]
    private var embedLoading: Set<String> = []

    private var session: WorkspaceSession?
    private(set) var store: SQLiteWorkspace?
    /// Синхронизация с Календарём и Напоминаниями открытого пространства.
    @Published private(set) var calendarSync: CalendarSyncHost?
    private var navigation: Task<Void, Never>?
    private let lastWorkspaceKey = "lastWorkspacePath"
    private let lastPageKey = "lastPageID"
    private let knownWorkspacesKey = "knownWorkspaces"
    private var imageCache: [UUID: NSImage] = [:]

    var isOpen: Bool { session != nil }
    var workspaceRoot: URL? { store?.layout.root }

    /// Новые копии получают новое расширение; старые архивы читаются и показываются как прежде.
    private static let backupExtension = "mindnotesbackup"
    /// Архивы прежних имён того же формата (ADR-0003) открываются и попадают в список копий.
    private static let backupExtensions = [backupExtension, "minervabackup", "grizzlybackup"]

    struct BackupItem: Identifiable, Equatable {
        var url: URL
        var date: Date
        var size: Int64
        var automatic = false
        var id: URL { url }
    }

    /// Автоматические копии: включены по умолчанию; папку можно перенести на другой диск.
    @Published var autoBackupEnabled = UserDefaults.standard.object(forKey: "autoBackupEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: "autoBackupEnabled") }
    }
    @Published private(set) var autoBackupFolder: URL? = UserDefaults.standard.string(forKey: "autoBackupFolder").map { URL(fileURLWithPath: $0) }
    private var autoBackupTask: Task<Void, Never>?
    private var autoBackupTimer: Timer?
    static let autoPrefix = "auto-"

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
        if case .success(let image) = await readImage(url) { return image }
        return nil
    }

    /// Чтение выбранной картинки с причиной отказа. Файл из iCloud сначала докачивается (координатор файлов,
    /// как в Finder); если сжатая копия не строится, картинка открывается напрямую.
    enum ImageReadError: Error { case noAccess, notDownloaded, unsupported }

    static func readImage(_ url: URL) async -> Result<NSImage, ImageReadError> {
        await Task.detached(priority: .userInitiated) { () -> Result<NSImage, ImageReadError> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var data: Data?
            var failure: Error?
            var coordinationError: NSError?
            // Для файла iCloud координатор ждёт, пока файл скачается на этот Mac.
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                do { data = try Data(contentsOf: readable, options: .mappedIfSafe) } catch { failure = error }
            }
            if data == nil { do { data = try Data(contentsOf: url) } catch { failure = failure ?? error } }
            guard let data else {
                let code = ((failure ?? coordinationError) as NSError?)?.code
                if code == NSFileReadNoPermissionError || code == Int(EPERM) || code == Int(EACCES) { return .failure(.noAccess) }
                let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if let status = values?.ubiquitousItemDownloadingStatus, status != .current { return .failure(.notDownloaded) }
                return .failure(.noAccess)
            }
            if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 2400]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return .success(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                }
            }
            // Запасной путь: то, что умеет открыть сама система (в том числе векторные PDF и SVG).
            if let image = NSImage(data: data), image.isValid { return .success(image) }
            return .failure(.unsupported)
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
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = L("Выбрать")
        guard panel.runModal() == .OK, let url = panel.url, let owner = store else { return done(nil) }
                let size = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 64 * 1024 * 1024 else {
            errorMessage = L("Изображение слишком большое: до 64 МБ.")
            return done(nil)
        }
        Task { @MainActor in
            let image: NSImage
            switch await Self.readImage(url) {
            case .success(let read): image = read
            case .failure(.noAccess):
                self.errorMessage = L("Нет доступа к файлу. Разрешите MindNotes доступ к этой папке: «Системные настройки» → «Конфиденциальность и безопасность» → «Файлы и папки» — или перенесите картинку, например, в «Загрузки».")
                return done(nil)
            case .failure(.notDownloaded):
                self.errorMessage = L("Файл лежит в iCloud и ещё не скачан на этот Mac. Откройте его в Finder (значок облака), дождитесь загрузки и выберите снова.")
                return done(nil)
            case .failure(.unsupported):
                self.errorMessage = L("Формат картинки не распознан. Подойдут JPEG, PNG, HEIC, GIF, WebP, TIFF, BMP.")
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
        panel.message = L("Выберите папку пространства MindNotes.")
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
                                         destination: root.appendingPathComponent("\(dir.lastPathComponent)-\(stamp).\(Self.backupExtension)"),
                                         appVersion: options.appVersion, now: options.clock.nowMillis())
            }
            let opts = options
            let store = try await Task.detached(priority: .userInitiated) { try SQLiteWorkspace.open(at: url, options: opts) }.value
            try await self.adopt(store)
        }
    }

    /// Сначала готовит новое пространство целиком, и только затем закрывает прежнее:
    /// сбой открытия оставляет пользователя в том пространстве, где он работал.
    /// Формулы с today() пересчитываются при смене даты, пока пространство открыто.
    private var dailyFormulas: Timer?

    private func adopt(_ store: SQLiteWorkspace) async throws {
        do {
            // Значения формул с today() должны быть свежими до первого показа.
            _ = try? await store.refreshDailyFormulas()
            let name = try await store.workspaceName()
            let loadedLook = try await store.look()
            let loadedPagesTitle = try await store.meta(Self.pagesTitleKey).flatMap { $0.isEmpty ? nil : $0 }
            let loadedSections = try await store.sections()
            let loadedMembers = try await store.sectionMembers()
            let loadedCollapsed = Set((try await store.meta(Self.collapsedSectionsKey) ?? "").split(separator: ",").map(String.init))
            let loadedPagesIndex = Int(try await store.meta(Self.pagesIndexKey) ?? "") ?? 0
            let loadedLocks = PageLock.decode(try await store.meta(PageLock.metaKey))
            let session = WorkspaceSession(store: store, name: name)
            session.coordinator.onStatusChange = { [weak self] in self?.saveStatus = $0 }
            try await session.refreshPages()
            let loadedTags = try await store.tags()
            let loadedPageTags = try await store.pageTags()
            let loadedDatabases = try await store.databaseIndex()
            try await closeSession()
            self.store = store
            // Синхронизация с Календарём и Напоминаниями: связки баз и связи записей у каждого пространства свои.
            self.calendarSync = CalendarSyncHost(source: store, workspaceID: try await store.workspaceID(),
                                                 supportDir: self.supportDirectory, gateway: EventKitGateway())
            Task { [weak self] in await self?.calendarSync?.engine.syncNow() }
            AIWorkspace.shared.attach(store)
            AIPropertyFiller.shared.resume(store: store, shell: self)
            dailyFormulas?.invalidate()
            dailyFormulas = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self, weak store] _ in
                Task { @MainActor in
                    guard let store, self?.store === store, (try? await store.refreshDailyFormulas()) == true else { return }
                    self?.databaseModel?.reload()
                }
            }
            backStack = [] // История относится к прежнему пространству.
            forwardStack = []
            self.session = session
            workspaceName = name
            imageCache = [:]
            look = loadedLook
            pagesTitle = loadedPagesTitle
            sections = loadedSections
            sectionOf = loadedMembers
            collapsedSections = loadedCollapsed
            pagesSectionIndex = loadedPagesIndex
            pageLocks = loadedLocks
            unlockedPages = []
            tags = loadedTags
            pageTags = loadedPageTags
            databaseIndex = loadedDatabases
            userTemplates = (try? await store.templates()) ?? []
            people = (try? await store.people()) ?? []
            pages = session.pages
            saveStatus = .saved
            await cacheImages(for: loadedLook)
            rememberWorkspace(path: store.layout.root.path, name: name)
            if section != .files { section = .home }
            UserDefaults.standard.set(store.layout.root.path, forKey: lastWorkspaceKey)
            try await reloadBackups()
            startAutoBackups()
            // После перезапуска пользователь возвращается к той же странице.
            if section != .files, let raw = UserDefaults.standard.string(forKey: lastPageKey), let id = UUID(uuidString: raw), pages.contains(where: { $0.id == id }) {
                try await show(id)
            }
        } catch {
            if self.store !== store { store.close() } // Блокировка нового пространства не должна остаться.
            throw error
        }
    }

    // MARK: Разделы боковой панели

    /// Строки дерева раздела: страницы верхнего уровня этого раздела (nil — стандартного) с потомками.
    func treeRows(collapsed: Set<UUID>, section: UUID?) -> [PageTree.Row] {
        let known = Set(sections.map(\.id))
        var out: [PageTree.Row] = []
        var include = false
        for row in pageTree.rows(collapsed: collapsed) {
            if row.depth == 0 {
                let own = sectionOf[row.page.id].flatMap { known.contains($0) ? $0 : nil }
                include = own == section
            }
            if include { out.append(row) }
        }
        return out
    }

    private func reloadSections() async throws {
        guard let store else { return }
        sections = try await store.sections()
        sectionOf = try await store.sectionMembers()
    }

    func addSection() {
        guard let name = PromptAlert.ask(L("Название раздела"), value: ""), let clean = PageSection.clean(name) else { return }
        enqueue {
            try await self.store?.addSection(name: clean, id: UUID(), now: SystemClock().nowMillis())
            try await self.reloadSections()
        }
    }

    func renameSection(_ section: PageSection) {
        guard let name = PromptAlert.ask(L("Название раздела"), value: section.name), let clean = PageSection.clean(name) else { return }
        enqueue {
            try await self.store?.renameSection(section.id, to: clean)
            try await self.reloadSections()
        }
    }

    /// Удаление раздела страниц не удаляет: они возвращаются в стандартный раздел.
    func deleteSection(_ section: PageSection) {
        let alert = NSAlert()
        alert.messageText = String(format: L("Удалить раздел «%@»?"), section.name)
        alert.informativeText = String(format: L("Страницы раздела не удаляются: они перейдут в «%@»."), pagesTitle ?? L("Страницы"))
        alert.addButton(withTitle: L("Удалить раздел"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        enqueue {
            try await self.store?.deleteSection(section.id)
            try await self.reloadSections()
        }
    }

    /// Позиция «Страниц» среди разделов: хранится в пространстве, как и порядок своих разделов.
    @Published private(set) var pagesSectionIndex = 0
    private static let pagesIndexKey = "ui.pagesSectionIndex"

    var sectionOrder: [SectionSlot] { SectionSlot.order(sections, pagesIndex: pagesSectionIndex) }

    func moveSection(_ slot: SectionSlot, by delta: Int) {
        let order = sectionOrder
        guard let i = order.firstIndex(of: slot), order.indices.contains(i + delta) else { return }
        moveSection(slot, onto: order[i + delta])
    }

    /// Раздел перетащили на место другого: новый порядок своих разделов и позиция «Страниц».
    func moveSection(_ moving: SectionSlot, onto target: SectionSlot) {
        let order = SectionSlot.move(sectionOrder, moving, onto: target)
        guard order != sectionOrder else { return }
        let pagesIndex = order.firstIndex(of: .pages) ?? 0
        pagesSectionIndex = pagesIndex
        enqueue {
            if case .custom(let id) = moving {
                try await self.store?.moveSection(id, after: SectionSlot.customPredecessor(of: id, in: order))
                try await self.reloadSections()
            }
            try await self.store?.setMeta(Self.pagesIndexKey, String(pagesIndex))
        }
    }

    /// Свёрнутые разделы пространства: «default» — стандартный, иначе ID раздела. Хранятся в пространстве.
    @Published private(set) var collapsedSections: Set<String> = []
    private static let collapsedSectionsKey = "ui.collapsedSections"

    func isSectionCollapsed(_ section: UUID?) -> Bool { collapsedSections.contains(section?.uuidString ?? "default") }

    func toggleSection(_ section: UUID?) {
        let key = section?.uuidString ?? "default"
        if collapsedSections.remove(key) == nil { collapsedSections.insert(key) }
        let value = collapsedSections.sorted().joined(separator: ",")
        enqueue { try await self.store?.setMeta(Self.collapsedSectionsKey, value) }
    }

    /// Страницу бросили на заголовок раздела: она становится страницей верхнего уровня этого раздела.
    func dropPage(_ id: UUID, onSection section: UUID?) {
        guard allowsMove(id, toParent: nil) else { return }
        let isRoot = pages.first { $0.id == id }?.parentID == nil
        act {
            guard let session = self.session else { return }
            if !isRoot {
                try await session.move(id, toParent: nil, afterSibling: nil)
                self.pages = session.pages
            }
            try await self.store?.setSection(page: id, section: section)
            try await self.reloadSections()
        }
        if isSectionCollapsed(section) { toggleSection(section) }
    }

    /// Страницу поставили рядом со страницей верхнего уровня другого раздела: она переходит в тот же раздел.
    func followSection(of target: UUID, page: UUID) {
        guard pages.first(where: { $0.id == target })?.parentID == nil else { return }
        let known = Set(sections.map(\.id))
        let section = sectionOf[target].flatMap { known.contains($0) ? $0 : nil }
        guard sectionOf[page] != section else { return }
        moveToSection(page, section)
    }

    func moveToSection(_ page: UUID, _ section: UUID?) {
        enqueue {
            try await self.store?.setSection(page: page, section: section)
            try await self.reloadSections()
        }
    }

    func createPage(inSection section: UUID) {
        enqueue {
            guard let session = self.session, let store = self.store else { return }
            let page = try await session.createPage(parent: nil, title: L("Без названия"))
            try await store.setSection(page: page.id, section: section)
            try await self.reloadSections()
            self.pages = session.pages
            try await self.show(page.id)
        }
    }

    func renamePagesSection() {
        guard let name = PromptAlert.ask(L("Название раздела страниц"), value: pagesTitle ?? L("Страницы")) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        setPagesTitle(clean.isEmpty || clean == L("Страницы") ? nil : String(clean.prefix(60)))
    }

    /// Название пишется в само пространство: переходит с ним в резервную копию и на другой Mac.
    func setPagesTitle(_ title: String?) {
        pagesTitle = title
        enqueue {
            try await self.store?.setMeta(Self.pagesTitleKey, title ?? "")
        }
    }

    func closeWorkspace() {
        enqueue {
            try await self.closeSession()
            self.pagesTitle = nil
            self.sections = []
            self.sectionOf = [:]
            self.collapsedSections = []
            self.pagesSectionIndex = 0
            self.pageLocks = [:]
            self.unlockedPages = []
            UserDefaults.standard.removeObject(forKey: self.lastWorkspaceKey)
            self.backStack = []
            self.forwardStack = []
            self.section = .welcome
        }
    }

    private func closeSession() async throws {
        // Копия читает базу: сначала дождаться её, потом закрывать.
        autoBackupTimer?.invalidate()
        autoBackupTimer = nil
        await autoBackupTask?.value
        // Peek записывается первым: его правки идут той же очередью сохранения.
        try await closePeekNow()
        // Модель редактора живёт до подтверждённой записи: при отказе нужен аварийный экспорт.
        if let session { try await session.close() }
        editor = nil
        session = nil
        store = nil
        calendarSync = nil
        // Чат и панель ИИ относятся к закрытому пространству.
        AIAssist.shared.close()
        AIChatModel.shared.reset()
        AIWorkspace.shared.detach()
        AIPropertyFiller.shared.detach()
        pages = []
        workspaceName = ""
        look = WorkspaceLook()
        tags = []
        pageTags = [:]
        databaseIndex = [:]
        databaseModel = nil
        userTemplates = []
        embedCache = [:]
    }

    // MARK: Базы данных

    func isDatabase(_ id: UUID) -> Bool { databaseIndex[id] != nil }

    private func refreshPageIndex() {
        let live = Set(pages.map(\.id))
        let databases = Set(databaseIndex.filter { live.contains($0.key) }.values)
        liveDatabases = databases
        pageTree = PageTree(pages: pages) { $0.databaseID.map(databases.contains) ?? false }
        favorites = pages.filter { $0.favoriteKey != nil }.sorted { ($0.favoriteKey ?? "") < ($1.favoriteKey ?? "") }
        recent = pages.filter { $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? 0) > ($1.lastOpenedAt ?? 0) }.prefix(5).map { $0 }
    }

    /// Открыта ли эта страница или база.
    func isOpenPage(_ id: UUID) -> Bool { section == .page(id) || section == .database(id) }

    func createDatabase(parent: UUID? = nil) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            let template = NewDatabase(title: L("Новая база"), titleProperty: L("Название"), statusProperty: L("Статус"),
                                       statusOptions: [L("Запланировано"), L("В работе"), L("Готово")], dateProperty: L("Срок"), viewName: L("Таблица"),
                                       extraViews: [(L("Доска"), DatabaseView.boardKind), (L("Список"), DatabaseView.listKind),
                                                    (L("Календарь"), DatabaseView.calendarKind), (L("Галерея"), DatabaseView.galleryKind),
                                                    (L("Хронология"), DatabaseView.timelineKind)])
            let database = try await store.createDatabase(parent: parent, template: template, ids: RandomIDs(), now: SystemClock().nowMillis())
            self.databaseIndex[database.pageID] = database.id
            try await session.refreshPages()
            self.pages = session.pages
            try await self.show(database.pageID)
        }
    }

    /// База открывается своим экраном: редактор создал бы в её странице пустой абзац.
    private func showDatabase(page: UUID, database: UUID) async throws {
        guard let session, let store else { return }
        try await session.closeEditor()
        editor = nil
        let coordinator = session.coordinator
        let model = DatabaseModel(store: store, databaseID: database, pageID: page, flush: { try await coordinator.flush() },
                                  pagesChanged: { [weak self] in
                                      guard let self, let session = self.session else { return }
                                      try await session.refreshPages()
                                      self.pages = session.pages
                                      try await self.reloadTrash()
                                  }, report: { [weak self] in self?.errorMessage = $0 })
        model.onChange = { [weak self] in self?.calendarSync?.recordsChanged() }
        databaseModel = model
        pages = session.pages
        section = .database(page)
        UserDefaults.standard.set(page.uuidString, forKey: lastPageKey)
    }

    // MARK: Встроенные представления

    /// Выбор базы для блока. Системное окно: блок вставляется только после подтверждения.
    func pickDatabaseFragment() -> BlockFragment? {
        let live = pages.filter { isDatabase($0.id) }
        guard !live.isEmpty else {
            notice = L("Сначала создайте базу данных.")
            return nil
        }
        let alert = NSAlert()
        alert.messageText = L("Какую базу показать?")
        alert.informativeText = L("Записи не копируются: на странице будет представление существующей базы со своими фильтрами.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: live.map { $0.title.isEmpty ? L("Без названия") : $0.title })
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Вставить"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn, live.indices.contains(popup.indexOfSelectedItem),
              let state = try? DatabaseViewState().jsonString() else { return nil }
        return AtomData.databaseView(page: live[popup.indexOfSelectedItem].id, kind: DatabaseView.tableKind, state: state)
    }

    /// Данные карточки в тексте: при первом запросе загружаются, затем редактор перерисовывается.
    func embedSummary(_ block: Block) -> EmbedSummary? {
        guard let json = try? block.contentJSON() else { return nil }
        if let cached = embedCache[block.id], cached.json == json { return cached.summary }
        let key = "\(block.id)|\(json)"
        guard !embedLoading.contains(key), let store else { return nil }
        guard let page = AtomData.viewPage(of: block), let database = databaseIndex[page], pages.contains(where: { $0.id == page }) else {
            return EmbedSummary(title: L("База недоступна: она удалена или в корзине."), lines: [], total: 0)
        }
        if isClosed(page) { return EmbedSummary(title: L("База защищена паролем: откройте её, чтобы увидеть записи."), lines: [], total: 0) }
        embedLoading.insert(key)
        let title = pages.first { $0.id == page }?.title ?? ""
        let state = DatabaseViewState(json: AtomData.viewState(of: block))
        Task { @MainActor in
            defer { self.embedLoading.remove(key) }
            guard let loaded = try? await store.database(database),
                  let records = try? await store.queryRecords(database: loaded, state: state, limit: DatabaseViewBlockCell.maxLines, offset: 0) else { return }
            let summary = EmbedSummary(title: "\(ViewKindTitle.title(AtomData.viewKind(of: block))) · \(title.isEmpty ? L("Без названия") : title)",
                                                lines: records.rows.map { $0.title.isEmpty ? L("Без названия") : $0.title }, total: records.total)
            self.embedCache[block.id] = (json, summary)
            self.editor?.controller.textView.needsDisplay = true
        }
        return nil
    }

    /// После правок в открытом представлении карточка должна показать новые данные.
    func refreshEmbeds() {
        embedCache = [:]
        editor?.controller.textView.needsDisplay = true
    }

    /// Модель полного вида для блока; состояние пишется обратно в блок обычной правкой страницы и попадает в отмену.
    func embeddedModel(for block: Block, editor: PageEditorModel) -> DatabaseModel? {
        guard let store, let session, let page = AtomData.viewPage(of: block), let database = databaseIndex[page], pages.contains(where: { $0.id == page }),
              !isClosed(page) else { return nil }
        let coordinator = session.coordinator
        var keep = block.atomJSON
        keep["kind"] = nil
        keep["state"] = nil
        keep["page"] = nil
        let embedded = DatabaseModel.EmbeddedView(id: block.id, name: "", kind: AtomData.viewKind(of: block), state: DatabaseViewState(json: AtomData.viewState(of: block))) { [weak editor, keep] kind, state in
            guard let json = try? state.jsonString() else { return }
            editor?.controller.updateEmbedded(block.id, json: AtomData.databaseViewJSON(page: page, kind: kind, state: json, keeping: keep))
        }
        return DatabaseModel(store: store, databaseID: database, pageID: page, embedded: embedded, flush: { try await coordinator.flush() },
                             pagesChanged: { [weak self] in
                                 guard let self, let session = self.session else { return }
                                 try await session.refreshPages()
                                 self.pages = session.pages
                                 try await self.reloadTrash()
                             }, report: { [weak self] in self?.errorMessage = $0 })
    }

    // MARK: Шаблоны

    func goTemplates() {
        leavePage { self.section = .templates }
    }

    /// Сохраняет страницу или запись. Шаблон — независимая копия: её дальнейшие правки не связаны с оригиналом.
    func saveAsTemplate(_ id: UUID) {
        guard allowsCopy(of: id) else { return }
        let current = pages.first { $0.id == id }?.title ?? ""
        guard let name = PromptAlert.ask(L("Название шаблона"), value: current) else { return }
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await session.coordinator.flush()
            _ = try await store.saveTemplate(from: id, name: name, ids: RandomIDs(), now: SystemClock().nowMillis())
            self.userTemplates = try await store.templates()
            self.notice = L("Шаблон сохранён.")
        }
    }

    func useTemplate(_ template: PageTemplate) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            let page = try await store.instantiate(template: template.id, parent: nil, ids: RandomIDs(), now: SystemClock().nowMillis())
            try await session.refreshPages()
            self.pages = session.pages
            try await self.reloadTags()
            try await self.reloadDatabases()
            try await self.show(page)
        }
    }

    /// Встроенный шаблон: обычная новая страница с начальным текстом.
    func useBuiltin(_ template: BuiltinTemplate) {
        enqueue {
            guard let session = self.session else { return }
            let page = try await session.createPage(parent: nil, title: template.title)
            self.pages = session.pages
            let opened = try await session.open(page.id)
            if let first = opened.document.blocks.first {
                try opened.perform(.replaceRange(BlockSelection(block: first.id, offset: 0), MarkdownImport.fragments(from: template.markdown)), recordUndo: false)
            }
            self.pages = session.pages
            self.installEditor(opened, id: page.id)
        }
    }

    /// Шаблон каталога: страницы и базы создаются в пространстве и сразу открываются.
    func useCatalog(_ template: CatalogTemplate) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            let page = try await store.install(template, today: LocalDate(date: Date(), in: .current), now: SystemClock().nowMillis())
            self.databaseIndex = try await store.databaseIndex()
            try await session.refreshPages()
            self.pages = session.pages
            try await self.show(page)
        }
    }

    func renameTemplate(_ template: PageTemplate) {
        guard let name = PromptAlert.ask(L("Название шаблона"), value: template.name) else { return }
        enqueue {
            guard let store = self.store else { return }
            try await store.renameTemplate(template.id, to: name)
            self.userTemplates = try await store.templates()
        }
    }

    func deleteTemplate(_ template: PageTemplate) {
        guard PromptAlert.confirm(L("Удалить шаблон «%@»?", template.name), detail: L("Созданные из него страницы останутся. Это действие нельзя отменить."), action: L("Удалить")) else { return }
        enqueue {
            guard let store = self.store else { return }
            try await store.deleteTemplate(template.id)
            self.userTemplates = try await store.templates()
        }
    }

    func loadImage(asset: UUID) {
        guard imageCache[asset] == nil, let store else { return }
        Task {
            if let url = try? await store.assetURL(asset) {
                self.imageCache[asset] = await Self.loadImage(url)
                self.objectWillChange.send()
            }
        }
    }

    private func reloadDatabases() async throws {
        guard let store else { return }
        databaseIndex = try await store.databaseIndex()
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
    func enqueue(_ body: @escaping @MainActor () async throws -> Void) {
        let previous = navigation
        navigation = Task { @MainActor in
            await previous?.value
            do { try await body() }
            catch { self.errorMessage = Self.describe(error) }
        }
    }

    private func show(_ id: UUID) async throws {
        guard let session else { return }
        // Страница открывается целиком: Peek закрывается, чтобы два редактора не правили одно и то же.
        if peek != nil { try await closePeekNow() }
        if isClosed(id) { return try await showLocked(id) }
        if let database = databaseIndex[id] { return try await showDatabase(page: id, database: database) }
        let editorSession = try await session.open(id)
        pages = session.pages
        installEditor(editorSession, id: id)
    }

    /// Настройка редактора страницы: основного и Peek (ссылки, вложения, упоминания, превью, представления).
    private func configure(_ model: PageEditorModel, page id: UUID) {
        let c = model.controller
        c.pageSearch = { [weak self] in self?.linkCandidates($0) ?? [] }
        c.peopleSource = { [weak self] in self?.people ?? [] }
        c.fetchLinkPreview = { [weak self] url in await self?.linkPreview(url) }
        c.onOpenURL = { url, type in
            if type == .embed { LinkPreviewFetcher.openEmbed(url, title: LinkCard.embed(url).provider) } else { NSWorkspace.shared.open(url) }
        }
        c.pageTitle = { [weak self] in self?.pages.first { $0.id == id }?.title ?? "" }
        c.scheduleReminder = { [weak self] when, text in
            MentionReminders.schedule(when, text: text) { self?.errorMessage = $0 }
        }
        c.pickDatabaseView = { [weak self] in self?.pickDatabaseFragment() }
        // ИИ (ADR-0016): только при включённом ИИ, согласии и ключе; иначе пробел и ⌘J работают как раньше.
        c.aiAvailable = { AISettings.isEnabled && AISettings.shared.hasKey }
        // Автообновление ИИ-свойств записи после правки её страницы (FR-AI-8); без ИИ — сразу выход.
        c.session.observe(AIPropertyFiller.shared) { [weak self] in
            guard AISettings.isEnabled, let self else { return }
            AIPropertyFiller.shared.recordEdited(id, shell: self)
        }
        c.onAIRequest = { [weak self] editor, range in
            AIAssist.shared.shell = self
            AIAssist.shared.present(controller: editor, range: range)
        }
        c.embedSummary = { [weak self] in self?.embedSummary($0) }
        // Живое представление базы прямо в тексте (M13): тот же экран, что и «Открыть целиком».
        c.liveView = { [weak self, weak model] block in
            guard let self, let model, let embedded = self.embeddedModel(for: block, editor: model) else { return nil }
            return NSHostingView(rootView: DatabaseScreen(model: embedded, compact: true).environment(\.databaseInset, 14).environmentObject(self))
        }
        c.onOpenLink = { [weak self] page, block in self?.followLink(to: page, block: block) }
        c.onPeekLink = { [weak self] page in self?.peekPage(page) }
        c.requestComment = { [weak self] block, anchor, thread in
            guard let self, let body = PromptAlert.ask(L("Комментарий"), value: "") else { return false }
            return await self.addComment(page: id, block: block, anchor: anchor, body: body, newID: thread)
        }
        c.onOpenComment = { [weak self] thread in
            self?.focusedThread = thread
            self?.showsComments = true
        }
        c.onPlayVideo = { [weak self] url, name in self?.playingVideo = PlayingVideo(url: url, name: name) }
        c.addAttachment = { [weak self] url in
            guard let store = self?.store else { throw WorkspaceError.storage(code: 0, detail: "пространство закрыто") }
                        let size = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        // Видео бывает большим; предел защищает от случайного копирования образа диска.
                        guard size <= 4 << 30 else { throw CocoaError(.fileReadTooLarge) }
            return try await store.addAsset(copying: url, now: SystemClock().nowMillis())
        }
        c.assetURL = { [weak self] id in self?.assetFileURL(id) }
        c.pickFile = { type in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            if type == .image { panel.allowedContentTypes = [.image] }
            if type == .video { panel.allowedContentTypes = [.movie] }
            panel.prompt = L("Выбрать")
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    private func installEditor(_ editorSession: EditorSession, id: UUID) {
        let style = Tokens.editorStyle()
        editor = PageEditorModel(session: editorSession, style: style) { [weak self] in self?.errorMessage = $0 }
        embedCache = [:]
        if let editor { configure(editor, page: id) }
        editor?.controller.renderAll()
        backlinks = []
        comments = []
        showsComments = false
        loadComments(id)
        section = .page(id)
        UserDefaults.standard.set(id.uuidString, forKey: lastPageKey)
    }

    func goHome() {
        UserDefaults.standard.removeObject(forKey: lastPageKey)
        leavePage { self.section = self.isOpen ? .home : .welcome }
    }

    // MARK: История переходов

    func goBack() {
        enqueue {
            guard let target = self.backStack.last else { return }
            let current = self.section
            var back = self.backStack
            back.removeLast()
            let forward = self.forwardStack + [current]
            try await self.transition(to: target)
            // Стеки меняются только после удачного перехода.
            self.backStack = back
            self.forwardStack = forward
        }
    }

    func goForward() {
        enqueue {
            guard let target = self.forwardStack.last else { return }
            let current = self.section
            var forward = self.forwardStack
            forward.removeLast()
            let back = self.backStack + [current]
            try await self.transition(to: target)
            self.backStack = back
            self.forwardStack = forward
        }
    }

    private func transition(to target: ShellSection) async throws {
        // Страница могла уйти в корзину: на неё не переходим.
        // Страница или база могла уйти в корзину: туда не переходим.
        var opened: UUID?
        if case .page(let id) = target { opened = id }
        if case .database(let id) = target { opened = id }
        if case .locked(let id) = target { opened = id } // Замок могли открыть: show решит заново.
        if let opened, pages.contains(where: { $0.id == opened }) {
            try await show(opened)
            return
        }
        try await session?.closeEditor()
        editor = nil
        if opened != nil { section = .home } else { section = target }
    }

    // MARK: Поиск и ссылки

    func search(_ query: String) async -> [SearchHit] {
        // Текст страниц под закрытым замком не показывается: только заголовок.
        ((try? await store?.search(query)) ?? []).map { hit in
            guard isClosed(hit.pageID) else { return hit }
            var hidden = hit
            hidden.snippet = L("Защищено паролем")
            hidden.blockID = nil
            return hidden
        }
    }

    /// Страницы для ссылки «[[»: по заголовку, без текущей корзины.
    /// Превью закладки (ADR-0011): только при включённом выключателе; картинка сохраняется вложением пространства.
    func linkPreview(_ url: URL) async -> (title: String?, description: String?, asset: UUID?)? {
        guard LinkPreviewFetcher.isEnabled, let store else { return nil }
        do {
            let result = try await LinkPreviewFetcher.fetch(url)
            var asset: UUID?
            if let image = result.image {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).\(image.ext)")
                defer { try? FileManager.default.removeItem(at: temp) }
                try image.data.write(to: temp)
                asset = try await store.addAsset(copying: temp, now: SystemClock().nowMillis()).id
            }
            return (result.preview.title, result.preview.description, asset)
        } catch {
            errorMessage = L("Превью ссылки не загрузилось: страница недоступна или слишком большая.")
            return nil
        }
    }

    func linkCandidates(_ query: String) -> [(id: UUID, title: String)] {
        let key = SearchText.normalize(query.trimmingCharacters(in: .whitespaces))
        let list = pages.filter { key.isEmpty || SearchText.normalize($0.title).contains(key) }
        return Array(list.prefix(12)).map { ($0.id, $0.title) }
    }

    func reloadBacklinks(for page: UUID) {
        enqueue {
            guard let session = self.session, let store = self.store else { return }
            try await session.coordinator.flush() // Ссылки считаются по записанному тексту.
            self.backlinks = try await store.backlinks(to: page).map { link in
                guard self.isClosed(link.pageID) else { return link }
                var hidden = link
                hidden.text = L("Защищено паролем")
                return hidden
            }
        }
    }

    /// Переход по ссылке. Страница в корзине не подменяется другой (FR-04).
    // MARK: Комментарии (M14)

    /// Комментарии открытой страницы, автор новых комментариев и ветка, к которой перешли щелчком по тексту.
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var commentAuthor: UUID?
    @Published var showsComments = false
    @Published var focusedThread: UUID?
    private static let commentAuthorKey = "comments.author"

    var commentThreads: [CommentThread] { CommentThread.group(comments) }

    func loadComments(_ page: UUID) {
        enqueue {
            guard let store = self.store else { return }
            if self.commentAuthor == nil, let raw = try await store.meta(Self.commentAuthorKey) { self.commentAuthor = UUID(uuidString: raw) }
            self.comments = try await store.comments(page: page)
            self.highlightComments()
        }
    }

    /// Подсветка в тексте — только у открытых веток.
    private func highlightComments() {
        let open = Set(commentThreads.filter { !$0.root.resolved }.map(\.id))
        editor?.controller.setActiveComments(open)
    }

    func setCommentAuthor(_ id: UUID?) {
        commentAuthor = id
        enqueue { try await self.store?.setMeta(Self.commentAuthorKey, id?.uuidString ?? "") }
    }

    /// Новая ветка: к странице (`block == nil`) или к выделенному тексту (ID ветки задаёт редактор).
    func addComment(page: UUID, block: UUID?, anchor: String, body: String, thread: UUID? = nil, newID: UUID = UUID()) async -> Bool {
        guard let store, Comment.clean(body) != nil else { return false }
        do {
            try await store.addComment(page: page, block: block, thread: thread, author: commentAuthor, body: body, anchor: anchor, id: newID, now: SystemClock().nowMillis())
            comments = try await store.comments(page: page)
            highlightComments()
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    func reply(to thread: UUID, page: UUID, body: String) {
        Task { _ = await addComment(page: page, block: nil, anchor: "", body: body, thread: thread) }
    }

    func resolveThread(_ thread: UUID, _ resolved: Bool, page: UUID) {
        enqueue {
            try await self.store?.resolveThread(thread, resolved: resolved, now: SystemClock().nowMillis())
            self.comments = try await self.store?.comments(page: page) ?? []
            self.highlightComments()
        }
    }

    func deleteComment(_ id: UUID, page: UUID) {
        enqueue {
            try await self.store?.deleteComment(id)
            self.comments = try await self.store?.comments(page: page) ?? []
            self.highlightComments()
        }
    }

    // MARK: Peek (M14)

    enum PeekMode: String, CaseIterable { case side, center, page }

    /// Страница, открытая сбоку или по центру поверх текущей, и как она показана.
    @Published private(set) var peek: PageEditorModel?
    @Published private(set) var peekMode: PeekMode = .side
    private var peekModes: [UUID: PeekMode] = [:]

    /// Как открывать записи базы: сбоку, по центру или страницей. Хранится в пространстве; по умолчанию — сбоку, как в Notion.
    func peekMode(for database: UUID) -> PeekMode { peekModes[database] ?? .side }

    func loadPeekMode(for database: UUID) {
        guard peekModes[database] == nil else { return }
        enqueue {
            let raw = try await self.store?.meta("peek." + database.uuidString)
            self.peekModes[database] = raw.flatMap(PeekMode.init(rawValue:)) ?? .side
        }
    }

    func setPeekMode(_ mode: PeekMode, for database: UUID) {
        peekModes[database] = mode
        objectWillChange.send()
        enqueue { try await self.store?.setMeta("peek." + database.uuidString, mode.rawValue) }
    }

    func openRecord(_ id: UUID, database: UUID) {
        let mode = peekMode(for: database)
        if mode == .page { openPage(id) } else { peekPage(id, mode: mode) }
    }

    /// Вторая страница поверх текущей: своя сессия редактора на том же сохранении, текущая не закрывается.
    func peekPage(_ id: UUID, mode: PeekMode = .side) {
        enqueue {
            guard let session = self.session, let store = self.store else { return }
            if self.editor?.pageID == id { return } // Та же страница уже открыта целиком.
            if self.isClosed(id) { return try await self.show(id) } // Под паролем — окно ввода, а не Peek.
            try await self.closePeekNow()
            try await session.coordinator.flush()
            let opened = try await EditorSession.open(pageID: id, store: store, coordinator: session.coordinator, clock: SystemClock(), ids: RandomIDs())
            if opened.document.blocks.isEmpty { try opened.perform(.insertBlock(after: nil, type: .paragraph), recordUndo: false, quiet: true) }
            let style = Tokens.editorStyle()
            let model = PageEditorModel(session: opened, style: style) { [weak self] in self?.errorMessage = $0 }
            self.configure(model, page: id)
            model.controller.renderAll()
            withAnimation(.easeOut(duration: 0.15)) {
                self.peekMode = mode == .page ? .side : mode
                self.peek = model
            }
        }
    }

    func closePeek() { enqueue { try await self.closePeekNow() } }

    func closePeekForLock() async throws { try await closePeekNow() }

    /// Закрытая паролем страница (ADR-0017): редактор и база закрываются, на экране — окно ввода.
    func showLocked(_ id: UUID) async throws {
        try await session?.closeEditor()
        editor = nil
        databaseModel = nil
        backlinks = []
        comments = []
        showsComments = false
        section = .locked(id)
    }

    private func closePeekNow() async throws {
        guard let model = peek else { return }
        model.closePanels()
        withAnimation(.easeIn(duration: 0.15)) { peek = nil }
        try await model.closeSession()
        try await session?.refreshPages()
        if let session { pages = session.pages }
    }

    /// «Открыть как страницу»: Peek закрывается, страница открывается целиком.
    func openPeekAsPage() {
        guard let id = peek?.pageID else { return }
        enqueue {
            try await self.closePeekNow()
            try await self.show(id)
        }
    }

    func followLink(to id: UUID, block: UUID? = nil) {
        if pages.contains(where: { $0.id == id }) {
            openPage(id, block: block)
        } else {
            notice = L("Страница, на которую ведёт ссылка, в корзине или удалена.")
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

    /// Путь файла вложения. Имя составлено при добавлении и проверено на границы пространства.
    func assetFileURL(_ id: UUID) -> URL? {
        guard let store else { return nil }
        return try? store.assetFileURLSync(id)
    }

    /// Обложка страницы: файл хранится в пространстве и входит в архив.
    func setPageCover(_ id: UUID, asset: UUID?) {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await store.setPageCover(id, asset: asset)
            try await session.refreshPages()
            self.pages = session.pages
            if let asset, self.imageCache[asset] == nil, let url = try await store.assetURL(asset) {
                self.imageCache[asset] = await Self.loadImage(url)
                self.objectWillChange.send()
            }
        }
    }

    func pickPageCover(_ id: UUID) {
        pickImage { [weak self] asset in
            if let asset { self?.setPageCover(id, asset: asset) }
        }
    }

    /// Обложки страниц, ещё не загруженные в память.
    func loadCover(for page: Page) {
        guard let asset = page.coverAssetID, imageCache[asset] == nil, let store else { return }
        Task {
            if let url = try? await store.assetURL(asset) {
                self.imageCache[asset] = await Self.loadImage(url)
                self.objectWillChange.send()
            }
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
        guard allowsCopy(of: id) else { return }
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await session.coordinator.flush()
            let title = self.pages.first { $0.id == id }?.title ?? ""
            let copy = try await store.duplicatePage(id, title: String(format: L("%@ (копия)"), title), ids: RandomIDs(), now: SystemClock().nowMillis())
            try await session.refreshPages()
            self.pages = session.pages
            try await self.reloadTags()
            try await self.reloadDatabases()
            try await self.show(copy)
        }
    }

    func goSettings() {
        leavePage { self.section = .settings }
    }

    func goCalendar() {
        leavePage { self.section = .calendar }
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
            if case .database(let open) = self.section, !self.pages.contains(where: { $0.id == open }) {
                self.databaseModel = nil
                UserDefaults.standard.removeObject(forKey: self.lastPageKey)
                self.section = .home
            }
            self.databaseModel?.reload()
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

    // MARK: Файлы и медиа

    /// Выбор файлов для свойства «Файлы и медиа»: каждый копируется в хранилище вложений пространства.
    func pickRecordFiles(_ done: @escaping ([AttachedFile]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Добавить")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        enqueue {
            guard let store = self.store else { return }
            var added: [AttachedFile] = []
            for url in urls {
                let size = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 4 << 30 else { throw CocoaError(.fileReadTooLarge) }
                let record = try await store.addAsset(copying: url, now: SystemClock().nowMillis())
                added.append(AttachedFile(id: record.id, name: record.originalName))
            }
            done(added)
        }
    }

    /// Файл открывается программой по умолчанию; оригинал в хранилище не меняется, если программа его не перезапишет.
    func openRecordFile(_ file: AttachedFile) {
        guard let url = assetFileURL(file.id) else { errorMessage = L("Файл недоступен."); return }
        NSWorkspace.shared.open(url)
    }

    func revealRecordFile(_ file: AttachedFile) {
        guard let url = assetFileURL(file.id) else { errorMessage = L("Файл недоступен."); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Люди

    private func reloadPeople() async throws {
        guard let store else { return }
        people = try await store.people()
        databaseModel?.reload()
    }

    func addPerson(name: String) {
        enqueue {
            guard let store = self.store else { return }
            _ = try await store.addPerson(name: name, color: nil, emoji: nil, id: UUID(), now: SystemClock().nowMillis())
            try await self.reloadPeople()
        }
    }

    func updatePerson(_ person: Person) {
        enqueue {
            try await self.store?.updatePerson(person, now: SystemClock().nowMillis())
            try await self.reloadPeople()
            self.editor?.controller.relabel(.relabelPerson(self.people.first { $0.id == person.id } ?? person))
        }
    }

    /// Удаление снимает человека из всех записей: подтверждение называет их число.
    func deletePerson(_ person: Person) {
        enqueue {
            guard let store = self.store else { return }
            let used = try await store.personUsage(person.id)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(format: L("Удалить «%@» из справочника?"), person.name)
            alert.informativeText = used > 0
                ? String(format: L("Человек будет убран из записей: %d. Это действие нельзя отменить."), used)
                : L("Это действие нельзя отменить.")
            alert.addButton(withTitle: L("Удалить"))
            alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try await store.deletePerson(person.id, now: SystemClock().nowMillis())
            try await self.reloadPeople()
        }
    }

    /// Очистка корзины целиком: одно подтверждение с числом страниц, затем каждая группа удаляется навсегда.
    func emptyTrash() {
        let items = trashItems
        guard !items.isEmpty else { return }
        let total = items.reduce(0) { $0 + 1 + $1.descendants }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Очистить корзину?")
        alert.informativeText = String(format: L("Будет удалено навсегда страниц: %d. Это действие нельзя отменить."), total)
        alert.addButton(withTitle: L("Удалить все навсегда"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        enqueue {
            for batch in Set(items.map(\.batchID)) { try await self.session?.store.purgeTrash(batch: batch) }
            try await self.reloadTrash()
            try await self.reloadDatabases()
            if let session = self.session {
                try await session.refreshPages()
                self.pages = session.pages
                if let store = self.store { self.userTemplates = try await store.templates() }
            }
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
            try await self.reloadDatabases()
            if let session = self.session {
                try await session.refreshPages() // Запись могла потерять базу и стать обычной страницей.
                self.pages = session.pages
                if let store = self.store { self.userTemplates = try await store.templates() }
            }
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
        let old = session.pages.first { $0.id == id }?.title
        session.rename(id, title: title)
        editor?.controller.relabel(.relabelPage(id, old: old, new: title))
        pages = session.pages
    }

    /// Перетаскивание в боковой панели: перед строкой, внутрь неё или после. В базу страницу положить нельзя.
    @discardableResult
    func reorder(_ id: UUID, onto target: UUID, zone: PageTree.DropZone) -> Bool {
        if zone == .into, isDatabase(target) { return false }
        guard let place = pageTree.placement(moving: id, onto: target, zone: zone), allowsMove(id, toParent: place.parent) else { return false }
        act {
            guard let session = self.session else { return }
            try await session.move(id, toParent: place.parent, afterSibling: place.after)
            self.pages = session.pages
        }
        return true
    }

    func reorder(_ id: UUID, onto target: UUID, upperHalf: Bool) {
        guard let place = pageTree.placement(moving: id, onto: target, upperHalf: upperHalf), allowsMove(id, toParent: place.parent) else { return }
        act {
            guard let session = self.session else { return }
            try await session.move(id, toParent: place.parent, afterSibling: place.after)
            self.pages = session.pages
        }
    }

    func move(_ id: UUID, toParent parent: UUID?) {
        guard allowsMove(id, toParent: parent) else { return }
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

    /// Показывает файл без изменений и без импорта. Картинка или другой нетекстовый файл
    /// (⌘O, перетаскивание на значок в Dock) добавляется на открытую страницу.
    func previewFile(_ url: URL) {
        if !Self.isTextFile(url) {
            guard let editor else {
                errorMessage = L("Это не текстовый файл. Чтобы добавить картинку или файл, откройте страницу и перетащите его в неё или выберите «/» → «Изображение».")
                return
            }
            editor.controller.moveCaretToEnd()
            editor.controller.insertFiles([url])
            notice = String(format: L("«%@» добавлен на страницу."), url.lastPathComponent)
            return
        }
        do {
            let file = try TextFileReader.read(url)
            rememberFile(url)
            leavePage { self.section = .files }
            preview = FilePreview(url: url, text: file.text, encoding: file.encoding)
        } catch {
            errorMessage = String(format: L("Не удалось прочитать файл: %@"), Self.describe(error))
        }
    }

    /// Текст по расширению или типу файла; неизвестное расширение проверяется чтением.
    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "txt", "text", "csv", "tsv", "json", "yaml", "yml", "log", ""].contains(ext) { return true }
        // Картинки, видео, звук, PDF, архивы и прочие известные двоичные форматы — не текст.
        if let type = UTType(filenameExtension: ext), type.isDeclared { return type.conforms(to: .text) }
        // Неизвестное расширение: текст, если читается как текст (размер ограничен читателем).
        return (try? TextFileReader.read(url)) != nil
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
        let id = try await store.workspaceID()
        func list(_ dir: URL, automatic: Bool) -> [BackupItem] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            return urls.filter { Self.backupExtensions.contains($0.pathExtension) && (!automatic || $0.lastPathComponent.hasPrefix(Self.autoPrefix)) }.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return BackupItem(url: url, date: values?.contentModificationDate ?? .distantPast, size: Int64(values?.fileSize ?? 0), automatic: automatic)
            }
        }
        var all = list(backupDirectory(for: id), automatic: false)
        all += list(autoBackupDirectory(for: id), automatic: true)
        backups = all.sorted { $0.date > $1.date }
    }

    /// Папка автоматических копий пространства: своя для каждого, чтобы ротация не задела чужие копии.
    private func autoBackupDirectory(for id: UUID) -> URL {
        if let folder = autoBackupFolder {
            let suffix = id.lowercasedString.prefix(8)
            // Папка, начатая под прежним именем, остаётся: в ней уже лежат копии, которые чередует ротация.
            let old = folder.appendingPathComponent("Minerva Noema \(suffix)", isDirectory: true)
            let new = folder.appendingPathComponent("MindNotes \(suffix)", isDirectory: true)
            let fm = FileManager.default
            return !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: old.path) ? old : new
        }
        return backupDirectory(for: id).appendingPathComponent("auto", isDirectory: true)
    }

    func chooseAutoBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Выбрать")
        panel.message = L("Выберите папку на другом диске: копия на том же диске не защищает от его отказа.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        autoBackupFolder = url
        UserDefaults.standard.set(url.path, forKey: "autoBackupFolder")
        act { try await self.reloadBackups() }
    }

    func resetAutoBackupFolder() {
        autoBackupFolder = nil
        UserDefaults.standard.removeObject(forKey: "autoBackupFolder")
        act { try await self.reloadBackups() }
    }

    /// Проверка при открытии и раз в час: копия создаётся, если прошлой больше суток.
    private func startAutoBackups() {
        autoBackupTimer?.invalidate()
        autoBackupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutoBackupIfDue() }
        }
        runAutoBackupIfDue()
    }

    private func runAutoBackupIfDue() {
        guard autoBackupEnabled, autoBackupTask == nil, let store, let session else { return }
        autoBackupTask = Task { @MainActor in
            defer { self.autoBackupTask = nil }
            do {
                let id = try await store.workspaceID()
                let dir = self.autoBackupDirectory(for: id)
                let last = self.backups.filter(\.automatic).map(\.date).max()
                guard BackupSchedule.isDue(last: last, now: Date()) else { return }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await session.coordinator.flush()
                let url = dir.appendingPathComponent("\(Self.autoPrefix)\(Self.stamp(Date())).\(Self.backupExtension)")
                let root = store.layout.root
                _ = try await Task.detached(priority: .utility) {
                    try BackupService.create(workspaceRoot: root, snapshotter: store, inspector: SQLiteSnapshotInspector(), destination: url,
                                             appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev",
                                             now: SystemClock().nowMillis())
                }.value
                try await self.reloadBackups()
                // Удаляются только собственные автоматические копии, ручные не трогаются.
                let automatic = self.backups.filter(\.automatic)
                let doomed = BackupSchedule.toDelete(automatic.map { (id: $0.url.path, date: $0.date) })
                for item in automatic where doomed.contains(item.url.path) {
                    try? FileManager.default.removeItem(at: item.url)
                }
                try await self.reloadBackups()
            } catch {
                self.notice = String(format: L("Автоматическая копия не создана: %@"), Self.describe(error))
            }
        }
    }

    func makeBackup() {
        act {
            guard let store = self.store else { return }
            let dir = self.backupDirectory(for: try await store.workspaceID())
            try await self.runBackup(to: dir.appendingPathComponent("\(Self.stamp(Date())).\(Self.backupExtension)"))
        }
    }

    func makeBackupAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(workspaceName)-\(Self.stamp(Date())).\(Self.backupExtension)"
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
            panel.allowedContentTypes = Self.backupExtensions.map { UTType(filenameExtension: $0) ?? .data }
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
            _ = try await Task.detached(priority: .userInitiated) {
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
            let peekModel = peek
        let finished = await Self.finishes(within: 5) {
            try await peekModel?.closeSession()
            try await session.close()
        }
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
    // MARK: Экспорт

    /// Страница в Markdown; вложения копируются в папку рядом с файлом. Оригинал не меняется.
    func exportMarkdown(_ id: UUID) {
        guard allowsCopy(of: id) else { return }
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await session.coordinator.flush() // В файл попадают все подтверждённые правки.
            let title = self.pageTree.page(id)?.title ?? ""
            let panel = NSSavePanel()
            panel.nameFieldStringValue = MarkdownExport.safeFileName(title.isEmpty ? L("Без названия") : title) + ".md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // Папка вложений всегда новая: чужие файлы рядом с выбранным местом не перезаписываются.
            let fm = FileManager.default
            let base = url.deletingPathExtension().lastPathComponent + "_files"
            var folder = base
            var n = 1
            while fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(folder).path) {
                n += 1
                folder = "\(base) \(n)"
            }
            let blocks = BlockDocument(pageID: id, blocks: try await store.blocks(ofPage: id)).blocks
            // Запись базы выгружается с карточкой свойств: связи — ссылками [[Заголовок]].
            var card: [String] = []
            var propertyFiles: [(id: UUID, path: String)] = []
            var fileNames: Set<String> = []
            if let databaseID = self.pageTree.page(id)?.databaseID, let database = try await store.database(databaseID) {
                // Файлы «Файлов и медиа» выгружаются в подпапку вложений, карточка ссылается на них.
                card = MarkdownExport.propertyCard(database, values: try await store.recordValues(page: id, database: database), untitled: L("Без названия")) { file in
                    let path = folder + "/properties/" + WorkspaceExport.unique(MarkdownExport.safeFileName(file.name), in: &fileNames)
                    propertyFiles.append((file.id, path))
                    return path
                }
            }
            let result = MarkdownExport.export(title: title, card: card, blocks: blocks, assetFolder: folder) { self.pageTree.page($0)?.title }
            var missing = 0
            let allAssets = result.assets + propertyFiles
            if !allAssets.isEmpty {
                try fm.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent(folder), withIntermediateDirectories: false)
                if !propertyFiles.isEmpty {
                    try fm.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent(folder + "/properties"), withIntermediateDirectories: false)
                }
                for asset in allAssets {
                    let target = url.deletingLastPathComponent().appendingPathComponent(asset.path)
                    // Недопустимый путь вложения считается отсутствующим файлом: чужой файл не копируется.
                    guard let source = (try? await store.assetURL(asset.id)) ?? nil, fm.fileExists(atPath: source.path) else { missing += 1; continue }
                    try fm.copyItem(at: source, to: target)
                }
            }
            try Data(result.markdown.utf8).write(to: url, options: .atomic)
            var lines = [L("Страница экспортирована в Markdown.")]
            lines += result.report.map { "\(L($0.reason)): \($0.count)" }
            if missing > 0 { lines.append(String(format: L("Не найдено вложений: %d"), missing)) }
            self.notice = lines.joined(separator: "\n")
        }
    }

    /// База в CSV: все записи без фильтра, значения в виде, который принимает импорт.
    func exportDatabaseCSV(page id: UUID) {
        guard allowsCopy(of: id) else { return }
        enqueue {
            guard let store = self.store, let session = self.session, let databaseID = self.databaseIndex[id],
                  let database = try await store.database(databaseID) else { return }
            try await session.coordinator.flush()
            let title = self.pageTree.page(id)?.title ?? ""
            let panel = NSSavePanel()
            panel.nameFieldStringValue = WorkspaceExport.fileName(title, untitled: L("Без названия")) + ".csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let rows = try await WorkspaceExport.databaseRows(source: store, database: database)
            try Data(("\u{FEFF}" + CSV.write(rows)).utf8).write(to: url, options: .atomic)
            self.notice = String(format: L("Экспортировано записей: %d."), rows.count - 1)
        }
    }

    /// Всё пространство в новую папку: Markdown, CSV и вложения. Резервную копию не заменяет.
    func exportWorkspace() {
        // Экспорт выгружает и страницы под паролем: при закрытых замках нужно подтверждение владельца Mac.
        if pageLocks.keys.contains(where: { !unlockedPages.contains($0) }) {
            Task { @MainActor in
                guard await Self.deviceOwner(reason: L("выгрузить пространство вместе со страницами под паролем")) else { return }
                self.exportWorkspaceNow()
            }
            return
        }
        exportWorkspaceNow()
    }

    private func exportWorkspaceNow() {
        enqueue {
            guard let store = self.store, let session = self.session else { return }
            try await session.coordinator.flush()
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = L("Экспортировать")
            panel.message = L("Выберите папку. В ней появится новая папка с экспортом; существующие файлы не меняются.")
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            let name = WorkspaceExport.fileName(self.workspaceName, untitled: L("Без названия"))
            let root = dir.appendingPathComponent("\(name) — \(L("экспорт")) \(Self.stamp(Date()))", isDirectory: true)
            self.busyMessage = L("Экспорт…")
            defer { self.busyMessage = nil }
            let untitled = L("Без названия")
            let summary = try await Task.detached(priority: .userInitiated) {
                try await WorkspaceExport.exportAll(source: store, to: root, untitled: untitled)
            }.value
            var lines = [String(format: L("Страниц: %d, баз: %d, записей: %d, вложений: %d."), summary.pages, summary.databases, summary.records, summary.assets)]
            if summary.missingAssets > 0 { lines.append(String(format: L("Не найдено вложений: %d"), summary.missingAssets)) }
            lines += summary.losses.sorted { $0.key < $1.key }.map { "\(L($0.key)): \($0.value)" }
            let report = [L("Экспорт не заменяет резервную копию: история версий, представления баз и корзина в него не входят.")] + lines
            try Data(report.joined(separator: "\n").appending("\n").utf8).write(to: root.appendingPathComponent(L("Отчёт об экспорте") + ".txt"))
            self.notice = ([L("Экспорт завершён.")] + lines).joined(separator: "\n")
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }

    // MARK: Импорт

    /// Одна точка входа: Markdown или текст — страница, CSV — база, папка или .zip — экспорт Notion и папки Markdown.
    /// Источник на экране «Импорт»: окно выбора сразу показывает только подходящее. nil — любой.
    enum ImportKind { case text, table, folder, notion }

    func presentImport(_ kind: ImportKind? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = kind != .folder
        panel.canChooseDirectories = kind == nil || kind == .folder
        panel.allowsMultipleSelection = false
        panel.prompt = L("Импортировать")
        panel.message = L("Файл Markdown, CSV, папка или архив экспорта Notion (.zip). Оригиналы не меняются.")
        switch kind {
        case .text?: panel.allowedContentTypes = ["md", "markdown", "txt"].compactMap { UTType(filenameExtension: $0) }
        case .table?: panel.allowedContentTypes = ["csv", "tsv"].compactMap { UTType(filenameExtension: $0) }
        case .notion?: panel.allowedContentTypes = [.zip]
        default: break
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        switch url.pathExtension.lowercased() {
        case _ where isDirectory: importFolder(url, archive: false)
        case "zip": importFolder(url, archive: true)
        case "csv", "tsv":
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= TextFileReader.maxSize else { throw CocoaError(.fileReadTooLarge) }
                csvImport = CSVImportRequest(url: url, data: data)
            } catch { errorMessage = Self.describe(error) }
        default: importFile(url)
        }
    }

    /// Повторный импорт того же содержимого: спросить, прежде чем создавать копии.
    private func confirmRepeat(_ fingerprint: String) async throws -> Bool {
        guard let store, let when = try await store.meta("import." + fingerprint) else { return true }
        let alert = NSAlert()
        alert.messageText = L("Это уже импортировалось")
        alert.informativeText = String(format: L("То же содержимое импортировано %@. Повторный импорт создаст копии страниц."), when)
        alert.addButton(withTitle: L("Импортировать ещё раз"))
        alert.addButton(withTitle: L("Отмена"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func rememberImport(_ fingerprint: String) async {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyyHHmm")
        try? await store?.setMeta("import." + fingerprint, f.string(from: Date()))
    }

    /// Чтение плагином (ADR-0019): сначала в базу записываются все подтверждённые правки открытой страницы.
    func flushForPlugin() async throws {
        try await session?.coordinator.flush()
    }

    /// Запись плагином в страницу (ADR-0019, п. 13): прежний текст — версией в истории, затем новые блоки.
    /// Открытая страница меняется через редактор, как «Восстановить версию»: правку можно отменить и там.
    func applyPluginBlocks(pageID: UUID, current: [Block], target: [Block], label: String) async throws {
        if let editorSession = session?.editor, editorSession.pageID == pageID {
            try await editorSession.restore(revisionBlocks: target, label: label)
            editor?.controller.reloadFromSession()
            return
        }
        guard let store else { return }
        let now = SystemClock().nowMillis()
        _ = try await store.saveRevision(pageID: pageID, reason: "Перед правками извне", blocks: current, id: UUID(), now: now)
        let before = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let keep = Set(target.map(\.id))
        var batch = SaveBatch()
        for block in current where !keep.contains(block.id) { batch.deletes.insert(block.id) }
        for block in target where before[block.id] != block { batch.upserts[block.id] = block }
        batch.touchedPages.insert(pageID)
        try await store.commit(batch)
        _ = try await store.saveRevision(pageID: pageID, reason: label, blocks: target, id: UUID(), now: now)
    }

    /// Запись извне (плагин, ADR-0019): пространство уже изменено через хранилище, оболочка перечитывает страницы и теги.
    func refreshAfterExternalWrite() async throws {
        guard let session, let store else { return }
        try await session.refreshPages()
        databaseIndex = try await store.databaseIndex()
        pages = session.pages
        try await reloadTags()
    }

    private func afterImport(open page: UUID) async throws {
        guard let session, let store else { return }
        try await session.refreshPages()
        databaseIndex = try await store.databaseIndex()
        pages = session.pages
        try await show(page)
    }

    func importCSV(_ request: CSVImportRequest, plan: CSVImport.Plan, title: String) {
        enqueue {
            guard let store = self.store else { return }
            let fingerprint = "csv." + SHA256.hash(data: request.data).map { String(format: "%02x", $0) }.joined()
            guard try await self.confirmRepeat(fingerprint) else { return }
            let zone = TimeZone.current.identifier
            // Сборка десятков тысяч записей — не на главном потоке.
            let built = await Task.detached(priority: .userInitiated) { CSVImport.build(plan, zone: zone, ids: RandomIDs()) }.value
            let name = title.trimmingCharacters(in: .whitespaces)
            let database = try await store.importDatabase(parent: nil, title: name, viewName: L("Таблица"),
                                                          properties: built.properties, records: built.records, now: SystemClock().nowMillis())
            await self.rememberImport(fingerprint)
            try await self.afterImport(open: database.pageID)
            var text = String(format: L("Импортировано записей: %d. Файл не изменён."), built.records.count)
            if built.unconverted > 0 { text += "\n" + String(format: L("Не подошли к типу столбца и сохранены как есть: %d."), built.unconverted) }
            self.notice = text
        }
    }

    func importFolder(_ url: URL, archive: Bool) {
        enqueue {
            guard let store = self.store else { return }
            var source = url
            var extracted: URL?
            defer { if let extracted { try? FileManager.default.removeItem(at: extracted) } }
            if archive {
                self.busyMessage = L("Распаковка архива…")
                let temp = FileManager.default.temporaryDirectory
                let result = await Task.detached(priority: .userInitiated) { Result { try ArchiveExtract.extract(url, into: temp) } }.value
                self.busyMessage = nil
                source = try result.get()
                extracted = source
            }
            let root = source
            let plan = try await Task.detached(priority: .userInitiated) { try FolderImport.scan(root) }.value
            guard !plan.markdown.isEmpty || !plan.csv.isEmpty else {
                self.errorMessage = L("Не найдено файлов Markdown и CSV.")
                return
            }
            let confirm = NSAlert()
            confirm.messageText = String(format: L("Импортировать «%@»?"), url.lastPathComponent)
            confirm.informativeText = String(format: L("Страниц: %d, таблиц: %d, других файлов: %d, пропущено: %d. Всё появится под новой страницей импорта; оригиналы не изменятся."),
                                             plan.markdown.count, plan.csv.count, plan.files.count, plan.skipped.count)
            confirm.addButton(withTitle: L("Импортировать"))
            confirm.addButton(withTitle: L("Отмена"))
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            guard try await self.confirmRepeat("folder." + plan.fingerprint) else { return }

            let title = String(format: L("Импорт — %@"), FolderImport.cleanTitle(url.deletingPathExtension().lastPathComponent))
            self.busyMessage = L("Импорт…")
            defer { self.busyMessage = nil }
            let untitled = L("Без названия"), viewName = L("Таблица"), zone = TimeZone.current.identifier
            let (page, report) = try await FolderImport.run(plan, into: store, title: title, untitled: untitled, viewName: viewName,
                                                            zone: zone, now: SystemClock().nowMillis()) { done, total in
                Task { @MainActor in self.busyMessage = String(format: L("Импорт… %d из %d"), done, total) }
            }
            try await FolderImport.commit(Self.reportFragments(report, source: url.lastPathComponent), to: page, target: store,
                                          ids: RandomIDs(), now: SystemClock().nowMillis())
            await self.rememberImport("folder." + plan.fingerprint)
            try await self.afterImport(open: page)
            self.notice = String(format: L("Импорт завершён: страниц %d, баз %d, записей %d. Отчёт — в начале страницы импорта."),
                                 report.pages + report.folders, report.databases, report.records)
        }
    }

    /// Журнал импорта (FR-14.6): итог и потери в начале страницы импорта.
    static func reportFragments(_ r: FolderImport.Report, source: String) -> [BlockFragment] {
        var out = [BlockFragment(type: .callout, content: BlockContent(text: String(format: L("Импорт из «%@». Чтобы отменить его, отправьте эту страницу в корзину."), source)))]
        func line(_ key: String, _ value: Int) {
            guard value > 0 else { return }
            out.append(BlockFragment(type: .bullet, content: BlockContent(text: String(format: L(key), value))))
        }
        line("Страниц: %d", r.pages)
        line("Папок: %d", r.folders)
        line("Баз: %d", r.databases)
        line("Записей: %d", r.records)
        line("Вложений: %d", r.assets)
        line("Ссылок без цели (оставлен текст): %d", r.unresolvedLinks)
        line("Связей Notion восстановлено: %d", r.relations)
        line("Столбцов связей Notion, оставленных текстом: %d", r.textRelations)
        line("Связей с записями не из архива (не перенесены): %d", r.unresolvedRelationLinks)
        line("Картинок без файла (оставлена подпись): %d", r.missingImages)
        line("Значений, не подошедших к типу столбца: %d", r.unconvertedValues)
        line("Файлов без ссылок на них (не импортированы): %d", r.unusedFiles)
        if !r.skipped.isEmpty {
            out.append(BlockFragment(type: .heading3, content: BlockContent(text: L("Пропущено"))))
            for item in r.skipped.prefix(50) {
                out.append(BlockFragment(type: .bullet, content: BlockContent(text: "\(item.path) — \(L(item.reason))")))
            }
            if r.skipped.count > 50 { line("И ещё: %d", r.skipped.count - 50) }
        }
        out.append(BlockFragment(type: BlockType.divider.rawValue, contentVersion: 1, json: "{}", plain: ""))
        return out
    }

    // MARK: История версий

    func revisions(of page: UUID) async -> [Revision] {
        (try? await store?.revisions(ofPage: page)) ?? []
    }

    func revisionBlocks(_ revision: Revision) async -> [Block] {
        (try? await store?.revisionBlocks(revision.id)) ?? []
    }

    /// Только для открытой страницы: восстановление идёт через её сессию, чтобы правку можно было отменить.
    func restore(_ revision: Revision) {
        enqueue {
            guard let store = self.store, let editorSession = self.session?.editor, editorSession.pageID == revision.pageID else {
                self.errorMessage = L("Откройте страницу, чтобы восстановить её версию.")
                return
            }
            let blocks = try await store.revisionBlocks(revision.id)
            try await editorSession.restore(revisionBlocks: blocks, label: String(format: L("Восстановлено из версии %d"), revision.seq))
            self.editor?.controller.reloadFromSession()
            self.notice = String(format: L("Восстановлена версия %d. Прежний текст сохранён в истории."), revision.seq)
        }
    }

    private func act(_ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await body() }
            catch { self.errorMessage = Self.describe(error) }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    func children(of parent: UUID?) -> [Page] {
        pageTree.children(of: parent)
    }

    /// Записи показывает их база. Запись, чья база в корзине, остаётся видна в дереве и не теряется.
    private func isRecordInLiveDatabase(_ page: Page) -> Bool {
        page.databaseID.map(liveDatabases.contains) ?? false
    }

    func path(of id: UUID) -> [Page] {
        pageTree.path(of: id)
    }

    /// Куда можно переместить страницу: не в неё саму и не в потомков.
    func moveTargets(for id: UUID) -> [Page] {
        let banned = pageTree.subtree(of: id)
        return pages.filter { !banned.contains($0.id) && !isDatabase($0.id) && !isRecordInLiveDatabase($0) }
    }

    // MARK: ИИ (ADR-0016)

    /// Выполняет шаг в общей очереди навигации и ждёт его: правки ИИ не пересекаются с переходами пользователя.
    func aiRun<T>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
            let previous = navigation
            navigation = Task { @MainActor in
                await previous?.value
                do { done.resume(returning: try await body()) } catch { done.resume(throwing: error) }
            }
        }
    }

    /// Блоки страницы: у открытой — из редактора (с несохранёнными правками), у остальных — из базы после записи.
    func aiBlocks(of id: UUID) async throws -> [Block] {
        if let editor, editor.pageID == id { return editor.controller.document.blocks }
        guard let session, let store else { throw WorkspaceError.storage(code: 0, detail: "пространство закрыто") }
        try await session.coordinator.flush()
        return try await store.blocks(ofPage: id)
    }

    /// Открывает страницу в редакторе (если она ещё не открыта) и возвращает его: правка идёт через команды и отмену.
    func aiEditor(for id: UUID) async throws -> PageEditorModel {
        try await aiRun {
            if let editor = self.editor, editor.pageID == id { return editor }
            guard self.pages.contains(where: { $0.id == id }), !self.isDatabase(id) else { throw WorkspaceError.storage(code: 0, detail: "страница не найдена") }
            try await self.show(id)
            guard let editor = self.editor, editor.pageID == id else { throw WorkspaceError.storage(code: 0, detail: "страница не открылась") }
            return editor
        }
    }

    /// Новая страница с содержимым; открывается, как после импорта.
    func aiCreatePage(parent: UUID?, title: String, fragments: [BlockFragment]) async throws -> UUID {
        try await aiRun {
            guard let session = self.session else { throw WorkspaceError.storage(code: 0, detail: "пространство закрыто") }
            let parentID = parent.flatMap { id in self.pages.contains { $0.id == id } ? id : nil }
            let page = try await session.createPage(parent: parentID, title: title)
            self.pages = session.pages
            let opened = try await session.open(page.id)
            if let first = opened.document.blocks.first, !fragments.isEmpty {
                try opened.perform(.replaceRange(BlockSelection(block: first.id, offset: 0), fragments), recordUndo: false)
            }
            self.pages = session.pages
            self.installEditor(opened, id: page.id)
            return page.id
        }
    }

    /// В корзину и обратно — для предложения и его отмены.
    func aiTrash(_ id: UUID) async throws {
        trash(id)
        try await aiRun { try await self.reloadTrash() }
    }

    /// База по ID её страницы (агент видит базы как страницы).
    func aiDatabase(page: UUID) async throws -> Database? {
        guard let store, let id = databaseIndex[page] else { return nil }
        return try await store.database(id)
    }

    /// Записи и значения изменились не через экран базы: обновить список страниц и открытую базу.
    func aiRecordsChanged() async throws {
        try await aiRun {
            guard let session = self.session else { return }
            try await session.refreshPages()
            self.pages = session.pages
            self.databaseModel?.reload()
            // Правки записей от ИИ тоже уходят в Календарь.
            self.calendarSync?.recordsChanged()
        }
    }

    func aiRestoreFromTrash(_ id: UUID) async throws {
        let item: TrashItem? = try await aiRun {
            try await self.reloadTrash()
            return self.trashItems.first { $0.page.id == id }
        }
        if let item { restoreFromTrash(item) }
        try await aiRun {}
    }
}
