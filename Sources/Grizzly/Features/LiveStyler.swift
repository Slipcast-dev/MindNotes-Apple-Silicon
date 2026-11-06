import AppKit

extension NSAttributedString.Key {
    /// Characters of formatting code that User mode does not show.
    static let grizzlyHidden = NSAttributedString.Key("grizzlyHidden")
    /// The marker drawn in place of a list marker (the value is the glyph).
    static let grizzlyBullet = NSAttributedString.Key("grizzlyBullet")
    /// A check list line; the value is the index of the character between the brackets.
    static let grizzlyTaskBox = NSAttributedString.Key("grizzlyTaskBox")
    static let grizzlyQuoteBar = NSAttributedString.Key("grizzlyQuoteBar")
    static let grizzlyRule = NSAttributedString.Key("grizzlyRule")
    /// A `|` of a table row, drawn as a cell border.
    static let grizzlyPipe = NSAttributedString.Key("grizzlyPipe")
    /// Table line: 0 header, 1 separator, 2 body row.
    static let grizzlyTableRow = NSAttributedString.Key("grizzlyTableRow")
    /// A heading that can be folded (the value is the section key); `grizzlyFoldOpen` tells the arrow's direction.
    static let grizzlyFold = NSAttributedString.Key("grizzlyFold")
    static let grizzlyFoldOpen = NSAttributedString.Key("grizzlyFoldOpen")
    static let grizzlyCode = NSAttributedString.Key("grizzlyCode")
}

/// "User mode" of the editor: the text of the file stays exactly as it is, but the formatting code is made invisible and
/// the document is drawn the way it reads: headings, bold, lists with real markers, check boxes, quotes with a bar,
/// dividers, tables with borders. The marks come back in Developer mode.
enum LiveStyler {
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let bold = regex("\\*\\*(?!\\s)([^*\\n]+?)(?<!\\s)\\*\\*")
    private static let italic = regex("(?<![*\\w])\\*(?![\\s*])([^*\\n]+?)(?<![\\s*])\\*(?![*\\w])")
    private static let strike = regex("~~([^~\\n]+?)~~")
    private static let underline = regex("<u>([^\\n]*?)</u>")
    private static let mark = regex("<mark class=\"(violet|pink|orange|mint|blue)\">([^\\n]*?)</mark>")
    private static let code = regex("`([^`\\n]+)`")
    private static let link = regex("\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")
    private static let listMarker = regex("^([ \\t]*)([-*+]|\\d+\\.)[ \\t]+(\\[([ xX])\\][ \\t]+)?")
    private static let rule = regex("^[ \\t]*([-*_])([ \\t]*\\1){2,}[ \\t]*$")
    private static let alignTag = regex("<div align=\"(left|center|right|justify)\">(.*)</div>$")

