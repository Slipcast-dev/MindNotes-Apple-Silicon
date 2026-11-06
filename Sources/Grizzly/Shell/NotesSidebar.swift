import SwiftUI

struct SidebarRow: View {
    let title: String
    let symbol: String
    var active = false
    var indent: CGFloat = 0
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundColor(active ? Tokens.accent : Tokens.muted)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 35, height: 35)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Tokens.logo))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shell.isOpen ? shell.workspaceName : AppEdition.displayName).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        Text(shell.isOpen ? "Локально на этом Mac" : "Пространство не открыто").font(.system(size: 11)).foregroundColor(Tokens.muted)
                    }
                }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Меню стирает оформление своей подписи, поэтому прозрачное меню лежит поверх.
            .overlay {
                Menu {
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SidebarRow(title: L("Главная"), symbol: "house", active: shell.section == .home) { shell.goHome() }
                    SidebarRow(title: L("Файлы"), symbol: "doc", active: shell.section == .files) { shell.goFiles() }

                    if shell.isOpen {
                        SidebarGroup(title: L("Страницы"))
                        ForEach(shell.children(of: nil)) { PageTreeRow(page: $0, depth: 0) }
                        SidebarRow(title: L("Новая страница"), symbol: "plus") { shell.createPage() }
                        SidebarRow(title: L("Новая папка"), symbol: "folder.badge.plus") { shell.createFolder() }
                    }

                    SidebarGroup(title: L("Пространство"))
                    if shell.isOpen {
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

/// Строка дерева страниц с вложенностью.
struct PageTreeRow: View {
    @EnvironmentObject private var shell: ShellModel
    let page: Page
    let depth: Int
    @State private var expanded = true

    var body: some View {
        let kids = shell.children(of: page.id)
        VStack(alignment: .leading, spacing: 0) {
            SidebarRow(title: page.title.isEmpty ? L("Без названия") : page.title,
                       symbol: kids.isEmpty ? (page.isFolder ? "folder" : "doc.text") : (expanded ? "chevron.down" : "chevron.right"),
                       active: shell.section == .page(page.id), indent: CGFloat(depth) * 14) {
                if shell.section == .page(page.id), !kids.isEmpty { expanded.toggle() } else { shell.openPage(page.id) }
            }
            .contextMenu {
                Button("Новая подстраница") { shell.createPage(parent: page.id) }
                Button("Новая папка") { shell.createFolder(parent: page.id) }
                Menu("Переместить") {
                    if page.parentID != nil { Button("В корень") { shell.move(page.id, toParent: nil) } }
                    ForEach(shell.moveTargets(for: page.id).filter { $0.id != page.parentID }) { target in
                        Button(target.title.isEmpty ? L("Без названия") : target.title) { shell.move(page.id, toParent: target.id) }
                    }
                }
                Divider()
                Button("Удалить") { shell.trash(page.id) }
            }
            if expanded {
                ForEach(kids) { PageTreeRow(page: $0, depth: depth + 1) }
            }
        }
    }
}
