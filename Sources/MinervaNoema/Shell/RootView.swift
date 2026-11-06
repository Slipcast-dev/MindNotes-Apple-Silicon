import AppKit
import SwiftUI

/// Корень окна. Боковая панель общая; файловый режим живёт в области содержимого.
struct RootView: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var prefs: AppPreferences

    var body: some View {
        NotesLayout()
            .id(prefs.theme) // Токены читаются при построении: смена темы перестраивает дерево.
            .sheet(isPresented: $shell.showsLookSheet) { WorkspaceLookSheet() }
            .sheet(isPresented: $shell.showsSearch) { SearchSheet() }
            .background(WindowChrome(theme: prefs.theme))
            .background(WindowFrameSaver(name: "MinervaNoemaMainWindow"))
            .preferredColorScheme(prefs.isDark ? .dark : .light)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Text(AppEdition.displayName).font(.system(size: 13, weight: .semibold))
                }
                ToolbarItem(placement: .automatic) { Spacer() }
                ToolbarItem(placement: .automatic) {
                    Button { prefs.isDark.toggle() } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .buttonStyle(.plain)
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
                        content
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
        case .database:
            if let model = shell.databaseModel {
                DatabaseScreen(model: model).id(model.pageID)
            } else {
                Color.clear
            }
        case .backups: BackupsScreen()
        case .settings: SettingsScreen()
        case .files: FilesScreen()
        case .trash: TrashScreen()
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
        case .page(let id), .database(let id): return shell.pages.first { $0.id == id }?.title ?? ""
        case .backups: return L("Резервные копии")
        case .settings: return L("Настройки")
        case .trash: return L("Корзина")
        case .tag(let id): return shell.tags.first { $0.id == id }?.name ?? L("Тег")
        case .files: return L("Файлы")
        default: return L("Главная")
        }
    }

    var body: some View {
        HStack(spacing: 9) {
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
                    let page = shell.pages.first { $0.id == id }
                    Button(page?.favoriteKey != nil ? "Убрать из избранного" : "Добавить в избранное") { shell.toggleFavorite(id) }
                    if !shell.isDatabase(id) {
                        Button(page?.fullWidth == true ? "Обычная ширина" : "Во всю ширину") { shell.toggleFullWidth(id) }
                        Divider()
                        Button("Новая подстраница") { shell.createPage(parent: id) }
                    }
                    Button("Дублировать страницу") { shell.duplicatePage(id) }
                    Divider()
                    Button("Удалить страницу") { shell.trash(id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Действия со страницей"))
            } else if shell.section != .settings {
                Button("Настройки") { shell.goSettings() }
                    .buttonStyle(.plain)
                    .foregroundColor(Tokens.muted)
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
