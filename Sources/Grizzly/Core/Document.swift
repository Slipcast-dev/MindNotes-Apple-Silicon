import Foundation

struct Document: Identifiable, Hashable {
    var id = UUID()
    var libraryID: UUID?
    let url: URL
    let type: FileType
    let encoding: String
    let text: String
    /// `text` with \n line endings: what the editor shows.
    let normalized: String
    let lines: [String]
    let csv: CSVTable?
    /// Syntax scanner state at the start of each line (open block comment or multi-line string); empty if unused.
    let syntaxStates: [Int]
    /// Modification date of the file when it was read; used to notice outside changes.
    var modified: Date?

    var name: String { url.lastPathComponent }
    var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }

    init(url: URL) throws {
        let loaded = try FileLoader.read(url)
        self.url = url
        self.type = FileType(url: url)
        self.encoding = loaded.encoding
        self.text = loaded.text
        self.normalized = loaded.text.replacingOccurrences(of: "\r\n", with: "\n")
        self.lines = normalized.components(separatedBy: "\n")
        self.modified = Document.modificationDate(url)
        let lines = self.lines
        self.syntaxStates = SyntaxEngine.states(lines, type: type)
        self.csv = type == .csv
            ? CSVTable(lines: lines, delimiter: CSVTable.detectDelimiter(url: url, lines: lines))
            : nil
    }

    static func modificationDate(_ url: URL) -> Date? {
        // URL caches resource values, so ask the file system directly.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // Includes the content: SwiftUI skips views whose input compares equal, and a reloaded document (same id,
    // new text after a save) must not be mistaken for the old one.
    static func == (a: Document, b: Document) -> Bool {
        a.id == b.id && a.modified == b.modified && a.text.utf8.count == b.text.utf8.count && a.encoding == b.encoding
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}
