import AppKit
import SwiftUI

/// Корень окна. Боковая панель общая; файловый режим живёт в области содержимого.
struct RootView: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: Preferences

    private var inFiles: Bool { shell.section == .files }

    var body: some View {
        NotesLayout()
            .background(WindowChrome(opaque: !inFiles || !prefs.glassEnabled))
            .background(WindowFrameSaver(name: "GrizzlyNotesMainWindow"))
            .preferredColorScheme(prefs.theme.isDark ? .dark : .light)
            // Файл, открытый из Finder, всегда попадает в раздел «Файлы» без импорта.
            .onReceive(NotificationCenter.default.publisher(for: .openFileSettings)) { _ in shell.goFileSettings() }
            .onReceive(state.$documents) { docs in
                if !docs.isEmpty && !inFiles { shell.goFiles() }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Text(AppEdition.displayName).font(.system(size: 13, weight: .semibold))
                }
                ToolbarItem(placement: .automatic) { Spacer() }
                ToolbarItem(placement: .automatic) {
                    Button { prefs.appearance = prefs.theme.isDark ? .light : .dark } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .buttonStyle(.hover)
                    .help("Переключить тему")
                    .accessibilityLabel(Text("Переключить тему"))
                }
            }
            .alert("Ошибка", isPresented: Binding(get: { shell.errorMessage != nil }, set: { if !$0 { shell.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shell.errorMessage ?? "")
            }
    }
}

/// Заголовок окна в цвет бумаги. Эффект стекла файлового режима включается в его настройках.
struct WindowChrome: NSViewRepresentable {
    let opaque: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if opaque {
                window.isOpaque = true
                window.backgroundColor = Tokens.paperNS
            }
        }
    }
}

/// Раскладка пространства по макету: боковая панель 240, хлебные крошки 54, содержимое.
struct NotesLayout: View {
    @EnvironmentObject private var shell: ShellModel

    var body: some View {
        Group {
            if shell.section == .welcome {
                WelcomeScreen()
            } else {
                HStack(spacing: 0) {
                    NotesSidebar()
                        .frame(width: Tokens.sidebarWidth)
                    Rectangle().fill(Tokens.line).frame(width: 1)
                    VStack(spacing: 0) {
                        CrumbBar()
                        Rectangle().fill(Tokens.line).frame(height: 1)
                        ZStack {
                            // Смонтирован после первого входа и дальше скрыт: отмена и прокрутка файлов живут в его видах.
                            if shell.filesMounted {
                                ContentView()
                                    .opacity(shell.section == .files ? 1 : 0)
                                    .allowsHitTesting(shell.section == .files)
                                    .accessibilityHidden(shell.section != .files)
                            }
                            if shell.section != .files { content }
                        }
                    }
                }
            }
        }
        .foregroundColor(Tokens.ink)
        .background(Tokens.paper)
        .overlay(Rectangle().fill(Tokens.line).frame(height: 1), alignment: .top)
        .overlay(alignment: .bottomTrailing) { noticeView }
    }

    @ViewBuilder private var content: some View {
        switch shell.section {
        case .page:
            if let editor = shell.editor {
                PageScreen(editor: editor).id(editor.pageID)
            } else {
                Color.clear
            }
        case .backups: BackupsScreen()
        case .settings: SettingsScreen()
        case .fileSettings: FileSettingsScreen()
        case .trash: TrashScreen()
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

/// Управление открытым файлом: живёт в строке раздела, а не в заголовке окна.
struct FileControls: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            if !state.documents.isEmpty {
                Picker("Режим", selection: $state.mode) {
                    Text("Текст").tag(ReadMode.user)
                    Text("Разметка").tag(ReadMode.developer)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help("Текст: без кода форматирования. Разметка: исходный текст с подсветкой и номерами строк.")
                Button { state.toggleSplit() } label: { Image(systemName: state.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1") }
                    .buttonStyle(.hover)
                    .help("Два файла рядом (⌘\\)")
                Button { state.showFind() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.hover)
                    .help("Найти (⌘F)")
                BookmarksButton()
            }
            Button { shell.showsLibrary.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.hover)
                .help("Библиотека файлов")
                .accessibilityLabel(Text("Библиотека файлов"))
        }
    }
}

struct CrumbBar: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var state: AppState

    private var currentTitle: String {
        switch shell.section {
        case .page(let id): return shell.pages.first { $0.id == id }?.title ?? ""
        case .backups: return L("Резервные копии")
        case .settings: return L("Настройки")
        case .trash: return L("Корзина")
        case .files: return state.current?.name ?? L("Файлы")
        case .fileSettings: return L("Настройки файлов")
        default: return L("Главная")
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Button(shell.isOpen ? shell.workspaceName : AppEdition.displayName) { shell.goHome() }
                .buttonStyle(.plain)
                .foregroundColor(Tokens.muted)
            Text("/").foregroundColor(Tokens.muted)
            Text(currentTitle.isEmpty ? L("Без названия") : currentTitle)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer()
            // Ошибка записи видна на любом экране: уход со страницы не отменяет её.
            if case .page = shell.section { saveIndicator } else if case .failed = shell.saveStatus { saveIndicator }
            if case .page(let id) = shell.section {
                Menu {
                    Button("Новая подстраница") { shell.createPage(parent: id) }
                    Divider()
                    Button("Удалить страницу") { shell.trash(id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Действия со страницей"))
            } else if shell.section == .files {
                FileControls()
            } else if shell.section != .settings && shell.section != .fileSettings {
                Button("Настройки") { shell.goSettings() }
                    .buttonStyle(.plain)
                    .foregroundColor(Tokens.muted)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 27)
        .frame(height: Tokens.crumbHeight)
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
