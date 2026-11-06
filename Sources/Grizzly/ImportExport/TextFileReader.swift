import Foundation

/// Чтение текстового файла только для просмотра и импорта: оригинал никогда не меняется.
enum TextFileReader {
    static let maxSize = 32 * 1024 * 1024

    static func read(_ url: URL) throws -> (text: String, encoding: String) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxSize else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, "UTF-8") }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return (s, "UTF-16") }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        if let s = String(data: data, encoding: .windowsCP1251) { return (s, "Windows-1251") }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
