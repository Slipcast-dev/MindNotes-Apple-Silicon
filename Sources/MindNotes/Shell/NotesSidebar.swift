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

/// Рамки видимых строк дерева в системе координат панели: по ним находится строка под курсором.
struct RowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct NotesSidebar: View {
    static let treeSpace = "pageTree"
    @EnvironmentObject private var shell: ShellModel
    /// Свёрнутые страницы дерева. По умолчанию всё развёрнуто.
    @State private var collapsed: Set<UUID> = []
    /// Перетаскивание страницы внутри панели: свой жест, без системного буфера обмена.
    @State private var drag: TreeDrag?
    @State private var rowFrames: [UUID: CGRect] = [:]

    struct TreeDrag: Equatable {
        var page: UUID
        var title: String
        var location: CGPoint
        var target: UUID?
        var zone: PageTree.DropZone?
    }

    private func updateDrag(_ page: Page, at location: CGPoint) {
        var state = drag ?? TreeDrag(page: page.id, title: page.title.isEmpty ? L("Без названия") : page.title, location: location)
        state.location = location
        state.target = nil
        state.zone = nil
        if let (id, frame) = rowFrames.first(where: { $0.value.contains(location) }), id != page.id {
            let zone = PageTree.DropZone.at(fraction: Double((location.y - frame.minY) / max(frame.height, 1)), allowsInto: !shell.isDatabase(id))
            if shell.pageTree.placement(moving: page.id, onto: id, zone: zone) != nil {
                state.target = id
                state.zone = zone
            }
        }
        drag = state
    }

    private func finishDrag() {
        defer { drag = nil }
        guard let state = drag, let target = state.target, let zone = state.zone else { return }
        if shell.reorder(state.page, onto: target, zone: zone), zone == .into { collapsed.remove(target) }
    }

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
                SidebarRow(title: L("Импорт"), symbol: "square.and.arrow.down", active: shell.section == .files) { shell.goFiles() }

                if shell.isOpen {
                    SidebarRow(title: L("Новая страница"), symbol: "plus") { shell.createPage() }
                    SidebarRow(title: L("Новая папка"), symbol: "folder.badge.plus") { shell.createFolder() }
                    SidebarRow(title: L("Новая база данных"), symbol: "tablecells.badge.ellipsis") { shell.createDatabase() }
                    SidebarRow(title: L("Шаблоны"), symbol: "square.on.square", active: shell.section == .templates) { shell.goTemplates() }
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
                        // Название раздела задаёт пользователь; оно хранится в пространстве (у другого — своё или «Страницы»).
                        SidebarGroup(title: shell.pagesTitle ?? L("Страницы"))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { shell.renamePagesSection() }
                            .contextMenu {
                                Button("Переименовать раздел…") { shell.renamePagesSection() }
                                if shell.pagesTitle != nil { Button("Вернуть «Страницы»") { shell.setPagesTitle(nil) } }
                            }
                            .help(L("Двойной щелчок — переименовать раздел"))
                        ForEach(shell.pageTree.rows(collapsed: collapsed)) { row in
                            PageTreeRow(row: row, expanded: !collapsed.contains(row.id),
                                        dropZone: drag?.target == row.id ? drag?.zone : nil,
                                        isDragged: drag?.page == row.id) {
                                if collapsed.remove(row.id) == nil { collapsed.insert(row.id) }
                            }
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: RowFramesKey.self, value: [row.id: geometry.frame(in: .named(Self.treeSpace))])
                            })
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.treeSpace))
                                    .onChanged { updateDrag(row.page, at: $0.location) }
                                    .onEnded { _ in finishDrag() }
                            )
                        }

                        if !shell.tags.isEmpty {
                            SidebarGroup(title: L("Теги"))
                            ForEach(shell.tags) { tag in
                                SidebarRow(title: tag.name, symbol: "tag", active: shell.section == .tag(tag.id), tint: Tokens.swatch(tag.color)?.fg) { shell.goTag(tag.id) }
                            }
                        }
                    }

                }
                .coordinateSpace(name: Self.treeSpace)
                .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
                .overlay(alignment: .topLeading) {
                    if let drag {
                        Text(drag.title)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.card).shadow(radius: 3))
                            .offset(x: drag.location.x + 12, y: drag.location.y - 10)
                            .allowsHitTesting(false)
                    }
                }
            }

            // Внизу — служебное: корзина и настройки (резервные копии открываются из настроек).
            Rectangle().fill(Tokens.line).frame(height: 1).padding(.top, 8)
            VStack(spacing: 0) {
                if shell.isOpen {
                    SidebarRow(title: L("Корзина"), symbol: "trash", active: shell.section == .trash) { shell.goTrash() }
                }
                SidebarRow(title: L("Настройки"), symbol: "gearshape", active: shell.section == .settings || shell.section == .backups) { shell.goSettings() }
            }
            .padding(.top, 8)
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
    var dropZone: PageTree.DropZone? = nil
    var isDragged = false
    let toggle: () -> Void

    var body: some View {
        let page = row.page
        let isDatabase = shell.isDatabase(page.id)
        let inset = CGFloat(row.depth) * 14 + 10
        SidebarRow(title: page.title.isEmpty ? L("Без названия") : page.title,
                   symbol: !row.hasChildren ? (isDatabase ? "tablecells" : (page.isFolder ? "folder" : "doc.text")) : (expanded ? "chevron.down" : "chevron.right"),
                   active: shell.isOpenPage(page.id), indent: CGFloat(row.depth) * 14, emoji: row.hasChildren ? nil : page.emoji) {
            if shell.isOpenPage(page.id), row.hasChildren { toggle() } else { shell.openPage(page.id) }
        }
        .opacity(isDragged ? 0.45 : 1)
        // Куда упадёт страница: линия между строками или рамка «внутрь».
        .overlay(alignment: dropZone == .before ? .top : .bottom) {
            if dropZone == .before || dropZone == .after {
                Rectangle().fill(Tokens.accent).frame(height: 2).padding(.leading, inset)
            }
        }
        .overlay {
            if dropZone == .into { RoundedRectangle(cornerRadius: 8).stroke(Tokens.accent, lineWidth: 2) }
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
