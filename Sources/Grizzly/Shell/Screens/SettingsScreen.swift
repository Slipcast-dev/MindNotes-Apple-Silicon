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
                    Group {
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
                        .onChange(of: language) { new in
                            new.apply()
                            AppRestart.offer()
                        }
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
                    row(AppEdition.displayName, String(format: L("На основе Grizzly %@. © 2026 Slipcast-dev. Изменять и распространять без письменного согласия автора запрещено."), (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")) {
                        EmptyView()
                    }
                }
                .padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))

                Text("Пространства").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 10)
                VStack(spacing: 0) {
                    ForEach(shell.knownWorkspaces) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(item.exists ? item.path : L("Папка не найдена")).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if item.path == shell.workspaceRoot?.path {
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
