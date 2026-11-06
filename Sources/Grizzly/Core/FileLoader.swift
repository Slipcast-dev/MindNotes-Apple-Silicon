import AppKit
import Foundation

enum FileLoader {
    /// Reads a file and decodes it, trying UTF-8, UTF-16 (BOM) and then legacy 8-bit encodings.
    static func read(_ url: URL) throws -> (text: String, encoding: String) {
        if url.pathExtension.lowercased() == "rtf",
           let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return (attributed.string, "RTF")
        }
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return (s, "UTF-8")
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return (s, "UTF-16")
        }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        if let s = String(data: data, encoding: .windowsCP1251) { return (s, "Windows-1251") }
        if let s = String(data: data, encoding: .isoLatin1) { return (s, "ISO-8859-1") }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// Inverse of `read`: writes the text back in the encoding the file was read with (a UTF-8 BOM is kept).
    /// Throws `.fileWriteInapplicableStringEncoding` when the text has characters the encoding cannot hold.
    static func write(_ text: String, to url: URL, encoding: String) throws {
        let data: Data
        switch encoding {
        case "UTF-8":
            let hadBOM = (try? Data(contentsOf: url, options: .mappedIfSafe))?.starts(with: [0xEF, 0xBB, 0xBF]) ?? false
            data = (hadBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
        case "UTF-16":
            guard let body = text.data(using: .utf16LittleEndian) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            data = Data([0xFF, 0xFE]) + body
        case "Windows-1251":
            guard let body = text.data(using: .windowsCP1251) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            data = body
        case "ISO-8859-1":
            guard let body = text.data(using: .isoLatin1) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            data = body
        case "RTF":
            // Plain text is written back as a plain RTF document: the original formatting is not kept.
            let attributed = NSAttributedString(string: text)
            guard let body = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            data = body
        default:
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }
}
