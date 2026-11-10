import AppKit
import SwiftUI

struct BackupsScreen: View {
    @EnvironmentObject private var shell: ShellModel

    private func detail(_ item: ShellModel.BackupItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        return "\(item.automatic ? L("Автоматическая копия") : L("Ручная копия")) · \(size)"
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Хранение данных"))
                ScreenTitle(text: L("Резервные копии")).padding(.top, 8).padding(.bottom, 9)
                Text("Архив включает страницы и вложения. Копия на том же диске не защищает от его отказа: сохраняйте её и на другой носитель.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                HStack(spacing: 9) {
                    Button("Создать копию") { shell.makeBackup() }.buttonStyle(NotesButtonStyle(kind: .primary))
                    Button("Сохранить копию как…") { shell.makeBackupAs() }.buttonStyle(NotesButtonStyle())
                    Button("Восстановить из архива…") { shell.presentRestore() }.buttonStyle(NotesButtonStyle())
                }
                .disabled(shell.busyMessage != nil)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Автоматические копии", isOn: $shell.autoBackupEnabled)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Раз в сутки, пока пространство открыто. Хранятся 7 дневных и 4 недельные копии; ручные копии не удаляются.")
                        .font(.system(size: 12)).foregroundColor(Tokens.muted)
                    HStack(spacing: 9) {
                        Text(shell.autoBackupFolder?.path ?? L("Папка приложения на этом диске"))
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Другая папка…") { shell.chooseAutoBackupFolder() }.buttonStyle(NotesButtonStyle())
                        if shell.autoBackupFolder != nil {
                            Button("По умолчанию") { shell.resetAutoBackupFolder() }.buttonStyle(NotesButtonStyle(kind: .plain))
                        }
                    }
                    .disabled(!shell.autoBackupEnabled)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
                .padding(.top, 24)

                if !shell.backups.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(shell.backups) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.soft))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dateText(item.date)).font(.system(size: 14, weight: .semibold))
                                    Text(detail(item)).font(.system(size: 12)).foregroundColor(Tokens.muted)
                                }
                                Spacer()
                                Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    .buttonStyle(NotesButtonStyle(kind: .plain))
                                Button("Восстановить…") { shell.presentRestore(archive: item.url) }
                                    .buttonStyle(NotesButtonStyle())
                            }
                            .padding(.vertical, 11)
                        }
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
                    .padding(.top, 24)
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
    }
}
