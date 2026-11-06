import QuickLook
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case files, recent, favorites
    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return L("Файлы")
        case .recent: return L("Недавние")
        case .favorites: return L("Избранное")
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .recent: return "clock"
        case .favorites: return "star"
        }
    }
}

/// Sidebar action buttons: equal width, tinted on hover, shrink while pressed.
struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonStyle(size: .row, base: 0.07).makeBody(configuration: configuration)
            .font(.system(size: 15))
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("sidebarSection") private var section: SidebarSection = .files

    /// Rows picked in the list: files and folders, several at once with ⌘-click and ⇧-click.
    @State private var selection: Set<UUID> = []
    @State private var query = ""
    @State private var isNaming = false
    @State private var newName = ""
    @State private var nameError: String?
    @State private var pendingMove: UUID?
    /// The folder a new folder is being created in (nil: the top level).
    @State private var namingParent: UUID?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var targetedFolder: UUID?
    @FocusState private var nameFocused: Bool
    @State private var previewURL: URL?
    @State private var smartRequest: SmartFolderRequest?
    @State private var spaceMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            // Same 30 pt height and 7 pt corners as the filter field below, so the header controls line up.
            HStack(spacing: 2) {
                ForEach(SidebarSection.allCases) { s in
                    Button { section = s } label: {
                        Image(systemName: s.symbol).font(.system(size: 14))
                    }
                    .buttonStyle(HoverButtonStyle(size: .row, selected: section == s))
                    .help(s.title)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Поиск файлов", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // File actions in one row of equal buttons (they used to be split between the title bar and the list header).
            HStack(spacing: 6) {
                Button { state.presentNewFilePanel() } label: { Image(systemName: "doc.badge.plus") }
                    .help("Новый файл (⌘N)")
                Button { state.presentOpenPanel() } label: { Image(systemName: "folder") }
                    .help("Открыть файл или папку (⌘O)")
                Button { popUpNewFolderMenu() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Новая папка или смарт-папка")
                Button { state.presentSaveAsPanel() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Сохранить как… (⇧⌘S)")
                    .disabled(state.current == nil)
            }
            .buttonStyle(SidebarIconButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: $selection) {
                if !state.selectedTags.isEmpty {
                    tagContent(state.selectedTags)
                } else {
                    switch section {
                    case .files: filesContent
                    case .recent: recentContent
                    case .favorites: favoritesContent
                    }
                }
            }
            .listStyle(.sidebar)
            .dropDestination(for: String.self) { items, _ in
                guard section == .files else { return false }
                return drop(items, into: nil)
            }
            .overlay { emptyState }
            .onDeleteCommand { deleteSelection(selection) }

            TagPanel()
        }
        .onChange(of: selection) { picked in
            // One file picked: it opens. Several rows picked: they wait for a command (move, delete, update ...).
            if picked.count == 1, let id = picked.first, library.file(id) != nil, state.selectedFileID != id { state.selectedFileID = id }
        }
        .onChange(of: state.selectedFileID) { id in
            if let id, selection != [id] { selection = [id] }
            // Option-click opens the file in the right pane.
            state.openLibraryFile(id, inRight: NSEvent.modifierFlags.contains(.option))
        }
        .onChange(of: section) { _ in finishNaming() }
        .onChange(of: state.sidebarRevealToken) { _ in section = .files }
        // A name typed but never confirmed with Return still creates the folder when focus leaves the field.
        .onChange(of: nameFocused) { focused in
            guard !focused else { return }
            if isNaming { commitNew() }
            else if let id = renamingID, let folder = library.folder(id) { commitRename(folder) }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $smartRequest) { request in
            SmartFolderEditor(request: request) { id in
                section = .files
                state.selectedTags = []
                library.setExpanded(id, true)
                state.scanTagsInLibrary()
                state.notify(request.folderID == nil ? L("Смарт-папка создана.") : L("Смарт-папка сохранена."), symbol: SmartFolderIcon.symbol)
            }
        }
        .onAppear(perform: installSpaceMonitor)
        .onDisappear(perform: removeSpaceMonitor)
    }

    // MARK: Sections

    @ViewBuilder
    private var filesContent: some View {
        Section {
            if isNaming && namingParent == nil { nameField }
            ForEach(visibleFolders(in: nil)) { folder in folderRow(folder) }
            ForEach(filtered(library.files(in: nil))) { file in fileRow(file) }
        } header: {
            HStack {
                Text("Файлы")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var recentContent: some View {
        let items = filtered(library.recents)
        if !items.isEmpty {
            Section {
                ForEach(items) { entry in historyRow(entry) }
            } header: {
                HStack {
                    Text("Недавно открытые")
                    Spacer()
                    Button("Очистить") { library.clearRecents() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        let items = filtered(library.favorites)
        if !items.isEmpty {
            Section("Избранное") {
                ForEach(items) { file in fileRow(file) }
            }
        }
    }

    /// All files that carry every selected tag, wherever they live in the library.
    @ViewBuilder
    private func tagContent(_ tags: [String]) -> some View {
        Section {
            ForEach(filtered(library.files(withAllTags: tags))) { file in fileRow(file) }
        } header: {
            HStack {
                Text("Теги: \(tags.map { "#" + $0 }.joined(separator: " "))")
                    .lineLimit(1)
                Spacer()
                Button("Сбросить") { state.selectedTags = [] }.buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !state.selectedTags.isEmpty {
            if library.files(withAllTags: state.selectedTags).isEmpty {
                hint("tag", "Нет файлов со всеми выбранными тегами.")
            }
        } else {
            sectionEmptyState
        }
    }

    @ViewBuilder
    private var sectionEmptyState: some View {
        switch section {
        case .files where library.folders(in: nil).isEmpty && library.files(in: nil).isEmpty && !isNaming:
            hint("doc.badge.plus", "Откройте файл (⌘O) или перетащите его в окно.")
        case .recent where library.recents.isEmpty:
            hint("clock", "Здесь появятся файлы, которые вы открывали.")
        case .favorites where library.favorites.isEmpty:
            hint("star", "Добавьте файл в избранное через контекстное меню.")
        default:
            EmptyView()
        }
    }

    private func hint(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light))
            Text(text).multilineTextAlignment(.center).font(AppFont.callout)
        }
        .foregroundColor(.secondary)
        .padding(24)
    }

    // MARK: Rows

    /// A folder stays when its name matches (then all its files show) or when some file or folder inside matches.
    private func visibleFolders(in parent: UUID?) -> [LibraryFolder] {
        let all = library.folders(in: parent)
        return query.isEmpty ? all : all.filter(folderMatches)
    }

    private func folderMatches(_ folder: LibraryFolder) -> Bool {
        Searcher.nameMatches(folder.name, query: query)
            || !filtered(library.files(in: folder.id)).isEmpty
            || library.folders(in: folder.id).contains(where: folderMatches)
    }

    private func filtered(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        query.isEmpty ? entries : entries.filter { Searcher.nameMatches($0.name, query: query) }
    }

    /// Matches by the beginning of the name or of any word in it; "#word" searches the tags the same way.
    private func matches(_ file: LibraryFile) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix("#") {
            let tag = LibraryStore.cleanTag(q)
            return tag.isEmpty ? !file.tags.isEmpty : file.tags.contains { Searcher.nameMatches($0, query: tag) }
        }
        return Searcher.nameMatches(file.name, query: q)
    }

    private func filtered(_ files: [LibraryFile]) -> [LibraryFile] {
        query.isEmpty ? files : files.filter(matches)
    }

    /// Folders nest to any depth, so a folder row draws its subfolders with the same function.
    private func folderRow(_ folder: LibraryFolder) -> AnyView { AnyView(folderRowBody(folder)) }

    @ViewBuilder
    private func folderRowBody(_ folder: LibraryFolder) -> some View {
        let all = library.files(in: folder.id)
        let nameHit = !query.isEmpty && Searcher.nameMatches(folder.name, query: query)
        let files = nameHit ? all : filtered(all)
        let subfolders = nameHit ? library.folders(in: folder.id) : visibleFolders(in: folder.id)
        let count = query.isEmpty ? library.fileCount(in: folder.id) : files.count
        DisclosureGroup(
            isExpanded: Binding(
                get: { folder.isExpanded },
                set: { library.setExpanded(folder.id, $0) })
        ) {
            if isNaming && namingParent == folder.id { nameField }
            ForEach(subfolders) { sub in folderRow(sub) }
            ForEach(files) { file in fileRow(file) }
            if files.isEmpty && subfolders.isEmpty && query.isEmpty && !(isNaming && namingParent == folder.id) {
                Text(folder.smart?.isEmpty == true ? "Условия не заданы. Откройте настройки папки."
                     : folder.isSmart ? "Подходящих файлов пока нет."
                     : "Пусто. Перетащите сюда файл.")
                    .font(AppFont.caption)
                    .foregroundColor(.secondary)
            }
        } label: {
            folderLabel(folder, count: count)
        }
        .tag(folder.id)
        .contextMenu { folderMenu(folder) }
    }

    /// The commands of a folder row. When the row is one of several picked rows, they act on all of them.
    @ViewBuilder
    private func folderMenu(_ folder: LibraryFolder) -> some View {
        let ids = targets(folder.id)
        if ids.count > 1 {
            Button("Развернуть выбранные папки") { setExpanded(ids, true) }
            Button("Свернуть выбранные папки") { setExpanded(ids, false) }
            Button("Переместить в…") { popUpMove(ids) }
            Button("Обновить из папок") { ids.filter { library.folderURL($0) != nil }.forEach { state.syncFolder($0) } }
            Divider()
            Button("Убрать выбранное (\(ids.count))", role: .destructive) { deleteSelection(ids) }
        } else {
            if folder.isSmart {
                Button("Настроить смарт-папку…") { smartRequest = SmartFolderRequest(folderID: folder.id) }
                Button("Быстрый просмотр") { state.previewFolder(folder.id) }
                Divider()
            } else {
                Button("Новая папка внутри") {
                    section = .files
                    pendingMove = nil
                    library.setExpanded(folder.id, true)
                    beginNaming(in: folder.id)
                }
                Button("Быстрый просмотр") { state.previewFolder(folder.id) }
            }
            Button("Переименовать") {
                renameText = folder.name
                renamingID = folder.id
                nameFocused = true
            }
            Button("Переместить в…") { popUpMove(ids) }
            Button("Показать в Finder") {
                if let url = library.folderURL(folder.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(library.folderURL(folder.id) == nil)
            Button("Обновить из папки") { state.syncFolder(folder.id) }
                .disabled(library.folderURL(folder.id) == nil)
            Button("Удалить папку", role: .destructive) { state.deleteFolder(folder.id) }
        }
    }

    // MARK: Several rows at once

    private func targets(_ id: UUID) -> Set<UUID> { selection.contains(id) ? selection : [id] }

    private func setExpanded(_ ids: Set<UUID>, _ expanded: Bool) {
        for id in ids where library.folder(id) != nil { library.setExpanded(id, expanded) }
    }

    /// What a drag carries: the dragged row, or all picked rows when it is one of them.
    private func dragPayload(_ id: UUID) -> String {
        let ids = selection.contains(id) && selection.count > 1 ? Array(selection) : [id]
        return ids.map { library.folder($0) != nil ? "folder:" + $0.uuidString : $0.uuidString }.joined(separator: "\n")
    }

    private func deleteSelection(_ ids: Set<UUID>) {
        guard section == .files || !state.selectedTags.isEmpty else { return }
        state.removeFromLibrary(folders: ids.filter { library.folder($0) != nil }, files: ids.filter { library.file($0) != nil })
        selection = []
    }

    private func moveItems(_ ids: Set<UUID>, to parent: UUID?) {
        var failed: [String] = []
        for id in ids {
            if let folder = library.folder(id) {
                if !library.moveFolder(id, to: parent) && folder.parentID != parent { failed.append(folder.name) }
            } else if library.file(id) != nil {
                library.move(id, to: parent)
            }
        }
        if !failed.isEmpty {
            state.errorMessage = L("Не удалось переместить папки: %@. В том месте уже есть папка с таким именем.", failed.joined(separator: ", "))
        }
    }

    private func moveFolder(_ folder: LibraryFolder, to parent: UUID?) {
        if !library.moveFolder(folder.id, to: parent) {
            state.errorMessage = L("Не удалось переместить папку «%@»: в том месте уже есть папка с таким именем.", folder.name)
        }
    }

    @ViewBuilder
    private func folderLabel(_ folder: LibraryFolder, count: Int) -> some View {
        if renamingID == folder.id {
            TextField("Название", text: $renameText)
                .focused($nameFocused)
                .onSubmit { commitRename(folder) }
                .onExitCommand { renamingID = nil }
        } else {
            HStack {
                Label(folder.name, systemImage: folder.isSmart ? SmartFolderIcon.symbol : "folder").lineLimit(1)
                Spacer()
                Text("\(count)").font(AppFont.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(targetedFolder == folder.id ? Color.accentColor.opacity(0.28) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { library.setExpanded(folder.id, !folder.isExpanded) }
            }
            .draggable(dragPayload(folder.id))
            .dropDestination(for: String.self) { items, _ in
                drop(items, into: folder.id)
            } isTargeted: { targeted in
                // A smart folder takes no files, so it does not light up as a drop target.
                targetedFolder = targeted && !folder.isSmart ? folder.id : (targetedFolder == folder.id ? nil : targetedFolder)
            }
        }
    }

    private func fileRow(_ file: LibraryFile, showsDate: Bool = false) -> some View {
        let isMissing = library.isMissing(file.id)
        return HStack(spacing: 6) {
            Image(systemName: isMissing ? "exclamationmark.triangle" : file.type.symbol)
                .foregroundColor(isMissing ? .orange : .secondary)
            Text(file.name)
                .lineLimit(1)
                .foregroundColor(isMissing ? .secondary : .primary)
            Spacer(minLength: 4)
            if showsDate, let date = file.lastOpened {
                Text(relative(date)).font(AppFont.caption).foregroundColor(.secondary)
            }
            if file.isFavorite {
                Image(systemName: "star.fill").font(AppFont.caption).foregroundColor(.yellow)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(file.id)
        .draggable(dragPayload(file.id))
        // Hit-testing of a draggable row is flaky near its edges; handle the click on the whole row ourselves.
        .simultaneousGesture(TapGesture().onEnded {
            guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            let inRight = NSEvent.modifierFlags.contains(.option)
            if state.selectedFileID == file.id {
                state.openLibraryFile(file.id, inRight: inRight)
            } else {
                state.selectedFileID = file.id
            }
        })
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .contextMenu { fileMenu(file) }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let isMissing = library.isMissing(entry)
        return HStack(spacing: 6) {
            Image(systemName: isMissing ? "exclamationmark.triangle" : entry.type.symbol)
                .foregroundColor(isMissing ? .orange : .secondary)
            Text(entry.name)
                .lineLimit(1)
                .foregroundColor(isMissing ? .secondary : .primary)
            Spacer(minLength: 4)
            Text(relative(entry.date)).font(AppFont.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { state.openHistory(entry, inRight: NSEvent.modifierFlags.contains(.option)) }
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .contextMenu {
            Button("Открыть") { state.openHistory(entry) }
            Button("Открыть справа") { state.openHistory(entry, inRight: true) }
            Button("Показать в Finder") {
                if let url = library.resolve(entry) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(isMissing)
            Divider()
            Button("Убрать из истории", role: .destructive) { library.removeFromHistory(entry.path) }
        }
    }

    @ViewBuilder
    private func fileMenu(_ file: LibraryFile) -> some View {
        let ids = targets(file.id)
        if ids.count > 1 {
            Button("Открыть выбранные (\(ids.filter { library.file($0) != nil }.count))") {
                for id in ids where library.file(id) != nil { state.openLibraryFile(id) }
            }
            Button("Переместить в…") { popUpMove(ids) }
            Divider()
            Button("Убрать выбранное (\(ids.count))", role: .destructive) { deleteSelection(ids) }
        } else {
            singleFileMenu(file)
        }
    }

    @ViewBuilder
    private func singleFileMenu(_ file: LibraryFile) -> some View {
        Button("Открыть") { state.openLibraryFile(file.id) }
        Button("Открыть справа") { state.openLibraryFile(file.id, inRight: true) }
        Button("Быстрый просмотр") { quickLook(file.id) }
        Button(LocalizedStringKey(file.isFavorite ? "Убрать из избранного" : "Добавить в избранное")) {
            library.toggleFavorite(file.id)
            state.notify(file.isFavorite ? L("Убрано из избранного.") : L("Добавлено в избранное."), symbol: "star.fill")
        }
        // These two menus list every tag and every folder. A row's context menu is built when the row is drawn, and with
        // thousands of rows that was seconds of work, so the lists are built only when the item is clicked.
        Button("Теги…") { popUpTags(for: file) }
        Button("Переместить в…") { popUpMove([file.id]) }
        Divider()
        Button("Показать в Finder") {
            if let url = library.resolve(file.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Button("Убрать из библиотеки", role: .destructive) { state.removeFromLibrary(file.id) }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "folder").foregroundColor(.accentColor)
                TextField("Название папки", text: $newName)
                    .focused($nameFocused)
                    .onSubmit(commitNew)
                    .onExitCommand(perform: cancelNaming)
            }
            if let nameError {
                Text(nameError).font(AppFont.caption).foregroundColor(.red)
            }
        }
    }

    // MARK: Menus built on demand

    private func popUp(_ items: [NSMenuItem]) {
        let menu = NSMenu()
        items.forEach(menu.addItem)
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    private func popUpNewFolderMenu() {
        func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        popUp([
            ClosureItem(L("Новая папка"), image: icon("folder")) {
                section = .files
                pendingMove = nil
                beginNaming(in: nil)
            },
            ClosureItem(L("Смарт-папка…"), image: icon(SmartFolderIcon.symbol)) {
                section = .files
                smartRequest = SmartFolderRequest()
            },
        ])
    }

    private func popUpTags(for file: LibraryFile) {
        var items: [NSMenuItem] = library.allTags.map { tag in
            ClosureItem("#" + tag, checked: library.hasTag(file.id, tag)) {
                state.notify(library.hasTag(file.id, tag) ? L("Тег #%@ убран.", tag) : L("Тег #%@ добавлен.", tag), symbol: "tag.fill")
                library.toggleTag(file.id, tag)
            }
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ClosureItem(L("Новый тег…")) {
            if let name = TextPrompt.ask(title: L("Новый тег"), confirm: L("Создать")),
               let tag = library.createTag(name), !library.hasTag(file.id, tag) {
                library.toggleTag(file.id, tag)
                state.notify(L("Тег #%@ добавлен.", tag), symbol: "tag.fill")
            }
        })
        popUp(items)
    }

    private func popUpMove(_ ids: Set<UUID>) {
        var blocked = Set<UUID>()
        for id in ids where library.folder(id) != nil { blocked.formUnion(library.subtreeIDs(of: id)) }
        var items: [NSMenuItem] = [ClosureItem(L("На верхний уровень")) { moveItems(ids, to: nil) }, .separator()]
        items += library.folderChoices.filter { !blocked.contains($0.folder.id) }.map { choice in
            ClosureItem(choice.path) { moveItems(ids, to: choice.folder.id) }
        }
        if ids.count == 1, let id = ids.first, library.file(id) != nil {
            items.append(.separator())
            items.append(ClosureItem(L("Новая папка…")) {
                section = .files
                pendingMove = id
                beginNaming(in: library.file(id)?.folderID)
            })
        }
        popUp(items)
    }

    // MARK: Quick Look

    /// Previews the file in the system Quick Look panel without opening it in a tab.
    private func quickLook(_ id: UUID?) {
        guard let id, library.file(id) != nil else { return }
        guard let url = library.resolve(id) else {
            state.errorMessage = L("Файл «%@» не найден. Возможно, он перемещён или удалён.", library.file(id)?.name ?? "")
            return
        }
        previewURL = url
    }

    /// Space previews the selected sidebar file, unless text is being typed somewhere.
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let pickedFolder = selection.count == 1 ? selection.first.flatMap { library.folder($0) != nil ? $0 : nil } : nil
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  NSApp.keyWindow?.identifier?.rawValue.contains("QLPreview") != true,
                  state.contentsPreview != nil || pickedFolder != nil || state.selectedFileID != nil else { return event }
            // Space on a picked folder looks into it; on a file it opens the system Quick Look. Space again closes either.
            if state.contentsPreview != nil { state.contentsPreview = nil }
            else if let pickedFolder { state.previewFolder(pickedFolder) }
            else if previewURL != nil { previewURL = nil }
            else { quickLook(state.selectedFileID) }
            return nil
        }
    }

    private func removeSpaceMonitor() {
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
    }

    // MARK: Actions

    private func beginNaming(in parent: UUID?) {
        namingParent = parent
        newName = ""
        nameError = nil
        isNaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func cancelNaming() {
        isNaming = false
        newName = ""
        nameError = nil
        pendingMove = nil
        namingParent = nil
    }

    /// Creates the folder if a name was typed, otherwise just closes the field.
    private func finishNaming() {
        guard isNaming else { return }
        commitNew()
        if isNaming { cancelNaming() }
    }

    private func commitNew() {
        guard isNaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { cancelNaming(); return }
        guard !library.folderExists(name, in: namingParent) else {
            nameError = L("Папка с таким именем уже есть.")
            return
        }
        let folder = library.createFolder(name, parent: namingParent)
        if let pendingMove { library.move(pendingMove, to: folder.id) }
        cancelNaming()
    }

    private func commitRename(_ folder: LibraryFolder) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != folder.name, !library.folderExists(name, in: folder.parentID, ignoring: folder.id) {
            library.renameFolder(folder.id, to: name)
        }
        renamingID = nil
    }

    private func drop(_ items: [String], into folderID: UUID?) -> Bool {
        if let folderID, library.folder(folderID)?.isSmart == true { return false }
        var ids = Set<UUID>()
        for item in items.flatMap({ $0.split(separator: "\n").map(String.init) }) {
            let raw = item.hasPrefix("folder:") ? String(item.dropFirst(7)) : item
            if let id = UUID(uuidString: raw) { ids.insert(id) }
        }
        let known = ids.filter { library.folder($0) != nil || library.file($0) != nil }
        guard !known.isEmpty else { return false }
        moveItems(known, to: folderID)
        return true
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
