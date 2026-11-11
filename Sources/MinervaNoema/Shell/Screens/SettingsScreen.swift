import AppKit
import SwiftUI

/// Настройки приложения по макету. Подробные настройки файлового режима — отдельным окном.
struct SettingsScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var prefs: AppPreferences
    @State private var language = AppLanguage.saved

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Приложение"))
                ScreenTitle(text: L("Настройки")).padding(.top, 8).padding(.bottom, 9)
                Text("Внешний вид, язык и данные пространства.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Тема").font(.system(size: 14, weight: .semibold))
                        HStack(spacing: 10) {
                            ForEach(AppTheme.allCases) { theme in themeTile(theme) }
                        }
                    }
                    .padding(.vertical, 15)
                    divider
                    row(L("Оформление"), prefs.isDark ? L("Тёмное") : L("Светлое")) {
                        Button("Переключить") { prefs.isDark.toggle() }
                            .buttonStyle(NotesButtonStyle())
                    }
                    divider
                    row(L("Язык интерфейса"), L("Вступает в силу после перезапуска")) {
                        Picker("", selection: $language) {
                            Text("Русский").tag(AppLanguage.ru)
                            Text("English").tag(AppLanguage.en)
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .accessibilityLabel(Text("Язык интерфейса"))
                        .onChange(of: language) { _, new in
                            new.apply()
                            AppRestart.offer()
                        }
                    }
                    if shell.isOpen {
                        divider
                        row(L("Вид пространства"), L("Название, логотип и обложка")) {
                            Button("Настроить") { shell.showsLookSheet = true }.buttonStyle(NotesButtonStyle())
                        }
                    }
                    if shell.isOpen {
                        divider
                        row(L("Резервные копии"), L("Создание и восстановление")) {
                            Button("Управлять") { shell.goBackups() }.buttonStyle(NotesButtonStyle())
                        }
                        divider
                        row(L("Экспорт"), L("Markdown, CSV и вложения в выбранную папку. Не заменяет резервную копию.")) {
                            Button("Экспортировать…") { shell.exportWorkspace() }.buttonStyle(NotesButtonStyle())
                        }
                        divider
                        row(L("Данные пространства"), shell.workspaceRoot?.path ?? "") {
                            Button("Показать в Finder") {
                                if let url = shell.workspaceRoot { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                            .buttonStyle(NotesButtonStyle())
                        }
                    }
                    divider
                    row(L("Обновления"), L("Локальная сборка обновляется вручную")) {
                        Chip(text: L("Автообновления выключены"))
                    }
                    divider
                    row("\(AppEdition.displayName) \((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")",
                        String(format: L("На основе Grizzly %@. © 2026 Slipcast-dev. Изменять и распространять без письменного согласия автора запрещено."), AppEdition.baseGrizzlyVersion)) {
                        EmptyView()
                    }
                }
                .padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))

                if shell.isOpen { PeopleSettings() }

                Text("Пространства").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 10)
                VStack(spacing: 0) {
                    ForEach(shell.knownWorkspaces) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(item.exists ? item.path : L("Папка не найдена")).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if shell.isCurrent(item) {
                                Chip(text: L("Открыто"))
                            } else {
                                Button("Открыть") { shell.switchWorkspace(item) }.buttonStyle(NotesButtonStyle()).disabled(!item.exists)
                                Button("Убрать из списка") { shell.forgetWorkspace(item) }.buttonStyle(NotesButtonStyle(kind: .plain))
                            }
                        }
                        .padding(.vertical, 11)
                    }
                    HStack(spacing: 9) {
                        Button("Создать пространство…") { shell.presentCreate() }.buttonStyle(NotesButtonStyle())
                        Button("Открыть папку…") { shell.presentOpen() }.buttonStyle(NotesButtonStyle())
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
    }

    private func themeTile(_ theme: AppTheme) -> some View {
        let palette = theme.palette(dark: prefs.isDark)
        func color(_ v: UInt32) -> Color {
            Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        return Button { prefs.theme = theme } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    color(palette.side).frame(width: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(color(palette.ink)).frame(width: 62, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(color(palette.muted)).frame(width: 84, height: 4)
                        RoundedRectangle(cornerRadius: 3).fill(color(palette.primary)).frame(width: 36, height: 11)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(palette.paper))
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(prefs.theme == theme ? Tokens.accent : Tokens.line, lineWidth: prefs.theme == theme ? 2 : 1))
                Text(theme.title).font(.system(size: 13, weight: .semibold))
                Text(theme.subtitle).font(.system(size: 11)).foregroundColor(Tokens.muted).lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 210)
    }

    private var divider: some View { Rectangle().fill(Tokens.line).frame(height: 1) }

    private func row<Control: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(2)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 15)
    }
}

/// Справочник людей пространства: имена, цвет и эмодзи для свойства «Человек». Без аккаунтов и сети.
struct PeopleSettings: View {
    @EnvironmentObject private var shell: ShellModel
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Люди").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 4)
            Text("Справочник для свойства «Человек»: общий для всех баз пространства.")
                .font(.system(size: 13)).foregroundColor(Tokens.muted).padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(shell.people) { person in
                    HStack(spacing: 10) {
                        CommitField(value: person.emoji ?? "", placeholder: "🙂") { emoji in
                            var next = person
                            next.emoji = emoji
                            shell.updatePerson(next)
                        }
                        .frame(width: 28)
                        .accessibilityLabel(Text("Эмодзи"))
                        CommitField(value: person.name, placeholder: L("Имя")) { name in
                            var next = person
                            next.name = name
                            shell.updatePerson(next)
                        }
                        .accessibilityLabel(Text("Имя"))
                        Menu {
                            Button("Без цвета") { var next = person; next.color = nil; shell.updatePerson(next) }
                            ForEach(BlockTextStyle.colors, id: \.name) { color in
                                Button(L(color.title)) { var next = person; next.color = color.name; shell.updatePerson(next) }
                            }
                        } label: {
                            Chip(text: person.label, colors: Tokens.swatch(person.color) ?? (Tokens.soft, Tokens.ink))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(Text("Цвет"))
                        Button { shell.deletePerson(person) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .foregroundColor(Tokens.muted)
                            .help(L("Удалить из справочника"))
                            .accessibilityLabel(Text("Удалить из справочника"))
                    }
                    .padding(.vertical, 9)
                    Rectangle().fill(Tokens.line).frame(height: 1)
                }
                HStack(spacing: 9) {
                    TextField(L("Новый человек"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(add)
                    Button("Добавить", action: add)
                        .buttonStyle(NotesButtonStyle())
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        shell.addPerson(name: name)
        newName = ""
    }
}
