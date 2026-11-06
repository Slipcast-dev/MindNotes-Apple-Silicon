import SwiftUI
import AppKit

/// Helpers shared by the editor: the reading font and the highlight colors.
enum TextBuilder {
    static func font(_ prefs: Preferences, size: CGFloat, bold: Bool = false) -> NSFont {
        if prefs.fontName == Preferences.systemFont {
            return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
        return FontLibrary.font(family: prefs.fontName, size: size, bold: bold)
    }

    /// The five soft highlight colors; one `<mark class="…">` name each (see `InlineMarkup.highlightNames`).
    static func highlightColor(_ index: Int, dark: Bool) -> NSColor {
        let palette: [UInt32] = [0xB39DFF, 0xFF9EC4, 0xFFB070, 0x8FE3C0, 0x8EC5FF]
        let hex = palette[min(max(index, 0), palette.count - 1)]
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: dark ? 0.42 : 0.55)
    }
}

// MARK: - Line numbers

/// Gutter with line numbers; a click on a number toggles the bookmark of that line.
final class LineNumberRuler: NSRulerView {
    var lineStarts: [Int] = [0]
    var bookmarks: Set<Int> = [] { didSet { needsDisplay = true } }
    var onToggle: ((Int) -> Void)?
    var numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var numberColor = NSColor.secondaryLabelColor
    var bookmarkColor = NSColor.systemOrange
    var background = NSColor.textBackgroundColor

    func setText(_ text: String) {
        var starts = [0]
        var i = 0
        for u in text.utf16 { i += 1; if u == 10 { starts.append(i) } }
        lineStarts = starts
        needsDisplay = true
    }

    /// 1-based line that contains the UTF-16 offset.
    private func line(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        background.setFill()
        bounds.fill()
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer,
              let clip = scrollView?.contentView else { return }
        let origin = tv.textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: clip.bounds, in: tc)
        let ns = tv.string as NSString
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, fragGlyphs, _ in
            let ch = lm.characterIndexForGlyph(at: fragGlyphs.location)
            guard ch == 0 || ns.character(at: ch - 1) == 10 else { return }
            let n = self.line(at: ch)
            let on = self.bookmarks.contains(n)
            let label = NSAttributedString(string: "\(n)", attributes: [
                .font: self.numberFont, .foregroundColor: on ? self.bookmarkColor : self.numberColor])
            let size = label.size()
            let y = self.convert(NSPoint(x: 0, y: frag.minY + origin.y), from: tv).y
            label.draw(at: NSPoint(x: self.bounds.width - size.width - 10, y: y + (frag.height - size.height) / 2))
            if on {
                self.bookmarkColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 8, y: y + frag.height / 2 - 3.5, width: 7, height: 7)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = clientView as? NSTextView else { return }
        let p = tv.convert(event.locationInWindow, from: nil)
        let ch = tv.characterIndexForInsertion(at: NSPoint(x: tv.textContainerOrigin.x + 1, y: p.y))
        onToggle?(line(at: min(ch, (tv.string as NSString).length)))
    }
}

