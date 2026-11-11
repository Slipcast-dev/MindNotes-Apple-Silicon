import SwiftUI

/// Связь в ячейке: связанные записи плашками, нажатие открывает запись, «+» — выбор записей целевой базы.
struct RelationCell: View {
    @EnvironmentObject private var shell: ShellModel
    let property: PropertyDefinition
    let value: PropertyValue?
    let onChange: (PropertyValue?) -> Void
    @State private var picking = false

    private static let shown = 3

    private var links: [LinkedPage] {
        if case .relation(let links)? = value { return links }
        return []
    }

    var body: some View {
        HStack(spacing: 4) {
            if links.isEmpty { Text("Пусто").font(.system(size: 13)).foregroundColor(Tokens.muted) }
            ForEach(links.prefix(Self.shown)) { link in
                Button { shell.openPage(link.id) } label: {
                    Chip(text: RelationPicker.title(link))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(L("Открыть запись"))
            }
            if links.count > Self.shown {
                Text(L("ещё %d", links.count - Self.shown)).font(.system(size: 11)).foregroundColor(Tokens.muted)
            }
            Spacer(minLength: 0)
            Button { picking = true } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain)
                .foregroundColor(Tokens.muted)
                .help(L("Выбрать записи"))
                .accessibilityLabel(Text("Выбрать записи"))
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            RelationPicker(property: property, chosen: links) { onChange($0.isEmpty ? nil : .relation($0)) }
                .environmentObject(shell)
        }
    }
}

/// Выбор записей целевой базы с поиском по заголовку. Каждое нажатие сразу меняет значение.
struct RelationPicker: View {
    @EnvironmentObject private var shell: ShellModel
    let property: PropertyDefinition
    let onChange: ([LinkedPage]) -> Void
    @State private var chosen: [LinkedPage]
    @State private var query = ""
    @State private var found: [LinkedPage] = []
    @State private var total = 0
    @State private var unavailable = false

    private static let limit = 50

    init(property: PropertyDefinition, chosen: [LinkedPage], onChange: @escaping ([LinkedPage]) -> Void) {
        self.property = property
        self.onChange = onChange
        _chosen = State(initialValue: chosen)
    }

    static func title(_ link: LinkedPage) -> String { link.title.isEmpty ? L("Без названия") : link.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Найти запись", text: $query).textFieldStyle(.roundedBorder)
            if unavailable {
                Text("База связи недоступна: она удалена или в корзине.").font(.system(size: 12)).foregroundColor(Tokens.danger)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(found) { row($0) }
                    if found.isEmpty, !unavailable {
                        Text(query.isEmpty ? "В базе нет записей." : "Ничего не найдено.").font(.system(size: 12)).foregroundColor(Tokens.muted)
                    }
                }
            }
            .frame(height: 260)
            if total > found.count {
                Text(L("Показаны первые %d из %d. Уточните поиск.", found.count, total)).font(.system(size: 11)).foregroundColor(Tokens.muted)
            }
            if chosen.count >= RelationLimits.maxLinks {
                Text(L("Не больше %d связей в одной ячейке.", RelationLimits.maxLinks)).font(.system(size: 11)).foregroundColor(Tokens.danger)
            }
        }
        .padding(12)
        .frame(width: 320)
        .task(id: query) {
            // Поиск после короткой паузы: не на каждую букву.
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func row(_ link: LinkedPage) -> some View {
        let selected = chosen.contains { $0.id == link.id }
        return Button { toggle(link) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundColor(selected ? Tokens.accent : Tokens.muted)
                Text(Self.title(link)).font(.system(size: 13)).foregroundColor(Tokens.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ link: LinkedPage) {
        if let i = chosen.firstIndex(where: { $0.id == link.id }) {
            chosen.remove(at: i)
        } else {
            guard chosen.count < RelationLimits.maxLinks else { return }
            chosen.append(link)
        }
        onChange(chosen)
    }

    private func search() async {
        guard let store = shell.store, let target = property.config.target else { unavailable = true; return }
        do {
            guard let database = try await store.database(target), let title = database.titleProperty,
                  shell.pages.contains(where: { $0.id == database.pageID }) else {
                unavailable = true
                found = []
                return
            }
            var state = DatabaseViewState()
            state.sorts = [SortRule(property: title.id)]
            let needle = query.trimmingCharacters(in: .whitespaces)
            if !needle.isEmpty { state.filter.items = [.rule(FilterRule(property: title.id, op: .contains, value: needle))] }
            let page = try await store.queryRecords(database: database, state: state, limit: Self.limit, offset: 0)
            found = page.rows.map { LinkedPage(id: $0.id, title: $0.title, icon: $0.icon) }
            total = page.total
            unavailable = false
        } catch {
            shell.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
