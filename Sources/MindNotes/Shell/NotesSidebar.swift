import SwiftUI

struct SidebarRow: View {
    let title: String
    let symbol: String
    var active = false
    var indent: CGFloat = 0
    var tint: Color?
    /// Значок-emoji страницы вместо символа.
    var emoji: String?
    /// Сочетание клавиш справа, как у «Поиска».
    var badge: String? = nil
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
                    .font(.system(size: Tokens.theme == .notion ? 14 : 13, weight: active ? (Tokens.theme == .notion ? .medium : .semibold) : .regular))
                    .foregroundColor(active ? Tokens.accent : Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge, !badge.isEmpty { ShortcutBadge(text: badge) }
            }
            .padding(.vertical, Tokens.theme == .notion ? 5 : 8) // В Notion строка панели — около 28 точек.
            .padding(.leading, 10 + indent)
            .padding(.trailing, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(active || hover ? Tokens.soft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Строка панели, открывающая меню: выглядит как `SidebarRow`, справа — шеврон.
struct SidebarMenuRow<Content: View>: View {
    let title: String
    let symbol: String
    var active = false
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundColor(active ? Tokens.accent : Tokens.muted)
                Text(title)
                    .font(.system(size: Tokens.theme == .notion ? 14 : 13, weight: active ? (Tokens.theme == .notion ? .medium : .semibold) : .regular))
                    .foregroundColor(active ? Tokens.accent : Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Tokens.muted)
            }
            .padding(.vertical, Tokens.theme == .notion ? 5 : 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(active || hover ? Tokens.soft : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover = $0 }
    }
}

struct SidebarGroup: View {
    let title: String
    /// Раздел сворачивается: стрелка перед названием. nil — заголовок без стрелки.
    var collapsed: Bool? = nil
    var onToggle: (() -> Void)? = nil
    /// Над заголовком тащат страницу: она ляжет в этот раздел.
    var highlighted = false
    /// Сюда встанет перетаскиваемый раздел: линия сверху или снизу заголовка.
    var insertion: VerticalEdge? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let collapsed {
                Button { onToggle?() } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(collapsed ? "Развернуть раздел" : "Свернуть раздел"))
            }
            // В Notion заголовок раздела — мелкий, обычными буквами, без разрядки.
            Text(Tokens.theme == .notion ? title : title.uppercased())
                .font(.system(size: Tokens.theme == .notion ? 12 : 10, weight: Tokens.theme == .notion ? .medium : .semibold))
                .tracking(Tokens.theme == .notion ? 0 : 1.3)
        }
        .foregroundColor(highlighted ? Tokens.accent : Tokens.muted)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Tokens.accent.opacity(0.12) : .clear).padding(.top, 14))
        .overlay(alignment: insertion == .bottom ? .bottom : .top) {
            if insertion != nil {
                Capsule().fill(Tokens.accent).frame(height: 2).padding(.horizontal, 6).padding(.top, insertion == .top ? 12 : 0)
            }
        }
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
    /// Пункт «ИИ» виден только при включённом ИИ (ADR-0016).
    @ObservedObject private var ai = AISettings.shared
    @ObservedObject private var chat = AIChatModel.shared
    @ObservedObject private var shortcuts = ShortcutSettings.shared
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

    /// Строки дерева одного раздела: страницы верхнего уровня этого раздела и их потомки.
    @ViewBuilder private func treeRows(in section: UUID?) -> some View {
        ForEach(shell.isSectionCollapsed(section) ? [] : shell.treeRows(collapsed: collapsed.union(shell.closedLockIDs), section: section)) { row in
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
    }

    @State private var sectionDrag: SectionDrag?
    /// Свёрнут ли блок «Теги»: настройка этого Mac, не зависит от разделов страниц.
    @AppStorage("sidebar.tagsCollapsed") private var tagsCollapsed = false

    /// Заголовок стандартного раздела в кадрах строк: свой ID, не совпадающий со страницами.
    static let defaultSection = UUID(uuidString: "00000000-0000-0000-0000-00000000D5EC")!

    private var sectionHeaders: Set<UUID> { Set(shell.sections.map(\.id)).union([Self.defaultSection]) }

    private func updateDrag(_ page: Page, at location: CGPoint) {
        var state = drag ?? TreeDrag(page: page.id, title: page.title.isEmpty ? L("Без названия") : page.title, location: location)
        state.location = location
        state.target = nil
        state.zone = nil
        // Над заголовком раздела: страница ляжет в этот раздел (в начало).
        if let (id, _) = rowFrames.first(where: { sectionHeaders.contains($0.key) && $0.value.contains(location) }) {
            state.target = id
            state.zone = .into
            drag = state
            return
        }
        if let (id, frame) = rowFrames.first(where: { !sectionHeaders.contains($0.key) && $0.value.contains(location) }), id != page.id {
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
        if sectionHeaders.contains(target) {
            shell.dropPage(state.page, onSection: target == Self.defaultSection ? nil : target)
            return
        }
        if shell.reorder(state.page, onto: target, zone: zone) {
            if zone == .into { collapsed.remove(target) } else { shell.followSection(of: target, page: state.page) }
        }
    }

    private func headerID(_ slot: SectionSlot) -> UUID { slot.sectionID ?? Self.defaultSection }

    private func slot(forHeader id: UUID) -> SectionSlot { id == Self.defaultSection ? .pages : .custom(id) }

    /// Заголовок раздела: щелчок сворачивает, перетаскивание меняет порядок, правый щелчок — действия.
    @ViewBuilder private func sectionHeader(_ slot: SectionSlot) -> some View {
        let id = headerID(slot)
        let section = shell.sections.first { $0.id == slot.sectionID }
        let order = shell.sectionOrder
        SidebarGroup(title: section?.name ?? shell.pagesTitle ?? L("Страницы"), collapsed: shell.isSectionCollapsed(slot.sectionID),
                     onToggle: { shell.toggleSection(slot.sectionID) },
                     highlighted: drag?.target == id,
                     insertion: sectionDrag?.target == slot ? sectionDrag?.edge : nil)
            .opacity(sectionDrag?.moving == slot ? 0.45 : 1)
            .background(GeometryReader { g in
                Color.clear.preference(key: RowFramesKey.self, value: [id: g.frame(in: .named(Self.treeSpace))])
            })
            .contentShape(Rectangle())
            .onTapGesture { shell.toggleSection(slot.sectionID) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.treeSpace))
                    .onChanged { updateSectionDrag(slot, at: $0.location) }
                    .onEnded { _ in finishSectionDrag() }
            )
            .contextMenu {
                if let section {
                    Button("Новая страница в разделе") { shell.createPage(inSection: section.id) }
                    Button("Переименовать раздел…") { shell.renameSection(section) }
                } else {
                    Button("Переименовать раздел…") { shell.renamePagesSection() }
                    if shell.pagesTitle != nil { Button("Вернуть «Страницы»") { shell.setPagesTitle(nil) } }
                }
                Button("Выше") { shell.moveSection(slot, by: -1) }.disabled(order.first == slot)
                Button("Ниже") { shell.moveSection(slot, by: 1) }.disabled(order.last == slot)
                if let section {
                    Divider()
                    Button("Удалить раздел…") { shell.deleteSection(section) }
                }
            }
            .help(L("Щелчок — свернуть или развернуть; перетащите, чтобы изменить порядок; правый щелчок — действия"))
    }

    /// Перетаскивание раздела: цель — заголовок другого раздела под курсором.
    private struct SectionDrag: Equatable {
        var moving: SectionSlot
        var target: SectionSlot?
        var edge: VerticalEdge?
    }

    private func updateSectionDrag(_ slot: SectionSlot, at location: CGPoint) {
        var state = sectionDrag ?? SectionDrag(moving: slot)
        state.target = nil
        state.edge = nil
        let order = shell.sectionOrder
        if let (id, _) = rowFrames.first(where: { sectionHeaders.contains($0.key) && $0.value.contains(location) }) {
            let target = self.slot(forHeader: id)
            if target != slot, let from = order.firstIndex(of: slot), let to = order.firstIndex(of: target) {
                state.target = target
                state.edge = from < to ? .bottom : .top
            }
        }
        sectionDrag = state
    }

    private func finishSectionDrag() {
        defer { sectionDrag = nil }
        guard let state = sectionDrag, let target = state.target else { return }
        shell.moveSection(state.moving, onto: target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    BrandLogo()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shell.isOpen ? shell.workspaceName : AppEdition.displayName).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        if !shell.isOpen { Text("Пространство не открыто").font(.system(size: 11)).foregroundColor(Tokens.muted) }
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
                            ShortcutBadge(text: shortcuts.display("nav.search"))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // «ИИ» — между «Поиском» и «Главной», как в Notion.
                if shell.isOpen, ai.enabled {
                    SidebarRow(title: "Notes AI", symbol: "sparkles", active: chat.isOpen, tint: AIStyle.tint, badge: shortcuts.display("ai.chat")) { chat.toggle() }
                }
                // Отступ отделяет «Поиск» и «Notes AI» от разделов.
                SidebarRow(title: L("Главная"), symbol: "house", active: shell.section == .home) { shell.goHome() }
                    .padding(.top, 10)
                if shell.isOpen {
                    SidebarRow(title: L("Календарь"), symbol: "calendar", active: shell.section == .calendar) { shell.goCalendar() }
                    SidebarRow(title: L("Шаблоны"), symbol: "square.on.square", active: shell.section == .templates) { shell.goTemplates() }

                    Divider().padding(.horizontal, 10).padding(.vertical, 4)

                    // Всё создание — в одном меню: навигация сверху, действие снизу.
                    SidebarMenuRow(title: L("Создать"), symbol: "plus", active: shell.section == .files) {
                        Button { shell.createPage() } label: { Label(L("Страница"), systemImage: "doc") }
                        Button { shell.createFolder() } label: { Label(L("Папка"), systemImage: "folder.badge.plus") }
                        Button { shell.createDatabase() } label: { Label(L("База данных"), systemImage: "tablecells.badge.ellipsis") }
                        Divider()
                        Button { shell.goFiles() } label: { Label(L("Импортировать…"), systemImage: "square.and.arrow.down") }
                    }
                } else {
                    // Без открытого пространства создавать некуда — остаётся только импорт.
                    SidebarRow(title: L("Импорт"), symbol: "square.and.arrow.down", active: shell.section == .files) { shell.goFiles() }
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
                        // Разделы в порядке пользователя: «Страницы» и свои (схема v9) перетаскиваются за заголовок.
                        ForEach(shell.sectionOrder, id: \.self) { slot in
                            sectionHeader(slot)
                            treeRows(in: slot.sectionID)
                        }
                        SidebarRow(title: L("Новый раздел"), symbol: "plus.rectangle.on.folder") { shell.addSection() }
                            .padding(.top, 4)

                        // Теги — отдельный блок, не раздел страниц: не перетаскивается и сворачивается сам по себе.
                        if !shell.tags.isEmpty {
                            Divider().padding(.horizontal, 10).padding(.top, 12)
                            SidebarGroup(title: L("Теги"), collapsed: tagsCollapsed, onToggle: { tagsCollapsed.toggle() })
                                .contentShape(Rectangle())
                                .onTapGesture { tagsCollapsed.toggle() }
                                .help(L("Щелчок — свернуть или развернуть"))
                            if !tagsCollapsed {
                                ForEach(shell.tags) { tag in
                                    SidebarRow(title: tag.name, symbol: "tag", active: shell.section == .tag(tag.id), tint: Tokens.swatch(tag.color)?.fg) { shell.goTag(tag.id) }
                                }
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
    @State private var hovering = false

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
        // Стрелка раскрытия нажимается отдельно от строки, как в Notion.
        .overlay(alignment: .leading) {
            if row.hasChildren {
                Color.clear.frame(width: 22, height: 26).contentShape(Rectangle())
                    .padding(.leading, inset - 4)
                    .onTapGesture { toggle() }
                    .accessibilityLabel(Text(expanded ? "Свернуть" : "Развернуть"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        // При наведении: «…» — действия со страницей, «+» — новая подстраница.
        .overlay(alignment: .trailing) {
            if hovering && !isDragged {
                HStack(spacing: 2) {
                    Menu { actions(page, isDatabase: isDatabase) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("Действия со страницей"))
                    if !isDatabase {
                        Button { shell.createPage(parent: page.id) } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("Новая подстраница"))
                    }
                }
                .foregroundColor(Tokens.muted)
                .padding(.trailing, 6)
            }
        }
        .overlay(alignment: .trailing) {
            if !hovering, shell.hasOwnLock(page.id) {
                Image(systemName: shell.isClosed(page.id) ? "lock.fill" : "lock.open")
                    .font(.system(size: 10)).foregroundColor(Tokens.muted).padding(.trailing, 10)
                    .accessibilityLabel(Text("Под паролем"))
            }
        }
        .onHover { hovering = $0 }
        // Куда упадёт страница: линия между строками или рамка «внутрь».
        .overlay(alignment: dropZone == .before ? .top : .bottom) {
            if dropZone == .before || dropZone == .after {
                Rectangle().fill(Tokens.accent).frame(height: 2).padding(.leading, inset)
            }
        }
        .overlay {
            if dropZone == .into { RoundedRectangle(cornerRadius: 8).stroke(Tokens.accent, lineWidth: 2) }
        }
        .contextMenu { actions(page, isDatabase: isDatabase) }
    }

    /// Одни и те же действия в меню «…» и по правой кнопке.
    @ViewBuilder private func actions(_ page: Page, isDatabase: Bool) -> some View {
        Button("Переименовать…") {
            if let name = PromptAlert.ask(L("Название страницы"), value: page.title) { shell.rename(page.id, to: name) }
        }
                if !isDatabase {
                    Button("Новая подстраница") { shell.createPage(parent: page.id) }
                    Button("Новая папка") { shell.createFolder(parent: page.id) }
                    Button("Новая база данных") { shell.createDatabase(parent: page.id) }
                }
                Button(page.favoriteKey != nil ? "Убрать из избранного" : "Добавить в избранное") { shell.toggleFavorite(page.id) }
                Button("Дублировать страницу") { shell.duplicatePage(page.id) }
                if !isDatabase { Button("Сохранить как шаблон…") { shell.saveAsTemplate(page.id) } }
                Button("Переместить в…") { shell.pageToMove = page }
                if page.parentID == nil, !shell.sections.isEmpty {
                    Menu("В раздел") {
                        Button(shell.pagesTitle ?? L("Страницы")) { shell.moveToSection(page.id, nil) }
                        ForEach(shell.sections) { section in Button(section.name) { shell.moveToSection(page.id, section.id) } }
                    }
                }
                if AISettings.shared.enabled { AIExcludeMenuItem(page: page.id) }
                PageLockMenuItems(page: page.id)
                Divider()
                Button("Удалить") { shell.trash(page.id) }
    }
}

/// Сочетание клавиш в рамке справа от пункта панели.
struct ShortcutBadge: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Tokens.muted)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Tokens.line))
        }
    }
}
