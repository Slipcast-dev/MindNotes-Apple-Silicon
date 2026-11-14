import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @State private var coverHover = false

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if shell.look.coverKind != .none {
                    CoverView()
                        .overlay(alignment: .topTrailing) {
                            Button("Настроить") { shell.showsLookSheet = true }
                                .buttonStyle(NotesButtonStyle())
                                .opacity(coverHover ? 1 : 0)
                                .padding(12)
                        }
                        .onHover { coverHover = $0 }
                        .padding(.bottom, 26)
                } else {
                    Button { shell.showsLookSheet = true } label: { Label("Добавить обложку", systemImage: "photo") }
                        .buttonStyle(NotesButtonStyle(kind: .plain))
                        .padding(.bottom, 10)
                }
                Eyebrow(text: dateLine)
                ScreenTitle(text: shell.workspaceName).padding(.top, 8).padding(.bottom, 9)
                Text("Заметки, проекты и задачи — в одном месте.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                Button { shell.createPage() } label: { Label("Новая страница", systemImage: "plus") }
                    .buttonStyle(NotesButtonStyle(kind: .primary))

                if !shell.quickCards.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        sectionTitle(L("Быстрый доступ"))
                        quickMenu
                        Spacer()
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13, alignment: .top), count: 3), alignment: .leading, spacing: 13) {
                        ForEach(shell.quickCards) { card in
                            Group {
                                if let page = card.page {
                                    QuickCard(page: page, kids: shell.children(of: page.id).count, cover: shell.image(for: page.coverAssetID),
                                              kind: kindLabel(page), pinned: card.pinned) { shell.openPage(page.id) }
                                        .onAppear { if let asset = page.coverAssetID { shell.loadImage(asset: asset) } }
                                } else {
                                    EmptyQuickCard { shell.quickPickerSlot = .init(slot: card.slot) }
                                }
                            }
                            .contextMenu { cardMenu(card) }
                        }
                    }
                }
                if !shell.recent.isEmpty {
                    sectionTitle(L("Недавние"))
                    VStack(spacing: 0) {
                        ForEach(shell.recent) { page in
                            RecentRow(page: page, parents: shell.path(of: page.id).map(\.title)) { shell.openPage(page.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
        // Частота открытий меняется при каждом переходе: карточки пересчитываются, когда главная снова видна.
        .onAppear { shell.refreshQuickAccess() }
        .sheet(item: $shell.quickPickerSlot) { target in QuickPickerSheet(slot: target.slot) }
        .onChange(of: shell.pages) { _, _ in shell.refreshQuickAccess() }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 10)
    }

    /// Правый щелчок по карточке: выбрать, что на ней будет, закрепить, переставить или вернуть автоматический выбор.
    @ViewBuilder private func cardMenu(_ card: ShellModel.QuickCardItem) -> some View {
        Button("Выбрать папку, страницу или базу…") { shell.quickPickerSlot = .init(slot: card.slot) }
        if let page = card.page {
            if card.pinned {
                Button("Выбирать автоматически") { shell.setQuickSlot(card.slot, nil) }
            } else {
                Button("Закрепить здесь") { shell.setQuickSlot(card.slot, page.id) }
            }
            Divider()
            Button("Левее") { shell.swapQuickSlot(card.slot, by: -1) }.disabled(card.slot == 0)
            Button("Правее") { shell.swapQuickSlot(card.slot, by: 1) }.disabled(card.slot >= shell.quickCards.count - 1)
        }
    }

    private func kindLabel(_ page: Page) -> String? {
        if shell.isDatabase(page.id) { return L("База данных") }
        if page.isFolder { return L("Папка") }
        return nil
    }

    /// Настройки «Быстрого доступа»: сколько карточек и как он выбирает страницы.
    private var quickMenu: some View {
        Menu {
            Picker("Карточек", selection: Binding(get: { shell.quickAccess.count }, set: { shell.setQuickCount($0) })) {
                ForEach(QuickAccessSettings.allowedCounts, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Text("Закреплённые карточки стоят на своих местах, остальные — страницы, которые вы чаще открываете")
            Text("Правый щелчок по карточке — выбрать, что на ней")
        } label: {
            Image(systemName: "ellipsis").foregroundColor(Tokens.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Настроить быстрый доступ"))
    }
}

struct QuickCard: View {
    let page: Page
    let kids: Int
    /// Обложка страницы сверху карточки; без обложки — мягкий фон темы той же высоты, чтобы карточки стояли ровно.
    var cover: NSImage? = nil
    /// «Папка» или «База данных» вместо числа подстраниц; nil — обычная страница.
    var kind: String? = nil
    /// Закреплена пользователем: значок булавки в углу.
    var pinned = false
    let action: () -> Void
    @State private var hover = false

    private static let coverHeight: CGFloat = 96
    private static let iconSize: CGFloat = 40

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title.isEmpty ? L("Без названия") : page.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Tokens.ink)
                        .lineLimit(1)
                    Text(kind.map { kids == 0 ? $0 : "\($0) · \(String(format: L("Подстраниц: %d"), kids))" } ?? (kids == 0 ? L("Страница") : String(format: L("Подстраниц: %d"), kids)))
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.muted)
                }
                .padding(.horizontal, 16)
                .padding(.top, Self.iconSize / 2 + 10) // Место под значок, наполовину заходящий на обложку.
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) { icon.padding(.leading, 16).padding(.top, Self.coverHeight - Self.iconSize / 2) }
            .overlay(alignment: .topTrailing) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Tokens.muted)
                        .padding(7)
                        .background(Circle().fill(Tokens.card.opacity(0.9)))
                        .padding(10)
                        .help(L("Закреплено"))
                }
            }
            .background(Tokens.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tokens.line.opacity(hover ? 0.4 : 1)))
            .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 14 : 4, y: hover ? 6 : 1)
            .scaleEffect(hover ? 1.012 : 1)
            .animation(.easeOut(duration: 0.18), value: hover)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Text(page.title.isEmpty ? L("Без названия") : page.title))
    }

    @ViewBuilder private var header: some View {
        ZStack {
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(hover ? 1.04 : 1)
                    .animation(.easeOut(duration: 0.3), value: hover)
            } else {
                LinearGradient(colors: [Tokens.soft, Tokens.soft.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.coverHeight)
        .clipped()
    }

    /// Значок страницы на границе обложки: emoji страницы или символ документа.
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tokens.card)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            if let emoji = page.emoji {
                Text(emoji).font(.system(size: 20))
            } else {
                Image(systemName: page.isFolder ? "folder" : "doc.text")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Tokens.muted)
            }
        }
        .frame(width: Self.iconSize, height: Self.iconSize)
    }
}