    private static func isSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|") && t.allSatisfy { "|-: ".contains($0) }
    }

    private struct Line {
        let content: NSRange
        let full: NSRange
        let text: String
    }

    static func apply(to storage: NSTextStorage, base: NSFont, textColor: NSColor, theme: Theme, collapsed: Set<String>,
                      document: URL? = nil) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.setAttributes([.font: base, .foregroundColor: textColor], range: full)
        guard ns.length > 0 else { return }

        let size = base.pointSize
        let dim = NSColor(theme.secondary)
        let tiny = NSFont.systemFont(ofSize: 0.01)
        let mono = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)

        func hide(_ r: NSRange) {
            guard r.length > 0 else { return }
            storage.addAttributes([.font: tiny, .foregroundColor: NSColor.clear, .grizzlyHidden: true], range: r)
        }
        func paragraph(first: CGFloat = 0, head: CGFloat = 0, align: NSTextAlignment = .natural, before: CGFloat = 0,
                       after: CGFloat = 0, spacing: CGFloat = 0, minHeight: CGFloat = 0, maxHeight: CGFloat = 0) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.firstLineHeadIndent = first
            s.headIndent = head
            s.alignment = align
            s.paragraphSpacingBefore = before
            s.paragraphSpacing = after
            s.lineSpacing = spacing
            s.minimumLineHeight = minHeight
            s.maximumLineHeight = maxHeight
            return s
        }

        // Lines.
        var lines: [Line] = []
        var location = 0
        while location < ns.length {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(full)
            if end > full.location, ns.character(at: end - 1) == 10 { end -= 1 }
            let content = NSRange(location: full.location, length: end - full.location)
            lines.append(Line(content: content, full: full, text: ns.substring(with: content)))
            location = NSMaxRange(full)
        }

        // What each line is: code fence / code, table row, foldable heading, folded away.
        var inCode = [Bool](repeating: false, count: lines.count)
        var isFence = [Bool](repeating: false, count: lines.count)
        var open = false
        for (i, l) in lines.enumerated() {
            if l.text.trimmingCharacters(in: .whitespaces).hasPrefix("```") { isFence[i] = true; inCode[i] = true; open.toggle() }
            else if open { inCode[i] = true }
        }
        var tableKind = [Int?](repeating: nil, count: lines.count)
        var i = 0
        while i + 1 < lines.count {
            if !inCode[i], !inCode[i + 1], lines[i].text.contains("|"), isSeparator(lines[i + 1].text) {
                tableKind[i] = 0
                tableKind[i + 1] = 1
                var k = i + 2
                while k < lines.count, !inCode[k], lines[k].text.contains("|"), !lines[k].text.trimmingCharacters(in: .whitespaces).isEmpty {
                    tableKind[k] = 2
                    k += 1
                }
                i = k
            } else {
                i += 1
            }
        }
        func headingInfo(_ text: String) -> (level: Int, title: String, markerEnd: Int)? {
            let trimmedLead = text.prefix { $0 == " " || $0 == "\t" }.count
            let body = text.dropFirst(trimmedLead)
            var level = 0
            for ch in body { if ch == "#" { level += 1 } else { break } }
            guard (1...6).contains(level), body.dropFirst(level).first == " " else { return nil }
            let rest = body.dropFirst(level).trimmingCharacters(in: .whitespaces)
            let skip = body.dropFirst(level).prefix { $0 == " " }.count
            return (level, MarkdownParser.splitAlignment(rest).1, trimmedLead + level + skip)
        }
        var foldHidden = [Bool](repeating: false, count: lines.count)
        var foldKey = [String?](repeating: nil, count: lines.count)
        var seen: [String: Int] = [:]
        var foldedLevel: Int?
        for (n, l) in lines.enumerated() where !inCode[n] {
            if let h = headingInfo(l.text) {
                if let f = foldedLevel, h.level <= f { foldedLevel = nil }
                if foldedLevel != nil { foldHidden[n] = true; continue }
                if h.level <= 2 {
                    let base = "\(h.level)|\(h.title)"
                    let count = seen[base, default: 0]
                    seen[base] = count + 1
                    let key = "\(base)|\(count)"
                    foldKey[n] = key
                    if collapsed.contains(key) { foldedLevel = h.level }
                }
            } else if foldedLevel != nil {
                foldHidden[n] = true
            }
        }
        // Hidden lines inside code blocks of a folded section.
        for n in lines.indices where foldedLevel != nil && inCode[n] && n > 0 && foldHidden[n - 1] { foldHidden[n] = true }

        for (n, l) in lines.enumerated() {
            let c = l.content
            if foldHidden[n] {
                hide(l.full)
                storage.addAttribute(.paragraphStyle, value: paragraph(minHeight: 1, maxHeight: 1), range: l.full)
                continue
            }
            if isFence[n] {
                hide(l.full)
                storage.addAttribute(.paragraphStyle, value: paragraph(minHeight: 4, maxHeight: 4), range: l.full)
                continue
            }
            if inCode[n] {
                storage.addAttributes([.font: mono, .foregroundColor: NSColor(theme.codeText), .backgroundColor: NSColor(theme.codeBackground),
                                       .grizzlyCode: true, .paragraphStyle: paragraph(first: 10, head: 10)], range: l.full)
                continue
            }
            if let kind = tableKind[n] {
                let cellFont = mono
                storage.addAttributes([.font: kind == 0 ? NSFontManager.shared.convert(cellFont, toHaveTrait: .boldFontMask) : cellFont,
                                       .grizzlyTableRow: kind, .paragraphStyle: paragraph(minHeight: size * 1.9)], range: l.full)
                if kind == 1 {
                    storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 2, weight: .regular), .foregroundColor: NSColor.clear,
                                           .grizzlyHidden: true, .paragraphStyle: paragraph(minHeight: 1, maxHeight: 1)], range: l.full)
                } else {
                    var k = c.location
                    while k < NSMaxRange(c) {
                        if ns.character(at: k) == 124 {
                            storage.addAttributes([.foregroundColor: NSColor.clear, .grizzlyPipe: true], range: NSRange(location: k, length: 1))
                        }
                        k += 1
                    }
                }
                continue
            }
            let text = l.text
            let nsText = text as NSString
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line between blocks is only a small gap.
                storage.addAttribute(.paragraphStyle, value: paragraph(minHeight: size * 0.45, maxHeight: size * 0.45), range: l.full)
                continue
            }
            if let att = Attachments.parse(line: text) {
                // A photo, video, PDF or file: the line is replaced by its picture or card.
                let info = AttachmentInfo(kind: att.kind, title: att.title.isEmpty ? (Attachments.decode(att.target) as NSString).lastPathComponent : att.title,
                                          url: Attachments.resolve(target: att.target, relativeTo: document))
                let height = AttachmentCache.height(for: info) + 10
                hide(l.full)
                storage.addAttributes([.grizzlyAttachment: info, .paragraphStyle: paragraph(minHeight: height, maxHeight: height)], range: l.full)
                continue
            }
            if rule.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) != nil {
                hide(l.full)
                storage.addAttributes([.grizzlyRule: true, .paragraphStyle: paragraph(minHeight: size * 1.4, maxHeight: size * 1.4)], range: l.full)
                continue
            }

            var align: NSTextAlignment = .natural
            var first: CGFloat = 0, head: CGFloat = 0
            var before: CGFloat = 0
            var after = size * 0.5
            var lineFont = base
            var bodyStart = 0   // where the visible text starts in the line

            if let h = headingInfo(text) {
                hide(NSRange(location: c.location, length: h.markerEnd))
                bodyStart = h.markerEnd
                let scale: [CGFloat] = [1.8, 1.5, 1.28, 1.15, 1.05, 1.0]
                lineFont = NSFontManager.shared.convert(NSFont(descriptor: base.fontDescriptor, size: size * scale[h.level - 1]) ?? base, toHaveTrait: .boldFontMask)
                storage.addAttributes([.font: lineFont, .foregroundColor: NSColor(theme.heading)],
                                      range: NSRange(location: c.location + bodyStart, length: c.length - bodyStart))
                before = size * (h.level <= 2 ? 0.7 : 0.4)
                after = size * 0.2
                if let key = foldKey[n] {
                    // The arrow of a foldable heading is drawn in the left margin.
                    storage.addAttributes([.grizzlyFold: key, .grizzlyFoldOpen: !collapsed.contains(key)], range: NSRange(location: c.location, length: max(h.markerEnd, 1)))
                }
            } else if text.hasPrefix(">") {
                let skip = text.hasPrefix("> ") ? 2 : 1
                hide(NSRange(location: c.location, length: skip))
                bodyStart = skip
                storage.addAttributes([.foregroundColor: dim, .grizzlyQuoteBar: true], range: NSRange(location: c.location + skip, length: c.length - skip))
                storage.addAttribute(.grizzlyQuoteBar, value: true, range: NSRange(location: c.location, length: skip))
                first = 18; head = 18
                after = size * 0.15
            } else if let m = listMarker.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let lead = m.range(at: 1).length
                let marker = nsText.substring(with: m.range(at: 2))
                let isNumber = marker.first?.isNumber == true
                let hasBox = m.range(at: 3).location != NSNotFound
                if isNumber {
                    storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: c.location + lead, length: m.range(at: 2).length))
                    head = 26
                } else {
                    hide(NSRange(location: c.location, length: m.range.length))
                    let done = hasBox && nsText.substring(with: m.range(at: 4)).lowercased() == "x"
                    let glyph = hasBox ? (done ? "◉" : "○") : (marker == "-" ? "–" : "•")
                    storage.addAttribute(.grizzlyBullet, value: glyph, range: NSRange(location: c.location, length: m.range.length))
                    if hasBox {
                        let boxIndex = c.location + m.range(at: 4).location
                        storage.addAttribute(.grizzlyTaskBox, value: boxIndex, range: NSRange(location: c.location, length: m.range.length))
                        if done {
                            let r = NSRange(location: c.location + m.range.length, length: c.length - m.range.length)
                            storage.addAttributes([.foregroundColor: dim, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: r)
                        }
                    }
                    first = CGFloat(lead) * 6 + 24; head = first
                    bodyStart = m.range.length
                }
                after = size * 0.25
            }

            // Alignment wrapper: <div align="center">…</div>
            let bodyRange = NSRange(location: bodyStart, length: nsText.length - bodyStart)
            if let m = alignTag.firstMatch(in: text, range: bodyRange), m.range(at: 1).location != NSNotFound {
                switch nsText.substring(with: m.range(at: 1)) {
                case "center": align = .center
                case "right": align = .right
                case "justify": align = .justified
                default: align = .left
                }
                let openLen = "<div align=\"\(nsText.substring(with: m.range(at: 1)))\">".count
                hide(NSRange(location: c.location + m.range.location, length: openLen))
                hide(NSRange(location: c.location + NSMaxRange(m.range) - 6, length: 6))
            }
            storage.addAttribute(.paragraphStyle, value: paragraph(first: first, head: head, align: align, before: before, after: after, spacing: size * 0.3), range: l.full)
        }

        // Inline marks, anywhere outside code.
        func plain(_ r: NSRange) -> Bool {
            r.length > 0 && storage.attribute(.grizzlyCode, at: r.location, effectiveRange: nil) == nil
                && storage.attribute(.grizzlyHidden, at: r.location, effectiveRange: nil) == nil
        }
        func hideAround(_ m: NSTextCheckingResult, inner: Int) {
            let inside = m.range(at: inner)
            hide(NSRange(location: m.range.location, length: inside.location - m.range.location))
            hide(NSRange(location: NSMaxRange(inside), length: NSMaxRange(m.range) - NSMaxRange(inside)))
        }
        func restyle(_ r: NSRange, _ change: (NSFont) -> NSFont) {
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                storage.addAttribute(.font, value: change(value as? NSFont ?? base), range: sub)
            }
        }
        let string = storage.string
        for m in bold.matches(in: string, range: full) where plain(m.range) {
            restyle(m.range(at: 1)) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            hideAround(m, inner: 1)
        }
        for m in italic.matches(in: string, range: full) where plain(m.range) {
            restyle(m.range(at: 1)) { FontLibrary.italic($0) }
            hideAround(m, inner: 1)
        }
        for m in strike.matches(in: string, range: full) where plain(m.range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            hideAround(m, inner: 1)
        }
        for m in underline.matches(in: string, range: full) where plain(m.range) {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            hideAround(m, inner: 1)
        }
        for m in mark.matches(in: string, range: full) where plain(m.range) {
            let index = InlineMarkup.highlightNames.firstIndex(of: ns.substring(with: m.range(at: 1))) ?? 0
            storage.addAttribute(.backgroundColor, value: TextBuilder.highlightColor(index, dark: theme.isDark), range: m.range(at: 2))
            hideAround(m, inner: 2)
        }
        for m in code.matches(in: string, range: full) where plain(m.range) {
            storage.addAttributes([.font: mono, .backgroundColor: NSColor(theme.codeBackground)], range: m.range(at: 1))
            hideAround(m, inner: 1)
        }
        for m in link.matches(in: string, range: full) where plain(m.range) {
            storage.addAttributes([.foregroundColor: NSColor(theme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .grizzlyLink: ns.substring(with: m.range(at: 2))], range: m.range(at: 1))
            hide(NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
        }

        // Table columns: the hidden marks have no width, so the padding of the source no longer lines the columns up.
        // Every cell is stretched to the widest cell of its column.
        var n = 0
        while n < lines.count {
            guard tableKind[n] == 0 else { n += 1; continue }
            var rows = [n]
            var k = n + 2
            while k < lines.count, tableKind[k] == 2 { rows.append(k); k += 1 }
            let grid: [[NSRange]] = rows.map { r in
                let c = lines[r].content
                let pipes = (c.location..<NSMaxRange(c)).filter { ns.character(at: $0) == 124 }
                return zip(pipes, pipes.dropFirst()).map { NSRange(location: $0 + 1, length: $1 - $0 - 1) }
            }
            var widths = [CGFloat](repeating: 0, count: grid.map(\.count).max() ?? 0)
            for row in grid {
                for (c, r) in row.enumerated() where r.length > 0 { widths[c] = max(widths[c], storage.attributedSubstring(from: r).size().width) }
            }
            for row in grid {
                for (c, r) in row.enumerated() where r.length > 0 {
                    let extra = widths[c] - storage.attributedSubstring(from: r).size().width
                    if extra > 0.5 { storage.addAttribute(.kern, value: extra, range: NSRange(location: NSMaxRange(r) - 1, length: 1)) }
                }
            }
            n = k
        }
    }
}

