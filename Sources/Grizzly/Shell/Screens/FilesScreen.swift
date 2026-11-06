import AppKit
import SwiftUI

/// Раздел «Файлы», когда ни один файл не открыт. Файлы остаются на диске; импорта здесь нет.
struct FilesScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var library: LibraryStore

    private var recent: [LibraryFile] {
        Array(library.allFiles.sorted { ($0.lastOpened ?? .distantPast, $0.name) > ($1.lastOpened ?? .distantPast, $1.name) }.prefix(20))
    }

    /// Папка библиотеки: виртуальная, на диске ничего не создаётся.
    private func newFolder() {
        let alert = NSAlert()
        alert.messageText = L("Новая папка")
        alert.informativeText = L("Папка появится в библиотеке файлов. На диске ничего не создаётся.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("Название")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("Создать"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !library.folderExists(name) else {
            shell.errorMessage = String(format: L("Папка «%@» уже есть."), name)
            return
        }
        _ = library.createFolder(name)
        shell.showsLibrary = true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Файловый режим"))
                ScreenTitle(text: L("Файлы")).padding(.top, 8).padding(.bottom, 9)
                Text("Работайте с Markdown и текстом на диске.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                HStack(spacing: 9) {
                    Button("Открыть файл…") { state.presentOpenPanel() }.buttonStyle(NotesButtonStyle(kind: .primary))
                    Button("Новый файл…") { state.presentNewFilePanel() }.buttonStyle(NotesButtonStyle())
                    Button("Новая папка…") { newFolder() }.buttonStyle(NotesButtonStyle())
                    Button("Добавить папку с диска…") { state.presentFolderPanel() }.buttonStyle(NotesButtonStyle())
                    Button(shell.showsLibrary ? "Скрыть библиотеку" : "Библиотека") { shell.showsLibrary.toggle() }
                        .buttonStyle(NotesButtonStyle(kind: .plain))
                }
                if !recent.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(recent) { file in
                            HStack(spacing: 10) {
                                Text(URL(fileURLWithPath: file.path).pathExtension.uppercased().prefix(4))
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.soft))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(file.path).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button("Открыть") { state.open(urls: [URL(fileURLWithPath: file.path)]) }
                                    .buttonStyle(NotesButtonStyle())
                            }
                            .padding(.vertical, 11)
                        }
                    }
                    .padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
                    .padding(.top, 24)
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
        .background(Tokens.paper)
    }
}
