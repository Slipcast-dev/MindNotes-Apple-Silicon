import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, text, syntax, files, language, updates, types
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: return "Оформление"
        case .text: return "Текст"
        case .syntax: return "Подсветка синтаксиса"
        case .files: return "Файлы"
        case .language: return "Язык"
        case .updates: return "Обновления"
        case .types: return "Типы файлов"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .text: return "textformat"
        case .syntax: return "chevron.left.forwardslash.chevron.right"
        case .files: return "doc.text"
        case .language: return "globe"
        case .updates: return "arrow.down.circle"
        case .types: return "square.grid.2x2"
        }
    }
}

/// Preferences window (⌘,): a list of sections on the left, the selected section on the right.
/// The window can be resized in both directions; long sections scroll.
struct SettingsView: View {
    @EnvironmentObject private var settings: Preferences
    @AppStorage("settingsPane") private var pane: SettingsPane = .appearance
    @ObservedObject private var updater = UpdateManager.shared

    var body: some View {
        let theme = settings.theme

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsPane.allCases) { p in
                    Button { pane = p } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.symbol).frame(width: 18)
                            Text(p.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(HoverButtonStyle(size: .row, selected: pane == p))
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 232)
            .background(Color.primary.opacity(0.04))

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(pane.title).font(AppFont.title2.weight(.semibold))
                    content(for: pane, theme: theme)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .environment(\.theme, theme)
        .environment(\.font, AppFont.body)
        .frame(minWidth: 640, idealWidth: 780, maxWidth: .infinity, minHeight: 420, idealHeight: 580, maxHeight: .infinity)
        .background(SettingsWindowConfigurator())
    }

    @ViewBuilder
    private func content(for pane: SettingsPane, theme: Theme) -> some View {
        switch pane {
        case .appearance:
            card("Режим") {
                Picker("", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            card("Тема") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(ThemeSet.all) { set in tile(set) }
                }
                Text("Dracula и Monokai всегда тёмные.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }
            card("Эффект стекла") {
                Toggle("Прозрачное окно с размытием, как в macOS", isOn: $settings.glassEnabled)
                glassRow("Боковая панель", $settings.glassSidebar)
                glassRow("Вкладки", $settings.glassTabs)
                glassRow("Документ", $settings.glassAmount)
                Text("Сквозь фон окна проступает рабочий стол; у боковой панели, вкладок и документа своя прозрачность. Чем выше значение, тем слабее фон; если текст читается плохо, уменьшите его или выключите эффект.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }
            card("Шрифт интерфейса") {
                row("Шрифт") {
                    Picker("", selection: $settings.uiFontName) {
                        ForEach(Preferences.fonts, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                row("Размер") {
                    Slider(value: $settings.uiFontSize, in: 10...20, step: 1)
                    Text("\(Int(settings.uiFontSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text("Так выглядят боковая панель, вкладки и настройки.")
                        .font(settings.uiFontName == Preferences.systemFont ? .system(size: CGFloat(settings.uiFontSize)) : Font(FontLibrary.font(family: settings.uiFontName, size: CGFloat(settings.uiFontSize))))
                    Spacer()
                    Button("Сбросить") {
                        settings.uiFontName = Preferences.systemFont
                        settings.uiFontSize = AppFont.defaultSize
                    }
                    .buttonStyle(.hoverFilled)
                    .disabled(settings.uiFontName == Preferences.systemFont && settings.uiFontSize == AppFont.defaultSize)
                }
                Text("Шрифт документов выбирается отдельно, в разделе «Текст». Меню macOS и заголовок окна всегда остаются системными.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }
            preview(theme)

        case .text:
            card("Шрифт и размер") {
                row("Шрифт") {
                    Picker("", selection: $settings.fontName) {
                        ForEach(Preferences.fonts, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                row("Размер") {
                    Slider(value: $settings.fontSize, in: 10...28, step: 1)
                    Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                row("Отступы заголовков") {
                    Slider(value: $settings.headingSpacing, in: 0.5...2.5, step: 0.1)
                    Text(String(format: "×%.1f", settings.headingSpacing)).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            card("Исходник") {
                Toggle("Показывать номера строк", isOn: $settings.showLineNumbers)
            }
            card("Списки задач") {
                Toggle("Переносить выполненные задачи в конец списка", isOn: $settings.moveDoneTasks)
                Text("Когда вы ставите галочку в режиме чтения, пункт сдвигается вниз списка. Отметка сохраняется прямо в файле.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }
            card("Проверка текста") {
                Toggle("Проверять орфографию и грамматику в режиме правки", isOn: $settings.spellCheck)
                Text("Русский и английский: ошибки подчёркиваются, исправление — в контекстном меню. Работает в Markdown, TXT, RTF и TeX; в исходном коде проверка выключена.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }
            preview(theme)

        case .syntax:
            card("Подсветка синтаксиса") {
                Toggle("Включить подсветку синтаксиса", isOn: $settings.syntaxEnabled)
                Text("Цвета берутся из выбранной темы. Подсветка работает в режимах чтения, исходника и правки, а также в блоках кода Markdown.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }
            card("Программирование") { languageToggles(Self.programming) }
            card("Разметка и данные") { languageToggles(Self.markup) }
            HStack(spacing: 8) {
                Button("Включить все") { settings.syntaxOff = [] }.buttonStyle(.hoverFilled)
                Button("Выключить все") { settings.syntaxOff = Set((Self.programming + Self.markup).map(\.rawValue)) }.buttonStyle(.hoverFilled)
            }
            .disabled(!settings.syntaxEnabled)

        case .files:
            card("Обновление") {
                Toggle("Обновлять файл автоматически, когда он изменился на диске", isOn: $settings.autoReload)
            }

        case .language:
            card("Язык интерфейса") {
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: settings.language) { _ in AppRestart.offer() }
                Text("После смены языка Grizzly предложит перезапуститься.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }

        case .updates:
            card("Обновления") {
                row("Установленная версия") { Text(updater.currentVersion).monospacedDigit() }
                HStack {
                    Button("Проверить обновления") { Task { await updater.check(silent: false) } }
                        .buttonStyle(.hoverFilled)
                        .disabled(updater.phase == .checking || updater.phase == .installing)
                }
                UpdateView(updater: updater)
                Text("Grizzly проверяет GitHub при каждом запуске. Новая версия скачивается и устанавливается прямо из приложения.")
                    .font(AppFont.caption).foregroundColor(.secondary)
                Text("Лицензия: © 2026 Slipcast-dev. Изменять и распространять Grizzly без письменного согласия автора запрещено.")
                    .font(AppFont.caption).foregroundColor(.secondary)
            }

        case .types:
            card("Приложение по умолчанию") { FileAssociationsView() }
        }
    }

    static let programming: [FileType] = [.python, .swift, .cpp, .csharp, .javascript, .typescript, .css, .php]
    static let markup: [FileType] = [.json, .yaml, .config, .xml, .html, .tex, .log]

    private func languageToggles(_ types: [FileType]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(types, id: \.self) { type in
                Toggle(type.title, isOn: Binding(
                    get: { settings.highlights(type) },
                    set: { settings.setHighlight(type, $0) }))
            }
        }
        .disabled(!settings.syntaxEnabled)
    }

    private func glassRow(_ title: LocalizedStringKey, _ value: Binding<Double>) -> some View {
        row(title) {
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
        .disabled(!settings.glassEnabled)
    }

    private func card<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppFont.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)))
    }

    private func row<C: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func tile(_ set: ThemeSet) -> some View {
        let t = set.variant(dark: settings.wantsDark)
        let selected = settings.themeID == set.id
        return Button { settings.themeID = set.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    ForEach([t.heading, t.key, t.string, t.keyword], id: \.self) { c in
                        Circle().fill(c).frame(width: 8, height: 8)
                    }
                }
                Text(set.name).font(AppFont.callout.weight(.medium)).foregroundColor(t.text).lineLimit(1)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(TileButtonStyle())
    }

    private func preview(_ t: Theme) -> some View {
        let size = CGFloat(settings.fontSize)
        let h = CGFloat(settings.headingSpacing)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Заголовок").font(settings.font(size: size * 1.5, weight: .semibold)).foregroundColor(t.heading)
                .padding(.top, size * 0.3 * h).padding(.bottom, size * 0.2 * h)
            Text("Так будет выглядеть обычный текст документа.").font(settings.font(size: size)).foregroundColor(t.text)
            HStack(spacing: 8) {
                if settings.showLineNumbers { Text("1").foregroundColor(t.gutter) }
                Text("\"key\": ").foregroundColor(t.key) + Text("\"value\"").foregroundColor(t.string)
            }
            .font(.system(size: size * 0.85, design: .monospaced))
            .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.35)))
    }
}

/// Theme tiles keep their own colors; hover and press only brighten and shrink them slightly.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .brightness(hovering && !configuration.isPressed ? 0.04 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }

    private struct Hovering<Content: View>: View {
        @State private var hovering = false
        let content: (Bool) -> Content
        init(@ViewBuilder _ content: @escaping (Bool) -> Content) { self.content = content }
        var body: some View { content(hovering).onHover { hovering = $0 } }
    }
}

/// Makes sure the Settings window can be dragged larger and smaller in both directions.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: 640, height: 420)
            window.setFrameAutosaveName("GrizzlySettingsWindow")
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