struct RecentRow: View {
    let page: Page
    let parents: [String]
    let action: () -> Void

    private var subtitle: String {
        let when = page.lastOpenedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        let relative = f.localizedString(for: when, relativeTo: Date())
        return (parents + [relative]).joined(separator: parents.isEmpty ? "" : " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.soft))
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title.isEmpty ? L("Без названия") : page.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1)
            }
            Spacer()
            Button("Открыть", action: action).buttonStyle(NotesButtonStyle(kind: .plain))
        }
        .padding(.vertical, 11)
    }
}

/// Пустое место «Быстрого доступа»: страниц для него не нашлось — его можно занять самому.
struct EmptyQuickCard: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 18))
                Text("Выбрать…").font(.system(size: 13))
            }
            .foregroundColor(Tokens.muted)
            .frame(maxWidth: .infinity, minHeight: 176)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Tokens.soft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Text("Выбрать страницу для быстрого доступа"))
    }
}

/// Выбор папки, страницы или базы для места карточки: поиск и список с типом и путём.
struct QuickPickerSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    let slot: Int
    @State private var query = ""
    @State private var filter = 0

    private func kind(_ page: Page) -> Int { shell.isDatabase(page.id) ? 3 : page.isFolder ? 1 : 2 }

    private var visible: [Page] {
        let key = SearchText.normalize(query.trimmingCharacters(in: .whitespaces))
        return shell.quickChoices
            .filter { filter == 0 || kind($0) == filter }
            .filter { key.isEmpty || SearchText.normalize($0.title).contains(key) }
            .sorted { a, b in
                // Без поиска — сначала то, что открывали недавно.
                if key.isEmpty, (a.lastOpenedAt ?? 0) != (b.lastOpenedAt ?? 0) { return (a.lastOpenedAt ?? 0) > (b.lastOpenedAt ?? 0) }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Что показать в карточке?").font(.system(size: 15, weight: .semibold)).padding([.horizontal, .top], 16)
            TextField(L("Найти папку, страницу или базу"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            Picker("", selection: $filter) {
                Text("Все").tag(0)
                Text("Папки").tag(1)
                Text("Страницы").tag(2)
                Text("Базы").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Rectangle().fill(Tokens.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { page in row(page) }
                    if visible.isEmpty {
                        Text("Ничего не найдено. Попробуйте другой запрос.")
                            .foregroundColor(Tokens.muted)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                .padding(8)
            }
            .frame(height: 340)
            Rectangle().fill(Tokens.line).frame(height: 1)
            HStack {
                if shell.quickAccess.slots.indices.contains(slot), shell.quickAccess.slots[slot] != nil {
                    Button("Выбирать автоматически") { shell.setQuickSlot(slot, nil); dismiss() }
                        .buttonStyle(NotesButtonStyle(kind: .plain))
                }
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(NotesButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 500)
        .background(Tokens.paper)
    }

    private func row(_ page: Page) -> some View {
        let k = kind(page)
        let path = shell.path(of: page.id).dropLast().map(\.title).joined(separator: " / ")
        return Button { shell.setQuickSlot(slot, page.id); dismiss() } label: {
            HStack(spacing: 10) {
                Group {
                    if let emoji = page.emoji { Text(emoji) } else {
                        Image(systemName: k == 3 ? "tablecells" : k == 1 ? "folder" : "doc.text").foregroundColor(Tokens.muted)
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title.isEmpty ? L("Без названия") : page.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !path.isEmpty { Text(path).font(.system(size: 11)).foregroundColor(Tokens.muted).lineLimit(1) }
                }
                Spacer()
                Text(k == 3 ? L("База данных") : k == 1 ? L("Папка") : L("Страница"))
                    .font(.system(size: 11))
                    .foregroundColor(Tokens.muted)
                if shell.quickAccess.isPinned(page.id) {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundColor(Tokens.muted).help(L("Уже закреплено на другом месте — переедет сюда"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
