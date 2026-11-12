import AppKit
import SwiftUI

/// Корень окна. Боковая панель общая; файловый режим живёт в области содержимого.
struct RootView: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var prefs: AppPreferences
    @EnvironmentObject private var updater: Updater

    var body: some View {
        NotesLayout()
            .id("\(prefs.theme.rawValue)|\(prefs.customThemeID ?? "")") // Токены читаются при построении: смена темы перестраивает дерево.
            .sheet(isPresented: $shell.showsLookSheet) { WorkspaceLookSheet() }
            .sheet(isPresented: $shell.showsSearch) { SearchSheet() }
            .sheet(item: $shell.pageToMove) { MovePageSheet(page: $0) }
            .sheet(item: $shell.historyPage) { HistorySheet(page: $0) }
            .sheet(item: $shell.csvImport) { CSVImportSheet(request: $0) }
            .sheet(item: $shell.playingVideo) { VideoPlayerSheet(video: $0) }
            .sheet(isPresented: $updater.showsSheet) { UpdateSheet(updater: updater) }
            .background(WindowChrome(theme: prefs.theme))
            .background(WindowFrameSaver(name: "MindNotesMainWindow"))
            .preferredColorScheme(prefs.isDark ? .dark : .light)
            .toolbar {
                // Без системных капсул: они обтягивают содержимое почти без отступов, в макете их нет.
                ToolbarItem(placement: .navigation) {
                    Text(AppEdition.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .automatic) { Spacer() } // Прижимает переключатель темы к правому краю.
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .automatic) {
                    Button { prefs.isDark.toggle() } label: {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Переключить тему")
                    .accessibilityLabel(Text("Переключить тему"))
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .alert("Ошибка", isPresented: Binding(get: { shell.errorMessage != nil }, set: { if !$0 { shell.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shell.errorMessage ?? "")
            }
    }
}

/// Заголовок окна в цвет бумаги.
struct WindowChrome: NSViewRepresentable {
    let theme: AppTheme
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = Tokens.paperNS
        }
    }
}

/// Раскладка пространства по макету: боковая панель 240, хлебные крошки 54, содержимое.
struct NotesLayout: View {
    @EnvironmentObject private var shell: ShellModel
    /// Свёрнутая панель показана поверх текста: курсор у левого края.
    @State private var peeking = false
    @State private var resizeStart: Double?

    var body: some View {
        Group {
            if shell.section == .welcome {
                WelcomeScreen()
            } else {
                HStack(spacing: 0) {
                    if !shell.sidebarCollapsed {
                        NotesSidebar()
                            .frame(width: CGFloat(shell.sidebarWidth))
                            .transition(.move(edge: .leading))
                        Rectangle().fill(Tokens.line).frame(width: 1)
                            .overlay { resizeHandle }
                    }
                    VStack(spacing: 0) {
                        CrumbBar()
                        Rectangle().fill(Tokens.line).frame(height: 1)
                        content
                    }
                }
                .overlay(alignment: .leading) {
                    if shell.sidebarCollapsed { peekSidebar }
                }
                .overlay { if let peek = shell.peek { PeekOverlay(editor: peek, mode: shell.peekMode) } }
                .overlay(alignment: .topTrailing) { aiChat }
                .animation(.easeInOut(duration: 0.15), value: shell.sidebarCollapsed)
            }
        }
        .foregroundColor(Tokens.ink)
        .background(Tokens.paper)
        .overlay(Rectangle().fill(Tokens.line).frame(height: 1), alignment: .top)
        .overlay(alignment: .bottomTrailing) { noticeView }
    }

    /// Чат с ИИ (ADR-0016): плавающая панель справа; при выключенном ИИ — подсказка про настройки.
    @ObservedObject private var chat = AIChatModel.shared
    @ViewBuilder private var aiChat: some View {
        if chat.isOpen, shell.isOpen {
            AIChatPanel(chat: chat)
                .padding(.top, Tokens.crumbHeight + 8)
                .padding([.trailing, .bottom], 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Граница панели тянется: ширина 200–480, запоминается при отпускании.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = resizeStart ?? shell.sidebarWidth
                        resizeStart = start
                        shell.setSidebarWidth(start + Double(g.translation.width), save: false)
                    }
                    .onEnded { _ in
                        resizeStart = nil
                        shell.setSidebarWidth(shell.sidebarWidth, save: true)
                    }
            )
            .onTapGesture(count: 2) { shell.setSidebarWidth(Double(Tokens.sidebarWidth), save: true) }
            .help(L("Потяните, чтобы изменить ширину; двойной щелчок — обычная ширина"))
    }

    /// Свёрнутая панель: полоска у левого края, наведение показывает панель поверх текста.
    @ViewBuilder private var peekSidebar: some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 10).frame(maxHeight: .infinity).contentShape(Rectangle())
                .onHover { if $0 { withAnimation(.easeOut(duration: 0.15)) { peeking = true } } }
            if peeking {
                NotesSidebar()
                    .frame(width: CGFloat(shell.sidebarWidth))
                    .frame(maxHeight: .infinity)
                    .background(Tokens.side)
                    .overlay(Rectangle().fill(Tokens.line).frame(width: 1), alignment: .trailing)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: 2)
                    .onHover { if !$0 { withAnimation(.easeIn(duration: 0.15)) { peeking = false } } }
                    .transition(.move(edge: .leading))
            }
        }
        .onChange(of: shell.sidebarCollapsed) { _, _ in peeking = false }
    }

    @ViewBuilder private var content: some View {
        switch shell.section {
        case .page:
            if let editor = shell.editor {
                PageScreen(editor: editor).id(editor.pageID)
            } else {
                Color.clear
            }
        case .database:
            if let model = shell.databaseModel {
                DatabaseScreen(model: model).id(model.pageID)
            } else {
                Color.clear
            }
        case .locked(let id): LockedPageScreen(id: id).id(id)
        case .backups: BackupsScreen()
        case .settings: SettingsScreen()
        case .files: FilesScreen()
        case .trash: TrashScreen()
        case .calendar:
            if let host = shell.calendarSync { CalendarView(engine: host.engine).background(Tokens.paper) } else { Color.clear }
        case .templates: TemplatesScreen()
        case .tag(let id): TagScreen(id: id).id(id)
        default: HomeScreen().background(Tokens.paper)
        }
    }

    @ViewBuilder private var noticeView: some View {
        if let text = shell.busyMessage ?? shell.notice {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 9).fill(Tokens.primary))
                .padding(20)
                .onTapGesture { shell.notice = nil }
                .task(id: shell.notice) {
                    guard shell.notice != nil else { return }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    shell.notice = nil
                }
        }
    }
}

