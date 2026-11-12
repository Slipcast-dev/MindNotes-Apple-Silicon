import AppKit

/// Единый список действий редактора: правый клик, меню «Формат», панель при выделении и меню «/» используют его.
enum EditorAction: Equatable {
    case turnInto(BlockType)
    case insert(BlockType)
    case mark(String)
    case color(String?)
    case highlight(String?)
    /// Цвет блока целиком: текст `red` или фон `red_background`.
    case blockColor(String?)
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
    /// `@`-упоминания (M12): страница, человек, дата (`ГГГГ-ММ-ДД` или с временем) и выбор даты в окне.
    case mentionPage(UUID, String)
    case mentionPerson(Person)
    case mentionDate(String)
    case pickMentionDate
    /// Закладка и встраивание (M12): адрес спрашивается в окне; «Обновить превью» — у выбранной закладки.
    case insertBookmark
    case insertEmbed
    case refreshLinkPreview
    /// Синхронизированный блок (ADR-0012).
    /// Комментарий к выделенному тексту (M14).
    case comment
    case makeSynced
    case unsyncCopy
    /// Запрашивает изображение или файл у пользователя.
    case attach(BlockType)
    case insertTable
    /// Просит выбрать базу и вставляет её представление.
    case insertDatabaseView
    case copyBlockLink
    case moveBlockUp
    case moveBlockDown

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
         Item(title: t("Ссылка на страницу"), action: .beginPageLink, aliases: ["link", "страница"]),
         Item(title: t("Изображение"), action: .attach(.image), aliases: ["картинка", "фото", "image"]),
         Item(title: t("Видео"), action: .attach(.video), aliases: ["ролик", "фильм", "кино", "video"]),
         Item(title: t("Файл"), action: .attach(.file), aliases: ["вложение", "документ", "file"]),
         Item(title: t("Таблица"), action: .insertTable, aliases: ["table", "сетка"]),
         Item(title: t("Представление базы"), action: .insertDatabaseView, aliases: ["база", "database", "view"]),
         Item(title: t("Закладка"), action: .insertBookmark, aliases: ["bookmark", "ссылка", "url", "сайт"]),
         Item(title: t("Встраивание"), action: .insertEmbed, aliases: ["embed", "youtube", "vimeo", "figma", "карта", "видео"])]
    }

    static var marks: [Item] {
        [Item(title: t("Жирный"), action: .mark("b"), key: "b"),
         Item(title: t("Курсив"), action: .mark("i"), key: "i"),
         Item(title: t("Подчёркнутый"), action: .mark("u"), key: "u"),
         Item(title: t("Зачёркнутый"), action: .mark("s"), key: "x", modifiers: [.command, .shift]),
         Item(title: t("Встроенный код"), action: .mark("code"), key: "e"),
         Item(title: t("Ссылка…"), action: .link, key: "k", modifiers: [.command, .shift]),
         Item(title: t("Убрать форматирование"), action: .clearFormat, key: "\\", modifiers: [.command, .control])]
    }

    static var colors: [Item] {
        BlockTextStyle.colors.map { Item(title: t($0.title), action: .color($0.name)) } + [Item(title: t("Обычный"), action: .color(nil))]
    }

    static var highlights: [Item] {
        BlockTextStyle.colors.map { Item(title: t($0.title), action: .highlight($0.name)) } + [Item(title: t("Без выделения"), action: .highlight(nil))]
    }

    static var blockColors: [Item] {
        [Item(title: t("По умолчанию"), action: .blockColor(nil))]
            + BlockTextStyle.colors.map { Item(title: t($0.title), action: .blockColor($0.name)) }
            + BlockTextStyle.colors.map { Item(title: String(format: t("Фон: %@"), t($0.title).lowercased()), action: .blockColor($0.name + BlockColor.backgroundSuffix)) }
    }

    static var blockActions: [Item] {
        [Item(title: t("Увеличить вложенность"), action: .indent),
         Item(title: t("Уменьшить вложенность"), action: .outdent),
         Item(title: t("Переместить вверх"), action: .moveBlockUp),
         Item(title: t("Переместить вниз"), action: .moveBlockDown),
         Item(title: t("Дублировать блок"), action: .duplicateBlock, key: "d"),
         Item(title: t("Копировать ссылку на блок"), action: .copyBlockLink),
         Item(title: t("Сделать синхронизированным"), action: .makeSynced, aliases: ["synced", "синхрон"]),
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

extension EditorAction {
    /// ID команды в списке настраиваемых сочетаний (`ShortcutCatalog`); nil — сочетания у действия нет.
    var shortcutID: String? {
        switch self {
        case .mark(let m): return "format.mark." + m
        case .link: return "format.link"
        case .clearFormat: return "format.clear"
        case .turnInto(let type): return "format.type." + type.rawValue
        case .duplicateBlock: return "block.duplicate"
        default: return nil
        }
    }
}
