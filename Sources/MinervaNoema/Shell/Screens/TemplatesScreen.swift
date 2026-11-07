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