struct CrumbBar: View {
    @EnvironmentObject private var shell: ShellModel

    /// Открытая страница или база: у обеих есть путь и меню действий.
    private var openID: UUID? {
        switch shell.section {
        case .page(let id), .database(let id): return id
        default: return nil
        }
    }

    private var currentTitle: String {
        switch shell.section {
        case .page(let id), .database(let id), .locked(let id): return shell.pageTree.page(id)?.title ?? ""
        case .backups: return L("Резервные копии")
        case .settings: return L("Настройки")
        case .trash: return L("Корзина")
        case .calendar: return L("Календарь")
        case .templates: return L("Шаблоны")
        case .tag(let id): return shell.tags.first { $0.id == id }?.name ?? L("Тег")
        case .files: return L("Импорт")
        default: return L("Главная")
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            navButton("sidebar.left", shell.sidebarCollapsed ? L("Показать боковую панель (⌘\\)") : L("Скрыть боковую панель (⌘\\)"), enabled: true) { shell.toggleSidebar() }
            navButton("chevron.left", L("Назад"), enabled: !shell.backStack.isEmpty) { shell.goBack() }
            navButton("chevron.right", L("Вперёд"), enabled: !shell.forwardStack.isEmpty) { shell.goForward() }
            Button(shell.isOpen ? shell.workspaceName : AppEdition.displayName) { shell.goHome() }
                .buttonStyle(.plain)
                .foregroundColor(Tokens.muted)
            if let id = openID {
                ForEach(shell.path(of: id)) { parent in
                    Text("/").foregroundColor(Tokens.muted)
                    Button(parent.title.isEmpty ? L("Без названия") : parent.title) { shell.openPage(parent.id) }
                        .buttonStyle(.plain)
                        .foregroundColor(Tokens.muted)
                        .lineLimit(1)
                }
            }
            Text("/").foregroundColor(Tokens.muted)
            Text(currentTitle.isEmpty ? L("Без названия") : currentTitle)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer()
            // Ошибка записи видна на любом экране: уход со страницы не отменяет её.
            if openID != nil { saveIndicator } else if case .failed = shell.saveStatus { saveIndicator }
            if let id = openID {
                Menu {
                    let page = shell.pageTree.page(id)
                    Button(page?.favoriteKey != nil ? "Убрать из избранного" : "Добавить в избранное") { shell.toggleFavorite(id) }
                    if !shell.isDatabase(id) {
                        Button(page?.fullWidth == true ? "Обычная ширина" : "Во всю ширину") { shell.toggleFullWidth(id) }
                        Divider()
                        Button("Новая подстраница") { shell.createPage(parent: id) }
                    }
                    Button("Дублировать страницу") { shell.duplicatePage(id) }
                    if !shell.isDatabase(id) { Button("Сохранить как шаблон…") { shell.saveAsTemplate(id) } }
                    if !shell.isDatabase(id), let page { Button("История версий…") { shell.historyPage = page } }
                    if !shell.isDatabase(id) { Button("Экспорт в Markdown…") { shell.exportMarkdown(id) } }
                    if shell.isDatabase(id) { Button("Экспорт в CSV…") { shell.exportDatabaseCSV(page: id) } }
                    if AISettings.shared.enabled { AIExcludeMenuItem(page: id) }
                    PageLockMenuItems(page: id)
                    Divider()
                    Button("Удалить страницу") { shell.trash(id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Действия со страницей"))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 27)
        .frame(height: Tokens.crumbHeight)
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(enabled ? Tokens.ink : Tokens.muted.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    @ViewBuilder private var saveIndicator: some View {
        switch shell.saveStatus {
        case .saved:
            Text("✓ Сохранено").foregroundColor(Tokens.muted)
        case .saving:
            Text("Сохранение…").foregroundColor(Tokens.muted)
        case .failed(let message):
            HStack(spacing: 8) {
                Text("Ошибка сохранения").foregroundColor(Tokens.danger).help(message)
                Button("Повторить") { shell.retrySave() }.buttonStyle(.plain).underline()
                Button("Экспорт…") { shell.emergencyExport() }.buttonStyle(.plain).underline()
            }
        }
    }
}

/// Peek (M14): страница сбоку (около 45% ширины) или по центру поверх текущей. Esc закрывает.
struct PeekOverlay: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var editor: PageEditorModel
    let mode: ShellModel.PeekMode

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: mode == .center ? .center : .trailing) {
                // Щелчок мимо панели закрывает её, как в Notion.
                Color.black.opacity(mode == .center ? 0.18 : 0.04)
                    .contentShape(Rectangle())
                    .onTapGesture { shell.closePeek() }
                panel
                    .frame(width: mode == .center ? min(900, geo.size.width * 0.72) : max(360, geo.size.width * 0.45),
                           height: mode == .center ? geo.size.height * 0.86 : geo.size.height)
                    .background(Tokens.paper)
                    .clipShape(RoundedRectangle(cornerRadius: mode == .center ? 12 : 0))
                    .shadow(color: .black.opacity(0.18), radius: 18, x: mode == .center ? 0 : -4)
                    .transition(.move(edge: mode == .center ? .bottom : .trailing).combined(with: .opacity))
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { shell.closePeek() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(L("Закрыть (Esc)"))
                Button { shell.openPeekAsPage() } label: {
                    Label("Открыть как страницу", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .foregroundColor(Tokens.muted)
            .padding(.horizontal, 16)
            .frame(height: 40)
            Rectangle().fill(Tokens.line).frame(height: 1)
            PageScreen(editor: editor).id(editor.pageID)
        }
    }
}

