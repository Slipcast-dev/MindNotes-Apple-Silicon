import AppKit

/// Light styling of Markdown in the editor: headings grow, bold and italic show, highlights are colored, the marks
/// themselves stay visible (dimmed), so the text is still exactly what is saved in the file.
enum MarkdownStyler {
    private static let headingScale: [CGFloat] = [1.6, 1.4, 1.2, 1.1, 1.05, 1.0]

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: []) }
    private static let bold = regex("\\*\\*(?!\\s)([^*\\n]+?)(?<!\\s)\\*\\*")
    private static let italic = regex("(?<![*\\w])\\*(?![\\s*])([^*\\n]+?)(?<![\\s*])\\*(?![*\\w])")
    private static let strike = regex("~~([^~\\n]+?)~~")
    private static let underline = regex("<u>([^\\n]*?)</u>")
    private static let mark = regex("<mark class=\"(violet|pink|orange|mint|blue)\">([^\\n]*?)</mark>")
    private static let code = regex("`([^`\\n]+)`")
    private static let listMarker = regex("^[ \\t]*([-*+]|\\d+\\.)[ \\t]+(\\[[ xX]\\][ \\t]+)?")
    private static let align = regex("^(<div align=\"(?:left|center|right|justify)\">)(.*)(</div>)$")

    static func apply(to storage: NSTextStorage, base: NSFont, textColor: NSColor, theme: Theme) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.setAttributes([.font: base, .foregroundColor: textColor], range: full)
        guard ns.length > 0 else { return }

        let dim = NSColor(theme.secondary)
        let manager = NSFontManager.shared
        func font(_ traits: NSFontTraitMask, from f: NSFont) -> NSFont { manager.convert(f, toHaveTrait: traits) }
        func dimMarks(_ m: NSTextCheckingResult, inner: Int) {
            // Everything of the match that is not the inner group is a mark.
            let inside = m.range(at: inner)
            let lead = NSRange(location: m.range.location, length: inside.location - m.range.location)
            let trail = NSRange(location: NSMaxRange(inside), length: NSMaxRange(m.range) - NSMaxRange(inside))
            storage.addAttribute(.foregroundColor, value: dim, range: lead)
            storage.addAttribute(.foregroundColor, value: dim, range: trail)
        }

        // Line by line: fences, headings, quotes, lists, alignment wrappers.
        var inFence = false
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 10 { contentEnd -= 1 }
            let line = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            let text = ns.substring(with: line)
            location = NSMaxRange(lineRange)

            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                storage.addAttributes([.foregroundColor: dim, .backgroundColor: NSColor(theme.codeBackground)], range: line)
                continue
            }
            if inFence {
                storage.addAttributes([.foregroundColor: NSColor(theme.codeText), .backgroundColor: NSColor(theme.codeBackground)], range: line)
                continue
            }
            var level = 0
            for ch in text { if ch == "#" { level += 1 } else { break } }
            if (1...6).contains(level), text.dropFirst(level).first == " " {
                let size = base.pointSize * headingScale[level - 1]
                let headingFont = font(.boldFontMask, from: NSFont(descriptor: base.fontDescriptor, size: size) ?? base)
                storage.addAttributes([.font: headingFont, .foregroundColor: NSColor(theme.heading)], range: line)
                storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: line.location, length: level))
            } else if text.hasPrefix(">") {
                storage.addAttribute(.foregroundColor, value: dim, range: line)
                storage.addAttribute(.foregroundColor, value: NSColor(theme.accent), range: NSRange(location: line.location, length: 1))
            } else if let m = listMarker.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                storage.addAttribute(.foregroundColor, value: NSColor(theme.accent),
                                     range: NSRange(location: line.location + m.range.location, length: m.range.length))
            }
            if let m = align.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                for g in [1, 3] {
                    let r = m.range(at: g)
                    storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: line.location + r.location, length: r.length))
                }
            }
        }

        // Inline marks anywhere in the text (code fences are skipped by their background).
        func fenced(_ r: NSRange) -> Bool {
            storage.attribute(.backgroundColor, at: r.location, effectiveRange: nil) != nil
                && (storage.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor) == NSColor(theme.codeText)
        }
        for m in bold.matches(in: storage.string, range: full) where !fenced(m.range) {
            let inner = m.range(at: 1)
            storage.enumerateAttribute(.font, in: inner) { value, r, _ in
                storage.addAttribute(.font, value: font(.boldFontMask, from: value as? NSFont ?? base), range: r)
            }
            dimMarks(m, inner: 1)
        }
        for m in italic.matches(in: storage.string, range: full) where !fenced(m.range) {
            storage.enumerateAttribute(.font, in: m.range(at: 1)) { value, r, _ in
                storage.addAttribute(.font, value: FontLibrary.italic(value as? NSFont ?? base), range: r)
            }
            dimMarks(m, inner: 1)
        }
        for m in strike.matches(in: storage.string, range: full) where !fenced(m.range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            dimMarks(m, inner: 1)
        }
        for m in underline.matches(in: storage.string, range: full) where !fenced(m.range) {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            dimMarks(m, inner: 1)
        }
        for m in mark.matches(in: storage.string, range: full) where !fenced(m.range) {
            let index = InlineMarkup.highlightNames.firstIndex(of: ns.substring(with: m.range(at: 1))) ?? 0
            storage.addAttribute(.backgroundColor, value: TextBuilder.highlightColor(index, dark: theme.isDark), range: m.range(at: 2))
            dimMarks(m, inner: 2)
        }
        for m in code.matches(in: storage.string, range: full) where !fenced(m.range) {
            storage.addAttribute(.backgroundColor, value: NSColor(theme.codeBackground), range: m.range)
        }
    }
}
