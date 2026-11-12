import Foundation

/// Сочетание клавиш команды меню. `key` — символ в нижнем регистре или имя особой клавиши.
/// Пустой `key` — команда без сочетания (пользователь его убрал).
struct KeyShortcut: Codable, Hashable {
    var key: String
    var command = true
    var shift = false
    var option = false
    var control = false

    static let none = KeyShortcut(key: "", command: false)

    /// Особые клавиши и их значки.
    static let special: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→", "return": "↩", "tab": "⇥", "space": "Пробел", "delete": "⌫",
    ]

    var isNone: Bool { key.isEmpty }

    /// Сочетание должно быть с ⌘ или ⌃: иначе оно перехватывало бы обычный ввод текста.
    var isValid: Bool { !key.isEmpty && (command || control) }

    /// Как в меню macOS: ⌃⌥⇧⌘K.
    var display: String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + (Self.special[key] ?? key.uppercased())
    }

    init(key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}

/// Команда с настраиваемым сочетанием. `title` — ключ строки интерфейса.
struct AppShortcut: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case navigation, ai, file, format, blocks
        var title: String {
            switch self {
            case .navigation: return "Переход"
            case .ai: return "ИИ"
            case .file: return "Файл"
            case .format: return "Формат"
            case .blocks: return "Блоки"
            }
        }
    }

    let id: String
    let title: String
    let group: Group
    let standard: KeyShortcut
}

enum ShortcutCatalog {
    private static func k(_ key: String, shift: Bool = false, option: Bool = false, control: Bool = false) -> KeyShortcut {
        KeyShortcut(key: key, command: true, shift: shift, option: option, control: control)
    }

    /// Все команды со стандартными сочетаниями. ID форматирования совпадают с `EditorAction.shortcutID`.
    static let all: [AppShortcut] = [
        AppShortcut(id: "nav.search", title: "Поиск…", group: .navigation, standard: k("k")),
        AppShortcut(id: "nav.back", title: "Назад", group: .navigation, standard: k("[")),
        AppShortcut(id: "nav.forward", title: "Вперёд", group: .navigation, standard: k("]")),
        AppShortcut(id: "nav.sidebar", title: "Боковая панель", group: .navigation, standard: k("\\")),
        AppShortcut(id: "nav.home", title: "Главная", group: .navigation, standard: k("h", shift: true)),
        AppShortcut(id: "ai.chat", title: "Чат с ИИ", group: .ai, standard: k("l")),
        AppShortcut(id: "ai.ask", title: "Спросить ИИ", group: .ai, standard: k("j")),
        AppShortcut(id: "file.newPage", title: "Новая страница", group: .file, standard: k("n")),
        AppShortcut(id: "file.newFolder", title: "Новая папка", group: .file, standard: k("n", shift: true)),
        AppShortcut(id: "file.open", title: "Открыть файл…", group: .file, standard: k("o")),
        AppShortcut(id: "app.settings", title: "Настройки…", group: .file, standard: k(",")),
        AppShortcut(id: "format.mark.b", title: "Жирный", group: .format, standard: k("b")),
        AppShortcut(id: "format.mark.i", title: "Курсив", group: .format, standard: k("i")),
        AppShortcut(id: "format.mark.u", title: "Подчёркнутый", group: .format, standard: k("u")),
        AppShortcut(id: "format.mark.s", title: "Зачёркнутый", group: .format, standard: k("x", shift: true)),
        AppShortcut(id: "format.mark.code", title: "Встроенный код", group: .format, standard: k("e")),
        AppShortcut(id: "format.link", title: "Ссылка…", group: .format, standard: k("k", shift: true)),
        // ⌘\ — «Боковая панель»; раньше оба пункта делили одно сочетание.
        AppShortcut(id: "format.clear", title: "Убрать форматирование", group: .format, standard: k("\\", control: true)),
        AppShortcut(id: "format.type.paragraph", title: "Текст", group: .blocks, standard: k("0", option: true)),
        AppShortcut(id: "format.type.heading1", title: "Заголовок 1", group: .blocks, standard: k("1", option: true)),
        AppShortcut(id: "format.type.heading2", title: "Заголовок 2", group: .blocks, standard: k("2", option: true)),
        AppShortcut(id: "format.type.heading3", title: "Заголовок 3", group: .blocks, standard: k("3", option: true)),
        AppShortcut(id: "format.type.task", title: "Задача", group: .blocks, standard: k("4", option: true)),
        AppShortcut(id: "format.type.bullet", title: "Маркированный список", group: .blocks, standard: k("5", option: true)),
        AppShortcut(id: "format.type.numbered", title: "Нумерованный список", group: .blocks, standard: k("6", option: true)),
        AppShortcut(id: "format.type.toggle", title: "Сворачиваемый блок", group: .blocks, standard: k("7", option: true)),
        AppShortcut(id: "format.type.quote", title: "Цитата", group: .blocks, standard: k("8", option: true)),
        AppShortcut(id: "format.type.callout", title: "Выноска", group: .blocks, standard: k("9", option: true)),
        AppShortcut(id: "block.duplicate", title: "Дублировать блок", group: .blocks, standard: k("d")),
    ]

    static func find(_ id: String) -> AppShortcut? { all.first { $0.id == id } }

    /// Действующее сочетание: своё или стандартное; nil — без сочетания.
    static func effective(_ id: String, overrides: [String: KeyShortcut]) -> KeyShortcut? {
        let s = overrides[id] ?? find(id)?.standard
        return s.flatMap { $0.isNone ? nil : $0 }
    }

    /// Команды, у которых совпадает сочетание с `shortcut` (кроме самой `id`).
    static func conflicts(of shortcut: KeyShortcut, for id: String, overrides: [String: KeyShortcut]) -> [AppShortcut] {
        all.filter { $0.id != id && effective($0.id, overrides: overrides) == shortcut }
    }

    /// Свои сочетания из настроек; неизвестные ID и испорченные данные пропускаются.
    static func decode(_ data: Data?) -> [String: KeyShortcut] {
        guard let data, let map = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) else { return [:] }
        return map.filter { find($0.key) != nil && ($0.value.isNone || $0.value.isValid) }
    }

    static func encode(_ map: [String: KeyShortcut]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(map)) ?? Data("{}".utf8)
    }
}
