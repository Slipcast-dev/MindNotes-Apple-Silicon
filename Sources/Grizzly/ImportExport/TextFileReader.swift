import Foundation

/// Чтение текстового файла только для просмотра и импорта: оригинал никогда не меняется.
enum TextFileReader {
    static let maxSize = 32 * 1024 * 1024

    static func read(_ url: URL) throws -> (text: String, encoding: String) {
        let data = try Data(contentsOf: url)
        guard data.count <= maxSize else { throw CocoaError(.fileReadTooLarge) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, "UTF-8") }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return (s, "UTF-16") }
        // Нулевой байт вне UTF-16 означает двоичный файл; однобайтовая кодировка приняла бы его как текст.
        guard !data.prefix(8192).contains(0) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        if let s = String(data: data, encoding: .windowsCP1251) { return (s, "Windows-1251") }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
