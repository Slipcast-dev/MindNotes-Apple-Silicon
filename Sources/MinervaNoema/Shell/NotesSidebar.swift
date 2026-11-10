import SwiftUI

struct SidebarRow: View {
    let title: String
    let symbol: String
    var active = false
    var indent: CGFloat = 0
    var tint: Color?
    /// Значок-emoji страницы вместо символа.
    var emoji: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let emoji {
                    Text(emoji).font(.system(size: 13)).frame(width: 16)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .frame(width: 16)
                        .foregroundColor(tint ?? (active ? Tokens.accent : Tokens.muted))
                }
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? Tokens.accent : Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.leading, 10 + indent)
            .padding(.trailing, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(active || hover ? Tokens.soft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SidebarGroup: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.3)
            .foregroundColor(Tokens.muted)
            .padding(.top, 20)
            .padding(.bottom, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NotesSidebar: View {
    @EnvironmentObject private var shell: ShellModel
    /// Свёрнутые страницы дерева. По умолчанию всё развёрнуто.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    BrandLogo()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shell.isOpen ? shell.workspaceName : AppEdition.displayName).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        Text(shell.isOpen ? "Локально на этом Mac" : "Пространство не открыто").font(.system(size: 11)).foregroundColor(Tokens.muted)
                    }
                }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Меню стирает оформление своей подписи, поэтому прозрачное меню лежит поверх.
            .overlay {
                Menu {
                    ForEach(shell.knownWorkspaces) { item in
                        Button { shell.switchWorkspace(item) } label: {
                            if shell.isCurrent(item) { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                        }
                        .disabled(!item.exists)
                    }
                    if !shell.knownWorkspaces.isEmpty { Divider() }
                    if shell.isOpen {
                        Button("Настроить пространство…") { shell.showsLookSheet = true }
                        Divider()
                    }
                    Button("Создать другое пространство…") { shell.presentCreate() }
                    Button("Открыть другое пространство…") { shell.presentOpen() }
                    Divider()
                    if shell.isOpen { Button("Закрыть пространство") { shell.closeWorkspace() } }
                } label: { Color.clear }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .opacity(0.02)
                .accessibilityLabel(Text("Меню пространства"))
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 15)

            // Навигация и создание закреплены: список страниц не сдвигает их, сколько бы страниц ни было.
            VStack(alignment: .leading, spacing: 0) {
                if shell.isOpen {
                    Button { shell.showsSearch = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).frame(width: 16).foregroundColor(Tokens.muted)
                            Text("Поиск").font(.system(size: 13))
                            Spacer()
                            Text("⌘K")
                                .font(.system(size: 11))
                                .foregroundColor(Tokens.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Tokens.line))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                SidebarRow(title: L("Главная"), symbol: "house", active: shell.section == .home) { shell.goHome() }
                SidebarRow(title: L("Файлы"), symbol: "doc", active: shell.section == .files) { shell.goFiles() }

                if shell.isOpen {
                    SidebarRow(title: L("Новая страница"), symbol: "plus") { shell.createPage() }
                    SidebarRow(title: L("Новая папка"), symbol: "folder.badge.plus") { shell.createFolder() }
                    SidebarRow(title: L("Новая база данных"), symbol: "tablecells.badge.ellipsis") { shell.createDatabase() }
                }
            }

            ScrollView(showsIndicators: false) {
                // Лениво и плоско: на больших пространствах строятся только строки на экране.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shell.isOpen, !shell.favorites.isEmpty {
                        SidebarGroup(title: L("Избранное"))
                        ForEach(shell.favorites) { page in
                            SidebarRow(title: page.title.isEmpty ? L("Без названия") : page.title, symbol: page.isFolder ? "folder" : (shell.isDatabase(page.id) ? "tablecells" : "star"), active: shell.isOpenPage(page.id), emoji: page.emoji) { shell.openPage(page.id) }
                        }
                    }
                    if shell.isOpen {
                        SidebarGroup(title: L("Страницы"))
                        ForEach(shell.pageTree.rows(collapsed: collapsed)) { row in
                            PageTreeRow(row: row, expanded: !collapsed.contains(row.id)) {
                                if collapsed.remove(row.id) == nil { collapsed.insert(row.id) }
                            }
                        }

                        if !shell.tags.isEmpty {
                            SidebarGroup(title: L("Теги"))
                            ForEach(shell.tags) { tag in
                                SidebarRow(title: tag.name, symbol: "tag", active: shell.section == .tag(tag.id), tint: Tokens.swatch(tag.color)?.fg) { shell.goTag(tag.id) }
                            }
                        }
                    }

                    SidebarGroup(title: L("Пространство"))
                    if shell.isOpen {
                        SidebarRow(title: L("Шаблоны"), symbol: "square.on.square", active: shell.section == .templates) { shell.goTemplates() }
                        SidebarRow(title: L("Импорт"), symbol: "square.and.arrow.down") { shell.presentImport() }
                        SidebarRow(title: L("Корзина"), symbol: "trash", active: shell.section == .trash) { shell.goTrash() }
                    }
                    SidebarRow(title: L("Настройки"), symbol: "gearshape", active: shell.section == .settings) { shell.goSettings() }
                }
            }

            Rectangle().fill(Tokens.line).frame(height: 1).padding(.top, 8)
            if shell.isOpen {
                SidebarRow(title: L("Резервные копии"), symbol: "arrow.clockwise", active: shell.section == .backups) { shell.goBackups() }
                    .padding(.top, 8)
            }
            HStack(spacing: 6) {
                Circle().fill(Tokens.muted).frame(width: 8, height: 8)
                Text("Локальный режим").font(.system(size: 11)).foregroundColor(Tokens.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 17)
        .background(Tokens.side)
    }
}

/// Строка дерева страниц с отступом по вложенности.
struct PageTreeRow: View {
    @EnvironmentObject private var shell: ShellModel
    let row: PageTree.Row
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let page = row.page
        let isDatabase = shell.isDatabase(page.id)
        SidebarRow(title: page.title.isEmpty ? L("Без названия") : page.title,
                   symbol: !row.hasChildren ? (isDatabase ? "tablecells" : (page.isFolder ? "folder" : "doc.text")) : (expanded ? "chevron.down" : "chevron.right"),
                   active: shell.isOpenPage(page.id), indent: CGFloat(row.depth) * 14, emoji: row.hasChildren ? nil : page.emoji) {
            if shell.isOpenPage(page.id), row.hasChildren { toggle() } else { shell.openPage(page.id) }
        }
        .contextMenu {
            if !isDatabase {
                Button("Новая подстраница") { shell.createPage(parent: page.id) }
                Button("Новая папка") { shell.createFolder(parent: page.id) }
                Button("Новая база данных") { shell.createDatabase(parent: page.id) }
            }
            Button(page.favoriteKey != nil ? "Убрать из избранного" : "Добавить в избранное") { shell.toggleFavorite(page.id) }
            Button("Дублировать страницу") { shell.duplicatePage(page.id) }
            if !isDatabase { Button("Сохранить как шаблон…") { shell.saveAsTemplate(page.id) } }
            Button("Переместить в…") { shell.pageToMove = page }
            Divider()
            Button("Удалить") { shell.trash(page.id) }
        }
    }
}
