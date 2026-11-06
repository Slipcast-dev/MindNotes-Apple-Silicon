import SwiftUI

/// A quick look into a folder, an archive or a disk image: the list of what is inside, read without opening or unpacking it.
final class ContentsPreviewModel: ObservableObject, Identifiable {
    enum Phase {
        case loading
        case loaded(ContentsListing)
        case failed(String)
    }

    let id = UUID()
    let title: String
    let symbol: String
    /// Where the contents come from on disk; nil for a listing built from the library.
    let url: URL?
    @Published private(set) var phase: Phase = .loading

    /// Reads a folder, archive or disk image in the background.
    init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title ?? url.lastPathComponent
        switch ContentsLister.kind(of: url) {
        case .diskImage: symbol = "opticaldiscdrive"
        case .archive: symbol = "archivebox"
        default: symbol = "folder"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ContentsLister.list(url) }
            DispatchQueue.main.async {
                switch result {
                case .success(let listing): self?.phase = .loaded(listing)
                case .failure(let error): self?.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// A listing that is already known (a folder of the library that does not mirror a directory).
    init(title: String, symbol: String, listing: ContentsListing) {
        self.url = nil
        self.title = title
        self.symbol = symbol
        phase = .loaded(listing)
    }
}

struct ContentsPreviewView: View {
    @ObservedObject var model: ContentsPreviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let url = model.url {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.hoverFilled)
                }
                Spacer()
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.hoverFilled)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(theme.accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(AppFont.title3).lineLimit(1).truncationMode(.middle)
                Text(summary).font(AppFont.callout).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var summary: String {
        switch model.phase {
        case .loading: return L("Читаем содержимое…")
        case .failed: return L("Не удалось прочитать")
        case .loaded(let listing):
            var parts = [L("Файлов: %lld", listing.files), L("Папок: %lld", listing.folders)]
            if listing.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: listing.size, countStyle: .file)) }
            if listing.truncated { parts.append(L("показано не всё")) }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                if model.symbol == "opticaldiscdrive" {
                    Text("Образ диска подключается скрытно и сразу отключается.")
                        .font(AppFont.caption).foregroundColor(.secondary)
                }
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26, weight: .light))
                Text(message).multilineTextAlignment(.center).font(AppFont.callout)
            }
            .foregroundColor(.secondary)
            .padding(24)
        case .loaded(let listing):
            if listing.entries.isEmpty {
                Text("Пусто.").foregroundColor(.secondary)
            } else {
                List(listing.entries, children: \.children) { entry in row(entry) }
                    .listStyle(.inset)
            }
        }
    }

    private func row(_ entry: ContentEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.symbol(for: entry))
                .foregroundColor(entry.isDirectory ? theme.accent : .secondary)
                .frame(width: 18)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = entry.size, size > 0 || !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(AppFont.caption).foregroundColor(.secondary).monospacedDigit()
            }
        }
    }

    private static func symbol(for entry: ContentEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if let type = FileType.extensions[ext] { return type.symbol }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp", "svg", "icns": return "photo"
        case "mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg": return "music.note"
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return "film"
        case "pdf": return "doc.richtext"
        case "app": return "app"
        case "dmg", "iso": return "opticaldiscdrive"
        default: return ContentsLister.isContainer(URL(fileURLWithPath: entry.name)) ? "archivebox" : "doc"
        }
    }
}
