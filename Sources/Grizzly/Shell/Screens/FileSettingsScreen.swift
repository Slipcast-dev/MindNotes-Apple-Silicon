import SwiftUI

/// Настройки файлового режима: текст, подсветка, типы файлов. Экран внутри окна, как остальные настройки.
struct FileSettingsScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case text, syntax, types
        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: return L("Текст")
            case .syntax: return L("Подсветка")
            case .types: return L("Типы файлов")
            }
        }
    }

    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var prefs: Preferences
    @State private var tab: Tab = .text

    static let programming: [FileType] = [.python, .swift, .cpp, .csharp, .javascript, .typescript, .css, .php]
    static let markup: [FileType] = [.json, .yaml, .config, .xml, .html, .tex, .log]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Файловый режим"))
                ScreenTitle(text: L("Настройки файлов")).padding(.top, 8).padding(.bottom, 9)
                Text("Как открываются и показываются файлы на диске.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 16)
                HStack(spacing: 4) {
                    ForEach(Tab.allCases) { item in
                        Button(item.title) { tab = item }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: tab == item ? .semibold : .regular))
                            .foregroundColor(tab == item ? Tokens.accent : Tokens.muted)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(tab == item ? Tokens.accent : .clear).frame(height: 2)
                            }
                    }
                }
                Rectangle().fill(Tokens.line).frame(height: 1).padding(.bottom, 13)
                content
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .text:
            panel {
                Group {
                row(L("Шрифт"), L("Шрифт документов")) {
                    Picker("", selection: $prefs.fontName) {
                        ForEach(Preferences.fonts, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                divider
                row(L("Размер"), "\(Int(prefs.fontSize)) pt") {
                    Slider(value: $prefs.fontSize, in: 10...28, step: 1).frame(width: 200)
                }
                divider
                row(L("Отступы заголовков"), String(format: "×%.1f", prefs.headingSpacing)) {
                    Slider(value: $prefs.headingSpacing, in: 0.5...2.5, step: 0.1).frame(width: 200)
                }
                }
                divider
                toggle(L("Номера строк"), L("В режиме разметки"), $prefs.showLineNumbers)
                divider
                toggle(L("Выполненные задачи в конец"), L("Отмеченный пункт сдвигается вниз списка; отметка сохраняется в файле"), $prefs.moveDoneTasks)
                divider
                toggle(L("Проверка орфографии"), L("Русский и английский, кроме исходного кода"), $prefs.spellCheck)
                divider
                toggle(L("Обновлять файл автоматически"), L("Когда он изменился на диске"), $prefs.autoReload)
            }
        case .syntax:
            panel {
                toggle(L("Подсветка синтаксиса"), L("Также в блоках кода Markdown"), $prefs.syntaxEnabled)
                divider
                languages(L("Программирование"), Self.programming)
                divider
                languages(L("Разметка и данные"), Self.markup)
            }
        case .types:
            panel { FileAssociationsView().padding(.vertical, 15) }
        }
    }

    private func languages(_ title: String, _ types: [FileType]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(types, id: \.self) { type in
                    Toggle(type.title, isOn: Binding(get: { prefs.highlights(type) }, set: { prefs.setHighlight(type, $0) }))
                }
            }
            .disabled(!prefs.syntaxEnabled)
        }
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
    }

    private var divider: some View { Rectangle().fill(Tokens.line).frame(height: 1) }

    private func toggle(_ title: String, _ subtitle: String, _ value: Binding<Bool>) -> some View {
        row(title, subtitle) { Toggle("", isOn: value).labelsHidden().accessibilityLabel(Text(title)) }
    }

    private func row<C: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundColor(Tokens.muted)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 15)
    }
}
