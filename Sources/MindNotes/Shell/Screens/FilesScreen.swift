import AppKit
import SwiftUI

/// Раздел «Импорт»: откуда импортировать и недавние файлы с просмотром. Оригиналы не меняются.
/// Прежний раздел «Файлы» стал его нижней частью.
struct FilesScreen: View {
    @EnvironmentObject private var shell: ShellModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Перенос в пространство"))
                ScreenTitle(text: L("Импорт")).padding(.top, 8).padding(.bottom, 9)
                Text("Файлы переносятся в пространство страницами и базами. Сами файлы не меняются.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 20)
                if shell.isOpen {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                        source(L("Markdown или текст"), L("Файл .md или .txt становится страницей"), "doc.text", .text)
                        source(L("Таблица CSV"), L("Строки становятся записями базы"), "tablecells", .table)
                        source(L("Папка"), L("Папки и файлы — дерево страниц"), "folder", .folder)
                        source(L("Экспорт Notion"), L("Архив .zip из Notion со связями"), "shippingbox", .notion)
                    }
                } else {
                    Text("Откройте пространство, чтобы импортировать в него файлы. Посмотреть файл можно и сейчас.")
                        .font(.system(size: 13)).foregroundColor(Tokens.muted)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Недавние файлы").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("Посмотреть файл…") { shell.presentOpenFile() }.buttonStyle(NotesButtonStyle())
                }
                .padding(.top, 28)
                if shell.recentFiles.isEmpty {
                    Text("Здесь появятся файлы, которые вы открывали для просмотра.")
                        .font(.system(size: 13)).foregroundColor(Tokens.muted).padding(.top, 10)
                }
                if !shell.recentFiles.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(shell.recentFiles, id: \.self) { url in
                            HStack(spacing: 10) {
                                Text(url.pathExtension.uppercased().prefix(4))
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.soft))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(url.deletingLastPathComponent().path).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button("Предпросмотр") { shell.previewFile(url) }.buttonStyle(NotesButtonStyle())
                                if shell.isOpen {
                                    Button("Импортировать") { shell.importFile(url) }.buttonStyle(NotesButtonStyle())
                                }
                                Button("Убрать из списка") { shell.forgetFile(url) }
                                    .buttonStyle(NotesButtonStyle(kind: .plain))
                                    .help("Файл на диске не удаляется")
                            }
                            .padding(.vertical, 11)
                        }
                    }
                    .padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
        .sheet(item: $shell.preview) { FilePreviewSheet(preview: $0) }
    }

    private func source(_ title: String, _ detail: String, _ symbol: String, _ kind: ShellModel.ImportKind) -> some View {
        Button { shell.presentImport(kind) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundColor(Tokens.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(Tokens.ink)
                    Text(detail).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FilePreview: Identifiable {
    let url: URL
    let text: String
    let encoding: String
    var id: URL { url }
}

struct FilePreviewSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    let preview: FilePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.url.lastPathComponent).font(Tokens.titleFont(28))
            Text(String(format: L("Файл на диске · %@ · строк: %d"), preview.encoding, preview.text.split(separator: "\n", omittingEmptySubsequences: false).count))
                .font(.system(size: 12))
                .foregroundColor(Tokens.muted)
            ScrollView {
                Text(preview.text.prefix(200_000))
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Tokens.line))
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
                if shell.isOpen {
                    Button("Импортировать в пространство") {
                        dismiss()
                        shell.importFile(preview.url)
                    }
                    .buttonStyle(NotesButtonStyle(kind: .primary))
                }
            }
        }
        .padding(23)
        .frame(width: 680, height: 560)
        .background(Tokens.paper)
    }
}
