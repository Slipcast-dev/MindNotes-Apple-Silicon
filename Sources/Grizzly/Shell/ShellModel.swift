import AppKit
import SwiftUI

enum ShellSection: Equatable {
    case welcome
    case home
    case files
    case page(UUID)
    case backups
    case settings
    case trash
}

/// Сборка зависимостей и состояние оболочки. Принадлежит AppDelegate, новых singleton нет.
@MainActor
final class ShellModel: ObservableObject {
    @Published var section: ShellSection = .welcome
    @Published private(set) var workspaceName = ""
    @Published private(set) var pages: [Page] = []
    @Published private(set) var saveStatus: SaveStatus = .saved
    @Published private(set) var editor: PageEditorModel? {
        didSet { if oldValue !== editor { oldValue?.closePanels() } }
    }
    @Published var errorMessage: String?
    @Published private(set) var recentFiles: [URL] = []
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

    var isOpen: Bool { session != nil }
    var workspaceRoot: URL? { store?.layout.root }

    struct BackupItem: Identifiable, Equatable {
        var url: URL
        var date: Date
        var size: Int64
        var id: URL { url }
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
        act {
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
        act {
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

    private func adopt(_ store: SQLiteWorkspace) async throws {
        try await closeSession()
        let name = try await store.workspaceName()
        let session = WorkspaceSession(store: store, name: name)
        session.coordinator.onStatusChange = { [weak self] in self?.saveStatus = $0 }
        try await session.refreshPages()
        self.store = store
        self.session = session
        workspaceName = name
        pages = session.pages
        saveStatus = .saved
        // Файл, открытый из Finder при запуске, важнее восстановления последней страницы.
        if section != .files { section = .home }
        UserDefaults.standard.set(store.layout.root.path, forKey: lastWorkspaceKey)
        try await reloadBackups()
        // После перезапуска пользователь возвращается к той же странице.
        if section != .files, let raw = UserDefaults.standard.string(forKey: lastPageKey), let id = UUID(uuidString: raw), pages.contains(where: { $0.id == id }) {
            try await show(id)
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
        section = .page(id)
        UserDefaults.standard.set(id.uuidString, forKey: lastPageKey)
    }

    func goHome() {
        UserDefaults.standard.removeObject(forKey: lastPageKey)
        leavePage { self.section = self.isOpen ? .home : .welcome }
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
            self.notice = L("Страница перемещена в корзину.")
        }
    }

    func restoreFromTrash(_ item: TrashItem) {
        enqueue {
            guard let session = self.session else { return }
            let moved = try await session.restore(batch: item.batchID)
            self.pages = session.pages
            try await self.reloadTrash()
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
