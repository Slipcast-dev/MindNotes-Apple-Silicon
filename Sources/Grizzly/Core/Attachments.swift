import Foundation

enum AttachmentKind: Equatable { case image, video, pdf, file }

/// Photos, videos, PDF files and other files in a Markdown document. They are ordinary Markdown on a line of their own:
/// `![name](doc.assets/photo.png)` for an image or a video, `[name](doc.assets/paper.pdf)` for a PDF or any other file.
/// Web pages are plain links, `[title](https://example.com)`, and stay inline.
enum Attachments {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]

    static func kind(ofExtension ext: String) -> AttachmentKind {
        let e = ext.lowercased()
        if imageExtensions.contains(e) { return .image }
        if videoExtensions.contains(e) { return .video }
        if e == "pdf" { return .pdf }
        return .file
    }

    struct Parsed: Equatable {
        let kind: AttachmentKind
        let title: String
        /// As written in the file (percent-encoded path or a file URL).
        let target: String
    }

    private static let linePattern = try! NSRegularExpression(pattern: "^(!?)\\[([^\\]]*)\\]\\(([^)\\s]+)\\)$")

    /// A line that is nothing but an image or a link to a local file. Links to web pages and mail are not attachments.
    static func parse(line: String) -> Parsed? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        guard t.hasPrefix("[") || t.hasPrefix("!["),
              let m = linePattern.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let bang = ns.substring(with: m.range(at: 1)) == "!"
        let title = ns.substring(with: m.range(at: 2))
        let target = ns.substring(with: m.range(at: 3))
        let lower = target.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("#") { return nil }
        let ext = (decode(target) as NSString).pathExtension
        var kind = kind(ofExtension: ext)
        // Without the "!" an image or a video is just a link to a file.
        if !bang && (kind == .image || kind == .video) { kind = .file }
        if bang && kind == .pdf { kind = .pdf }
        return Parsed(kind: kind, title: title, target: target)
    }

    /// Spaces, parentheses and non-ASCII letters are written percent-encoded, so the Markdown stays valid.
    static func encode(path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { part in
            String(part).addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? String(part)
        }.joined(separator: "/")
    }

    static func decode(_ target: String) -> String {
        var t = target
        if t.lowercased().hasPrefix("file://") { t = String(t.dropFirst(7)) }
        return t.removingPercentEncoding ?? t
    }

    /// The file a target points to: absolute, or relative to the folder of the document.
    static func resolve(target: String, relativeTo document: URL?) -> URL? {
        let path = decode(target)
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let document else { return nil }
        return document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    /// The folder next to a document that holds its attachments: `Notes.md` -> `Notes.assets`.
    static func assetsFolderName(for document: URL) -> String {
        document.deletingPathExtension().lastPathComponent + ".assets"
    }

    /// The Markdown line for an attached file (`path` is relative to the document, or absolute).
    static func markdown(title: String, path: String, kind: AttachmentKind) -> String {
        let name = title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        let target = encode(path: path)
        return (kind == .image || kind == .video ? "!" : "") + "[\(name)](\(target))"
    }

    /// `[title](address)` for a web page; the address gets https:// when the scheme was left out. Nil for an address that is not a web page.
    static func webLink(title: String, address: String) -> String? {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !a.contains(" ") else { return nil }
        if !a.contains("://") { a = "https://" + a }
        guard let url = URL(string: a), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, host.contains(".") else { return nil }
        let name = (title.isEmpty ? host : title).replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(name)](\(a))"
    }
}

extension RichFormat {
    /// A block (an attachment, a divider) on lines of its own: it replaces an empty line or goes after the current line,
    /// with a blank line in between.
    static func insertBlock(_ block: String, text: String, selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let caret = min(selection.location + selection.length, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 10 { contentEnd -= 1 }
        let line = ns.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        let length = (block as NSString).length
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            let r = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            return TextEdit(range: r, text: block + "\n", selection: NSRange(location: r.location + length + 1, length: 0))
        }
        let insert = "\n\n" + block + "\n"
        return TextEdit(range: NSRange(location: contentEnd, length: 0), text: insert,
                        selection: NSRange(location: contentEnd + (insert as NSString).length, length: 0))
    }

    /// Makes the selected text a link to a web page; with nothing selected the link is inserted with its own title.
    static func linkEdit(_ link: (title: String, address: String), text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""
        guard let markdown = Attachments.webLink(title: selected.isEmpty ? link.title : selected, address: link.address) else { return nil }
        return TextEdit(range: selection, text: markdown, selection: NSRange(location: selection.location + (markdown as NSString).length, length: 0))
    }
}
