import SwiftUI

/// Встроенный шаблон: обычная страница с начальным текстом. Хранится в коде, а не в пространстве.
struct BuiltinTemplate: Identifiable {
    var title: String
    var detail: String
    var markdown: String
    var id: String { title }

    static var all: [BuiltinTemplate] {
        [BuiltinTemplate(title: L("Задача"), detail: L("Статус, срок и описание"),
                         markdown: L("**Статус:** запланировано\n**Срок:** \n\n## Описание\n\n\n## Что нужно сделать\n\n- [ ] Первый шаг\n- [ ] Второй шаг")),
         BuiltinTemplate(title: L("Проект"), detail: L("Цели, этапы и задачи"),
                         markdown: L("## Цель\n\n\n## Этапы\n\n1. Подготовка\n2. Работа\n3. Завершение\n\n## Задачи\n\n- [ ] Первая задача")),
         BuiltinTemplate(title: L("Дневник"), detail: L("События и итоги дня"),
                         markdown: L("## События\n\n\n## Мысли\n\n\n## Итоги дня\n")),
         BuiltinTemplate(title: L("Заметка базы знаний"), detail: L("Тема, источники и ссылки"),
                         markdown: L("## Тема\n\n\n## Главное\n\n\n## Источники\n\n- \n\n## Связанные страницы\n"))]
    }
}

/// Библиотека шаблонов по макету: карточки с кнопкой «Использовать».
struct TemplatesScreen: View {
    @EnvironmentObject private var shell: ShellModel
    /// Категория каталога; nil — все.
    @State private var category: CatalogTemplate.Category?
    private let catalog = TemplateCatalog.all

    private var shown: [CatalogTemplate] { catalog.filter { category == nil || $0.category == category } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Библиотека"))
                ScreenTitle(text: L("Шаблоны")).padding(.top, 8)
                Text("Начните с готовой структуры и измените её под себя.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.top, 6)
                    .padding(.bottom, 22)
                categories.padding(.bottom, 14)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(shown) { template in catalogCard(template) }
                }
                Text("Простые страницы").font(.system(size: 17, weight: .semibold)).padding(.top, 28).padding(.bottom, 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(BuiltinTemplate.all) { template in
                        card(title: template.title, detail: template.detail) { shell.useBuiltin(template) }
                    }
                }
                Text("Мои шаблоны").font(.system(size: 17, weight: .semibold)).padding(.top, 28).padding(.bottom, 10)
                if shell.userTemplates.isEmpty {
                    Text("Откройте страницу или запись и выберите «Сохранить как шаблон…» в меню «…». Шаблон записи сохранит и значения свойств.")
                        .font(.system(size: 13))
                        .foregroundColor(Tokens.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(shell.userTemplates) { template in
                        card(title: template.name, detail: detail(template)) { shell.useTemplate(template) }
                            .contextMenu {
                                Button("Переименовать…") { shell.renameTemplate(template) }
                                Button("Удалить") { shell.deleteTemplate(template) }
                            }
                    }
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Категории каталога: «Все» и по одной на категорию.
    private var categories: some View {
        HStack(spacing: 6) {
            chip(L("Все"), symbol: "square.grid.2x2", active: category == nil) { category = nil }
            ForEach(CatalogTemplate.Category.allCases, id: \.self) { c in
                chip(TemplateCatalog.title(c), symbol: TemplateCatalog.symbol(c), active: category == c) { category = c }
            }
        }
    }

    private func chip(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(active ? Tokens.soft : .clear))
                .overlay(Capsule().stroke(Tokens.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundColor(active ? Tokens.ink : Tokens.muted)
    }

    /// Карточка готового шаблона: значок, описание, состав баз и видов.
    private func catalogCard(_ template: CatalogTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(template.icon).font(.system(size: 24))
                Text(template.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            // Строки зарезервированы заранее: у всех карточек одна высота, кнопки на одной линии.
            Text(template.detail).font(.system(size: 13)).foregroundColor(Tokens.muted)
                .lineLimit(3, reservesSpace: true)
            Text(composition(template)).font(.system(size: 11)).foregroundColor(Tokens.muted)
                .lineLimit(1)
                .padding(.top, 2)
            Spacer(minLength: 0)
            HStack {
                Text(TemplateCatalog.title(template.category)).font(.system(size: 11)).foregroundColor(Tokens.muted)
                Spacer()
                Button("Использовать") { shell.useCatalog(template) }
                    .buttonStyle(NotesButtonStyle(kind: .primary))
            }
            .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 200, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.line))
    }

    /// «База: Таблица · Доска · Хронология» — что появится после установки.
    private func composition(_ template: CatalogTemplate) -> String {
        // Несколько баз — их названия: виды каждой в одну строку не помещаются.
        if template.databases.count > 1 { return template.databases.map(\.title).joined(separator: " · ") }
        return template.databases.map { db in
            let kinds = db.views.map { ViewKindTitle.title($0.kind) }
            var seen = Set<String>()
            let unique = kinds.filter { seen.insert($0).inserted }
            return unique.joined(separator: " · ")
        }.joined(separator: "; ")
    }

    private func detail(_ template: PageTemplate) -> String {
        guard let database = template.databaseID else { return L("Страница") }
        let page = shell.databaseIndex.first { $0.value == database }?.key
        let title = shell.pages.first { $0.id == page }?.title
        return L("Запись базы «%@»", title ?? L("в корзине"))
    }

    private func card(title: String, detail: String, use: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            Text(detail).font(.system(size: 13)).foregroundColor(Tokens.muted).lineLimit(2)
            Button("Использовать", action: use)
                .buttonStyle(NotesButtonStyle())
                .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.line))
    }
}

/// Полный вид встроенного представления поверх страницы.
struct EmbeddedDatabaseSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    let block: Block
    let editor: PageEditorModel
    @State private var model: DatabaseModel?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                DatabaseScreen(model: model)
            } else {
                EmptyKindNote(text: L("База недоступна: она удалена или в корзине."))
            }
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(NotesButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 960, height: 640)
        .onAppear { model = shell.embeddedModel(for: block, editor: editor) }
    }
}