/// Draws what User mode shows in place of the hidden code: list markers and check boxes, quote bars, dividers,
/// table borders and the folding arrows.
final class LiveLayoutManager: NSLayoutManager {
    var live = false
    var theme: Theme?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard live, let storage = textStorage, let container = textContainers.first, let theme, storage.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let secondary = NSColor(theme.secondary), border = NSColor(theme.rule), accent = NSColor(theme.accent)

        func fragment(_ char: Int) -> NSRect {
            lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: min(char, storage.length - 1)), effectiveRange: nil)
        }
        /// Draws a marker in the left margin of the line, on the baseline of the text that follows `after`.
        func draw(_ glyph: String, after char: Int, x: CGFloat, color: NSColor, scale: CGFloat = 1) {
            let target = min(char, storage.length - 1)
            let bodyFont = (storage.attribute(.font, at: target, effectiveRange: nil) as? NSFont).flatMap { $0.pointSize > 4 ? $0 : nil }
                ?? NSFont.systemFont(ofSize: 14)
            let font = NSFont(descriptor: NSFont.systemFont(ofSize: 14).fontDescriptor, size: bodyFont.pointSize * scale) ?? bodyFont
            let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color])
            let g = glyphIndexForCharacter(at: target)
            let rect = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let baseline = origin.y + rect.minY + location(forGlyphAt: g).y
            text.draw(at: NSPoint(x: origin.x + rect.minX + x, y: baseline - font.ascender))
        }

        storage.enumerateAttribute(.grizzlyBullet, in: chars) { value, range, _ in
            guard let glyph = value as? String else { return }
            let done = glyph == "◉"
            draw(glyph, after: NSMaxRange(range), x: max(2, textStorageIndent(range.location, storage) - 20),
                 color: done ? accent : secondary, scale: glyph == "•" ? 1.3 : 1.05)
        }
        storage.enumerateAttribute(.grizzlyAttachment, in: chars) { value, range, _ in
            guard let info = value as? AttachmentInfo else { return }
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                let frame = NSRect(x: origin.x + rect.minX + 2, y: origin.y + rect.minY + 5,
                                   width: min(AttachmentCache.maxWidth, container.size.width - 4), height: rect.height - 10)
                AttachmentCache.draw(info, in: frame, theme: theme)
            }
        }
        storage.enumerateAttribute(.grizzlyQuoteBar, in: chars) { value, range, _ in
            guard value != nil else { return }
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                accent.withAlphaComponent(0.7).setFill()
                NSRect(x: origin.x + rect.minX + 4, y: origin.y + rect.minY, width: 3, height: rect.height).fill()
            }
        }
        storage.enumerateAttribute(.grizzlyRule, in: chars) { value, range, _ in
            guard value != nil else { return }
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                border.setFill()
                NSRect(x: origin.x + rect.minX, y: origin.y + rect.midY, width: container.size.width - container.lineFragmentPadding * 2, height: 1).fill()
            }
        }
        storage.enumerateAttribute(.grizzlyFold, in: chars) { value, range, _ in
            guard value != nil else { return }
            let open = (storage.attribute(.grizzlyFoldOpen, at: range.location, effectiveRange: nil) as? Bool) ?? true
            draw(open ? "▾" : "▸", after: NSMaxRange(range), x: -18, color: secondary, scale: 0.85)
        }
        // Table lines: the attribute is the same on neighbouring rows, so each line fragment is handled on its own.
        storage.enumerateAttribute(.grizzlyTableRow, in: chars) { value, range, _ in
            guard value != nil else { return }
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, glyphs, _ in
                let lineChars = self.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                guard lineChars.length > 0, let kind = storage.attribute(.grizzlyTableRow, at: lineChars.location, effectiveRange: nil) as? Int,
                      kind != 1 else { return }
                var pipes: [CGFloat] = []
                storage.enumerateAttribute(.grizzlyPipe, in: lineChars) { pipe, r, _ in
                    guard pipe != nil else { return }
                    let box = self.boundingRect(forGlyphRange: self.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: container)
                    pipes.append(origin.x + box.midX)
                }
                guard let left = pipes.first, let right = pipes.last, right > left else { return }
                let top = origin.y + rect.minY, bottom = origin.y + rect.maxY
                if kind == 0 {
                    NSColor(theme.codeBackground).setFill()
                    NSRect(x: left, y: top, width: right - left, height: bottom - top).fill()
                }
                border.setFill()
                for x in pipes { NSRect(x: x - 0.25, y: top, width: 0.5, height: bottom - top).fill() }
                NSRect(x: left, y: bottom - 0.5, width: right - left, height: 0.5).fill()
                if kind == 0 { NSRect(x: left, y: top, width: right - left, height: 0.5).fill() }
            }
        }
    }

    /// The first-line indent of the paragraph that contains the character.
    private func textStorageIndent(_ char: Int, _ storage: NSTextStorage) -> CGFloat {
        ((storage.attribute(.paragraphStyle, at: char, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent) ?? 0
    }
}
