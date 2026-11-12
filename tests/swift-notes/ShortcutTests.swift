import AppKit
import Foundation

/// Настраиваемые сочетания клавиш: стандартные значения, конфликты, сохранение.
@MainActor
func runShortcutTests() async {
    await test("Сочетания: стандартные без повторов, чат — ⌘L, поиск — ⌘K") {
        let all = ShortcutCatalog.all
        checkEqual(Set(all.map(\.id)).count, all.count, "ID без повторов")
        for item in all {
            check(item.standard.isValid, "стандартное сочетание с ⌘ или ⌃: \(item.id)")
            checkEqual(ShortcutCatalog.conflicts(of: item.standard, for: item.id, overrides: [:]).map(\.id), [], "не совпадает с другими: \(item.id)")
        }
        checkEqual(ShortcutCatalog.effective("ai.chat", overrides: [:])?.display, "⌘L")
        checkEqual(ShortcutCatalog.effective("nav.search", overrides: [:])?.display, "⌘K")
        checkEqual(ShortcutCatalog.effective("format.clear", overrides: [:])?.display, "⌃⌘\\", "больше не делит ⌘\\ с боковой панелью")
    }

    await test("Сочетания: у каждого действия редактора с клавишей — то же стандартное в списке") {
        let items = EditorAction.blockTypes + EditorAction.marks + EditorAction.blockActions
        for item in items where !item.key.isEmpty {
            guard let id = item.action.shortcutID, let standard = ShortcutCatalog.find(id)?.standard else { check(false, "нет в списке: \(item.title)"); continue }
            checkEqual(standard.key, item.key, id)
            checkEqual(standard.shift, item.modifiers.contains(.shift), id)
            checkEqual(standard.option, item.modifiers.contains(.option), id)
            checkEqual(standard.control, item.modifiers.contains(.control), id)
        }
    }

    await test("Сочетания: подпись, проверка, свои значения, конфликты и сохранение") {
        checkEqual(KeyShortcut(key: "k", shift: true, option: true, control: true).display, "⌃⌥⇧⌘K")
        checkEqual(KeyShortcut(key: "up").display, "⌘↑")
        check(!KeyShortcut(key: "a", command: false).isValid, "без ⌘ и ⌃ — нельзя: перехватывало бы ввод")
        check(KeyShortcut(key: "a", command: false, control: true).isValid)
        check(KeyShortcut.none.isNone && ShortcutCatalog.effective("ai.chat", overrides: ["ai.chat": .none]) == nil, "можно убрать сочетание")
        let custom = KeyShortcut(key: "k")
        let taken = ShortcutCatalog.conflicts(of: custom, for: "ai.chat", overrides: [:]).map(\.id)
        checkEqual(taken, ["nav.search"], "⌘K уже у поиска")
        let map: [String: KeyShortcut] = ["ai.chat": KeyShortcut(key: "y", shift: true), "nav.home": .none, "нет.такой": KeyShortcut(key: "z"), "nav.back": KeyShortcut(key: "q", command: false)]
        let decoded = ShortcutCatalog.decode(ShortcutCatalog.encode(map))
        checkEqual(decoded["ai.chat"], KeyShortcut(key: "y", shift: true))
        checkEqual(decoded["nav.home"], KeyShortcut.none)
        check(decoded["нет.такой"] == nil && decoded["nav.back"] == nil, "неизвестные и неверные пропущены")
        checkEqual(ShortcutCatalog.decode(Data("мусор".utf8)), [:])
    }
}
