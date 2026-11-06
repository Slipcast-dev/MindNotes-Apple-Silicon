import AppKit

/// Оформление редактора. Цвета передаёт оболочка: слой редактора не зависит от неё.
struct BlockTextStyle {
    var ink: NSColor = .labelColor
    var muted: NSColor = .secondaryLabelColor
    var accent: NSColor = .controlAccentColor
    var line: NSColor = .separatorColor

    static let taskIndent: CGFloat = 24
    static let checkboxSize: CGFloat = 14

    func font(for type: BlockType) -> NSFont {
        switch type {
        case .heading1: return .systemFont(ofSize: 26, weight: .bold)
        case .heading2: return .systemFont(ofSize: 21, weight: .semibold)
        case .heading3: return .systemFont(ofSize: 17, weight: .semibold)
        default: return .systemFont(ofSize: 14)
        }
    }

    func paragraphStyle(for type: BlockType) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch type {
        case .heading1, .heading2, .heading3:
            style.lineSpacing = 2
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 6
        case .task:
            style.lineSpacing = 5
            style.paragraphSpacing = 9
            style.firstLineHeadIndent = Self.taskIndent
            style.headIndent = Self.taskIndent
        default:
            style.lineSpacing = 5 // Интерлиньяж макета: 1,6.
            style.paragraphSpacing = 9
        }
        return style
    }

    func attributes(for type: BlockType) -> [NSAttributedString.Key: Any] {
        [.font: font(for: type), .foregroundColor: ink, .paragraphStyle: paragraphStyle(for: type)]
    }

    /// Текст блока для вида: перенос строки внутри блока — U+2028, разделитель блоков — "\n".
    func render(_ block: Block) -> NSAttributedString {
        guard let content = block.content else { return unsupported(block) }
        let out = NSMutableAttributedString()
        let base = attributes(for: block.type)
        for run in content.runs {
            var attrs = base
            let font = base[.font] as? NSFont ?? .systemFont(ofSize: 14)
            let manager = NSFontManager.shared
            var styled = font
            if run.marks.contains("b") { styled = manager.convert(styled, toHaveTrait: .boldFontMask) }
            if run.marks.contains("i") { styled = manager.convert(styled, toHaveTrait: .italicFontMask) }
            if run.marks.contains("code") { styled = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular) }
            attrs[.font] = styled
            if run.marks.contains("u") { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.marks.contains("s") { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: BlockTextMapping.toView(run.text), attributes: attrs))
        }
        return out
    }

    /// Неизвестный блок — один неделимый символ: показывается, не правится и не теряется (FR-05).
    private func unsupported(_ block: Block) -> NSAttributedString {
        let title = NSLocalizedString("Блок не поддерживается этой версией", comment: "")
        let text = block.plainText.isEmpty ? title : "\(title): \(block.plainText)"
        let attachment = NSTextAttachment()
        let cell = UnsupportedBlockCell(text: text, ink: muted, line: line)
        attachment.attachmentCell = cell
        return NSAttributedString(attachment: attachment)
    }
}

/// Плашка неизвестного блока, также заглушка для таблиц и встроенных баз до их реализации.
final class UnsupportedBlockCell: NSTextAttachmentCell {
    private let text: String
    private let ink: NSColor
    private let line: NSColor

    init(text: String, ink: NSColor, line: NSColor) {
        self.text = text
        self.ink = ink
        self.line = line
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellSize() -> NSSize { NSSize(width: 480, height: 40) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -12) }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let box = frame.insetBy(dx: 0.5, dy: 0.5)
        line.setStroke()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(in: NSRect(x: frame.minX + 12, y: frame.midY - size.height / 2, width: frame.width - 24, height: size.height + 2), withAttributes: attrs)
    }
}

enum BlockTextMapping {
    static let lineBreak = "\u{2028}"

    static func toView(_ model: String) -> String { model.replacingOccurrences(of: "\n", with: lineBreak) }
    static func toModel(_ view: String) -> String { view.replacingOccurrences(of: lineBreak, with: "\n") }
}
