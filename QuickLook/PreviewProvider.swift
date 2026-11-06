import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look extension: Space in Finder shows the file as styled HTML, without opening Grizzly.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Previews are capped so that a huge log does not freeze Finder.
    private static let maxBytes = 2_000_000

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let html = try Self.render(url)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 900)) { _ in
            Data(html.utf8)
        }
        reply.stringEncoding = .utf8
        return reply
    }

    private static func render(_ url: URL) throws -> String {
        var (text, _) = try FileLoader.read(url)
        var truncated = false
        if text.utf8.count > maxBytes {
            text = String(text.prefix(maxBytes))
            truncated = true
        }
        let lines = text.components(separatedBy: .newlines)
        let body: String
        switch FileType(url: url) {
        case .markdown: body = HTMLRenderer.markdown(lines)
        case .csv: body = HTMLRenderer.csv(url: url, lines: lines)
        default: body = HTMLRenderer.code(lines)
        }
        let note = truncated ? "<p class=\"note\">Показано начало файла / Showing the beginning of the file</p>" : ""
        return HTMLRenderer.page(title: url.lastPathComponent, body: body + note)
    }
}
