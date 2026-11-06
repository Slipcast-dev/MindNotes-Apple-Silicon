import Foundation

/// The inline formatting that Markdown itself does not have: underline (`<u>text</u>`) and the five soft highlight
/// colors (`<mark class="violet">text</mark>`). Bold, italic, strikethrough and code are plain Markdown.
///
/// The system Markdown parser knows nothing about these tags, so they are swapped for private-use characters first;
/// the parser leaves those alone, and the text builder turns each pair into an attribute and removes the characters.
enum InlineMarkup {
    static let highlightNames = ["violet", "pink", "orange", "mint", "blue"]

    static let underlineOpen: UInt16 = 0xE000
    static let underlineClose: UInt16 = 0xE001
    static let markBase: UInt16 = 0xE010
    static let markClose: UInt16 = 0xE01F

    static func isSentinel(_ unit: UInt16) -> Bool { unit >= 0xE000 && unit <= 0xE01F }

    /// Replaces the tags outside code spans with their placeholder characters.
    static func prepare(_ source: String) -> String {
        guard source.contains("<") else { return source }
        let parts = source.components(separatedBy: "`")
        var out = ""
        for (i, part) in parts.enumerated() {
            if i > 0 { out += "`" }
            // Odd pieces sit between two backticks: code, left alone (an unclosed backtick opens no code span).
            let isCode = i % 2 == 1 && i < parts.count - 1
            out += isCode ? part : replaceTags(in: part)
        }
        return out
    }

    private static func replaceTags(in s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "<u>", with: String(utf16CodeUnits: [underlineOpen], count: 1))
        t = t.replacingOccurrences(of: "</u>", with: String(utf16CodeUnits: [underlineClose], count: 1))
        t = t.replacingOccurrences(of: "</mark>", with: String(utf16CodeUnits: [markClose], count: 1))
        for (i, name) in highlightNames.enumerated() {
            t = t.replacingOccurrences(of: "<mark class=\"\(name)\">", with: String(utf16CodeUnits: [markBase + UInt16(i)], count: 1))
        }
        return t
    }

    /// The text without the placeholder characters.
    static func stripped(_ s: String) -> String {
        let units = s.utf16.filter { !isSentinel($0) }
        return units.count == s.utf16.count ? s : String(utf16CodeUnits: Array(units), count: units.count)
    }
}
