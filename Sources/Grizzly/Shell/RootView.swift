import AppKit
import SwiftUI

/// Корень окна. Боковая панель общая; файловый режим живёт в области содержимого.
struct RootView: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var prefs: AppPreferences

    var body: some View {
        NotesLayout()
            .background(WindowChrome())
            .background(WindowFrameSaver(name: "GrizzlyNotesMainWindow"))
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
        case .backups: BackupsScreen()
        case .settings: SettingsScreen()
        case .files: FilesScreen()
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

struct CrumbBar: View {
    @EnvironmentObject private var shell: ShellModel

    private var currentTitle: String {
        switch shell.section {
        case .page(let id): return shell.pages.first { $0.id == id }?.title ?? ""
        case .backups: return L("Резервные копии")
        case .settings: return L("Настройки")
        case .trash: return L("Корзина")
        case .files: return L("Файлы")
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
