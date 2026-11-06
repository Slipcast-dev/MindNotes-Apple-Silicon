import AppKit

/// Оформление редактора. Цвета передаёт оболочка: слой редактора не зависит от неё.
struct BlockTextStyle {
    var ink: NSColor = .labelColor
    var muted: NSColor = .secondaryLabelColor
    var accent: NSColor = .controlAccentColor
    var line: NSColor = .separatorColor
    var soft: NSColor = .quaternaryLabelColor

    static let markerIndent: CGFloat = 24
    static let nestIndent: CGFloat = 24
    static let checkboxSize: CGFloat = 14

    /// Палитра цветов текста и маркера (название, цвет текста, фон; светлая и тёмная темы совпадают по смыслу).
    static let colors: [(name: String, title: String, text: UInt32, background: UInt32)] = [
        ("gray", "Серый", 0x787774, 0xE9E9E7), ("brown", "Коричневый", 0x9F6B53, 0xEEE0DA), ("orange", "Оранжевый", 0xD9730D, 0xFAEBDD),
        ("yellow", "Жёлтый", 0xCB912F, 0xFBF3DB), ("green", "Зелёный", 0x448361, 0xDDEDEA), ("blue", "Синий", 0x337EA9, 0xDDEBF1),
        ("purple", "Фиолетовый", 0x9065B0, 0xEAE4F2), ("pink", "Розовый", 0xC14C8A, 0xF4DFEB), ("red", "Красный", 0xD44C47, 0xFBE4E4),
    ]

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    func font(for type: BlockType) -> NSFont {
        switch type {
        case .heading1: return .systemFont(ofSize: 26, weight: .bold)
        case .heading2: return .systemFont(ofSize: 21, weight: .semibold)
        case .heading3: return .systemFont(ofSize: 17, weight: .semibold)
        case .code: return .monospacedSystemFont(ofSize: 13, weight: .regular)
        default: return .systemFont(ofSize: 14)
        }
    }

    /// Отступы текста от края блока: место для маркера, полоски или фона.
    static func leading(for type: BlockType) -> CGFloat {
        switch type {
        case .task, .bullet, .numbered, .toggle: return markerIndent
        case .quote: return 16
        case .callout: return 44
        case .code: return 14
        default: return 0
        }
    }

    func paragraphStyle(for type: BlockType, depth: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = Self.leading(for: type) + CGFloat(depth) * Self.nestIndent
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        switch type {
        case .heading1, .heading2, .heading3:
            style.lineSpacing = 2
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 6
        case .callout:
            style.lineSpacing = 5
            style.tailIndent = -14
            style.paragraphSpacingBefore = 12
            style.paragraphSpacing = 21
        case .code:
            style.lineSpacing = 3
            style.tailIndent = -14
            style.paragraphSpacingBefore = 12
            style.paragraphSpacing = 21
        default:
            style.lineSpacing = 5 // Интерлиньяж макета: 1,6.
            style.paragraphSpacing = 9
        }
        return style
    }

    func attributes(for type: BlockType, depth: Int) -> [NSAttributedString.Key: Any] {
        [.font: font(for: type), .foregroundColor: type == .quote ? muted : ink, .paragraphStyle: paragraphStyle(for: type, depth: depth)]
    }

    /// Текст блока для вида: перенос строки внутри блока — U+2028, разделитель блоков — "\n".
    func render(_ block: Block, depth: Int) -> NSAttributedString {
        guard let content = block.content else { return atom(block, depth: depth) }
        let out = NSMutableAttributedString()
        let base = attributes(for: block.type, depth: depth)
        for run in content.runs {
            out.append(NSAttributedString(string: BlockTextMapping.toView(run.text), attributes: attributes(base: base, marks: run.marks)))
        }
        return out
    }

    func attributes(base: [NSAttributedString.Key: Any], marks: [String]) -> [NSAttributedString.Key: Any] {
        var attrs = base
        let font = base[.font] as? NSFont ?? .systemFont(ofSize: 14)
        let manager = NSFontManager.shared
        var styled = font
        if marks.contains("b") { styled = manager.convert(styled, toHaveTrait: .boldFontMask) }
        if marks.contains("i") { styled = manager.convert(styled, toHaveTrait: .italicFontMask) }
        if marks.contains("code") {
            styled = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
            attrs[.backgroundColor] = soft
        }
        attrs[.font] = styled
        if marks.contains("u") { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if marks.contains("s") { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        for mark in marks {
            if mark.hasPrefix("c:"), let c = Self.colors.first(where: { "c:\($0.name)" == mark }) { attrs[.foregroundColor] = Self.rgb(c.text) }
            if mark.hasPrefix("bg:"), let c = Self.colors.first(where: { "bg:\($0.name)" == mark }) {
                attrs[.backgroundColor] = Self.rgb(c.background)
                attrs[.foregroundColor] = attrs[.foregroundColor] ?? ink
            }
            if mark.hasPrefix("a:"), let url = URL(string: String(mark.dropFirst(2))) {
                attrs[.link] = url
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        return attrs
    }

    /// Неделимый блок — один символ: показывается, не правится посимвольно и не теряется (FR-05).
    private func atom(_ block: Block, depth: Int) -> NSAttributedString {
        let attachment = NSTextAttachment()
        if block.type == .divider {
            attachment.attachmentCell = DividerCell(line: line)
        } else {
            let title = NSLocalizedString("Блок не поддерживается этой версией", comment: "")
            let text = block.plainText.isEmpty ? title : "\(title): \(block.plainText)"
            attachment.attachmentCell = UnsupportedBlockCell(text: text, ink: muted, line: line)
        }
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttribute(.paragraphStyle, value: paragraphStyle(for: .paragraph, depth: depth), range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// Разделитель на всю ширину строки.
final class DividerCell: NSTextAttachmentCell {
    private let line: NSColor

    init(line: NSColor) {
        self.line = line
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: -2, width: max(1, lineFrag.width - position.x - 1), height: 17)
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        line.setFill()
        NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: 1).fill()
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
