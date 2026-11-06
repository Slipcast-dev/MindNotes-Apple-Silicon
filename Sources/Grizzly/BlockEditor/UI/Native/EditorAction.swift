import AppKit

/// Единый список действий редактора: правый клик, меню «Формат», панель при выделении и меню «/» используют его.
enum EditorAction: Equatable {
    case turnInto(BlockType)
    case insert(BlockType)
    case mark(String)
    case color(String?)
    case highlight(String?)
    case link
    case clearFormat
    case indent
    case outdent
    case deleteBlock
    case duplicateBlock
    /// Вставляет ссылку на страницу вместо набранного «[[запрос».
    case linkPage(UUID, String)
    /// Начинает набор ссылки: вводит «[[».
    case beginPageLink

    struct Item {
        let title: String
        let action: EditorAction
        var key: String = ""
        var modifiers: NSEvent.ModifierFlags = [.command]
        /// Дополнительные слова для поиска в меню «/».
        var aliases: [String] = []
    }

    struct Group {
        let title: String
        let items: [Item]
    }

    private static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    static var blockTypes: [Item] {
        [Item(title: t("Текст"), action: .turnInto(.paragraph), key: "0", modifiers: [.command, .option], aliases: ["абзац", "text"]),
         Item(title: t("Заголовок 1"), action: .turnInto(.heading1), key: "1", modifiers: [.command, .option], aliases: ["h1", "название"]),
         Item(title: t("Заголовок 2"), action: .turnInto(.heading2), key: "2", modifiers: [.command, .option], aliases: ["h2"]),
         Item(title: t("Заголовок 3"), action: .turnInto(.heading3), key: "3", modifiers: [.command, .option], aliases: ["h3", "подзаголовок"]),
         Item(title: t("Задача"), action: .turnInto(.task), key: "4", modifiers: [.command, .option], aliases: ["чекбокс", "todo", "список задач"]),
         Item(title: t("Маркированный список"), action: .turnInto(.bullet), key: "5", modifiers: [.command, .option], aliases: ["список", "bullet"]),
         Item(title: t("Нумерованный список"), action: .turnInto(.numbered), key: "6", modifiers: [.command, .option], aliases: ["список", "номер"]),
         Item(title: t("Сворачиваемый блок"), action: .turnInto(.toggle), key: "7", modifiers: [.command, .option], aliases: ["переключатель", "toggle", "спойлер"]),
         Item(title: t("Цитата"), action: .turnInto(.quote), key: "8", modifiers: [.command, .option], aliases: ["quote"]),
         Item(title: t("Выноска"), action: .turnInto(.callout), key: "9", modifiers: [.command, .option], aliases: ["callout", "заметка", "важно"]),
         Item(title: t("Код"), action: .turnInto(.code), aliases: ["code", "программа"])]
    }

    static var inserts: [Item] {
        [Item(title: t("Разделитель"), action: .insert(.divider), aliases: ["линия", "divider", "черта"]),
         Item(title: t("Ссылка на страницу"), action: .beginPageLink, aliases: ["link", "страница"])]
    }

    static var marks: [Item] {
        [Item(title: t("Жирный"), action: .mark("b"), key: "b"),
         Item(title: t("Курсив"), action: .mark("i"), key: "i"),
         Item(title: t("Подчёркнутый"), action: .mark("u"), key: "u"),
         Item(title: t("Зачёркнутый"), action: .mark("s"), key: "x", modifiers: [.command, .shift]),
         Item(title: t("Встроенный код"), action: .mark("code"), key: "e"),
         Item(title: t("Ссылка…"), action: .link, key: "k", modifiers: [.command, .shift]),
         Item(title: t("Убрать форматирование"), action: .clearFormat, key: "\\")]
    }

    static var colors: [Item] {
        BlockTextStyle.colors.map { Item(title: t($0.title), action: .color($0.name)) } + [Item(title: t("Обычный"), action: .color(nil))]
    }

    static var highlights: [Item] {
        BlockTextStyle.colors.map { Item(title: t($0.title), action: .highlight($0.name)) } + [Item(title: t("Без выделения"), action: .highlight(nil))]
    }

    static var blockActions: [Item] {
        [Item(title: t("Увеличить вложенность"), action: .indent),
         Item(title: t("Уменьшить вложенность"), action: .outdent),
         Item(title: t("Дублировать блок"), action: .duplicateBlock, key: "d"),
         Item(title: t("Удалить блок"), action: .deleteBlock)]
    }

    /// Пункты меню «/»: типы блоков и вставки.
    static var slashItems: [Item] { blockTypes + inserts }

    /// Нормализация для поиска: регистр и ё/е не различаются.
    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    static func filterSlash(_ query: String) -> [Item] {
        let q = normalized(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return slashItems }
        return slashItems.filter { item in
            normalized(item.title).contains(q) || item.aliases.contains { normalized($0).contains(q) }
        }
    }
}
