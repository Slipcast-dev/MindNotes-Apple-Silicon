import AppKit
import SwiftUI

/// Настройки приложения по макету. Подробные настройки файлового режима — отдельным окном.
struct SettingsScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var prefs: Preferences
    @State private var language = AppLanguage.saved == .en ? AppLanguage.en : AppLanguage.ru

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
                    row(L("Тема"), L("Светлое или тёмное оформление")) {
                        Button("Переключить тему") { prefs.appearance = prefs.theme.isDark ? .light : .dark }
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
                        .onChange(of: language) { new in
                            new.apply()
                            AppRestart.offer()
                        }
                    }
                    if shell.isOpen {
                        divider
                        row(L("Резервные копии"), L("Создание и восстановление")) {
                            Button("Управлять") { shell.goBackups() }.buttonStyle(NotesButtonStyle())
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
                    row(L("Файловый режим"), L("Шрифты, подсветка кода, типы файлов")) {
                        Button("Настройки файлов") { shell.goFileSettings() }.buttonStyle(NotesButtonStyle())
                    }
                    divider
                    row(L("Обновления"), L("Локальная сборка обновляется вручную")) {
                        Chip(text: L("Автообновления выключены"))
                    }
                    divider
                    row(AppEdition.displayName, String(format: L("На основе Grizzly %@. © 2026 Slipcast-dev. Изменять и распространять без письменного согласия автора запрещено."), (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")) {
                        EmptyView()
                    }
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
