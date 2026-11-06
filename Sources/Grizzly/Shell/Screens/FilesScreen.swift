import AppKit
import SwiftUI

/// Раздел «Файлы» по макету: файлы на диске можно посмотреть и импортировать в пространство. Оригиналы не меняются.
struct FilesScreen: View {
    @EnvironmentObject private var shell: ShellModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Файлы на диске"))
                ScreenTitle(text: L("Файлы")).padding(.top, 8).padding(.bottom, 9)
                Text("Посмотрите текстовый файл или импортируйте его как страницу. Сам файл не меняется.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                Button("Открыть файл…") { shell.presentOpenFile() }.buttonStyle(NotesButtonStyle(kind: .primary))
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
        .sheet(item: $shell.preview) { FilePreviewSheet(preview: $0) }
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
