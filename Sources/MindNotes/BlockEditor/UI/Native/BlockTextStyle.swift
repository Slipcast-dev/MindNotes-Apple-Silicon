import AppKit
import UniformTypeIdentifiers

/// Оформление редактора. Цвета передаёт оболочка: слой редактора не зависит от неё.
struct BlockTextStyle {
    var ink: NSColor = .labelColor
    var muted: NSColor = .secondaryLabelColor
    var accent: NSColor = .controlAccentColor
    var line: NSColor = .separatorColor
    var soft: NSColor = .quaternaryLabelColor
    /// Плашка неделимого блока, которую строит контроллер: изображение, файл, таблица.
    var atomCell: ((Block) -> NSTextAttachmentCell?)?

    /// Атрибут текста упоминания: набор рядом с ним не перенимает его оформление.
    static let mentionKey = NSAttributedString.Key("MindNotesMention")
    static let markerIndent: CGFloat = 24
    static let nestIndent: CGFloat = 24
    static let checkboxSize: CGFloat = 14

    /// Палитра цветов текста и маркера (название, цвет текста, фон; светлая и тёмная темы совпадают по смыслу).
    static let colors: [(name: String, title: String, text: UInt32, background: UInt32)] = [
        ("gray", "Серый", 0x787774, 0xE9E9E7), ("brown", "Коричневый", 0x9F6B53, 0xEEE0DA), ("orange", "Оранжевый", 0xD9730D, 0xFAEBDD),
        ("yellow", "Жёлтый", 0xCB912F, 0xFBF3DB), ("green", "Зелёный", 0x448361, 0xDDEDEA), ("blue", "Синий", 0x337EA9, 0xDDEBF1),
        ("purple", "Фиолетовый", 0x9065B0, 0xEAE4F2), ("pink", "Розовый", 0xC14C8A, 0xF4DFEB), ("red", "Красный", 0xD44C47, 0xFBE4E4),
    ]

    /// Фон палитры по имени цвета: в тёмной теме — приглушённый, чтобы светлый текст читался.
    static func background(of name: String) -> NSColor? {
        guard let c = colors.first(where: { $0.name == name }) else { return nil }
        let light = rgb(c.background), dark = rgb(c.text).withAlphaComponent(0.28)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static func text(of name: String) -> NSColor? { colors.first { $0.name == name }.map { rgb($0.text) } }

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
        var base = attributes(for: block.type, depth: depth)
        // Цвет текста блока; собственный цвет отрезка (метка c:) важнее.
        if let color = content.color, !BlockColor.isBackground(color), let ink = Self.text(of: color) { base[.foregroundColor] = ink }
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
        if marks.contains(Mention.flag) {
            // Упоминание — плашка: видно, что это одно целое, а не набранный текст.
            attrs[.backgroundColor] = soft
            attrs[.foregroundColor] = marks.contains { PageLink.page(fromMark: $0) != nil } ? ink : accent
            attrs[Self.mentionKey] = true
        }
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
        if let cell = atomCell?(block) {
            attachment.attachmentCell = cell
        } else if block.type == .divider {
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

/// Изображение на ширину текста.
final class ImageBlockCell: NSTextAttachmentCell {
    private let picture: NSImage?
    private let loading: Bool
    private let soft: NSColor
    private let name: String
    private let ink: NSColor
    private let line: NSColor

    init(picture: NSImage?, loading: Bool, name: String, ink: NSColor, line: NSColor, soft: NSColor) {
        self.picture = picture
        self.loading = loading
        self.soft = soft
        self.name = name
        self.ink = ink
        self.line = line
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(40, lineFrag.width - position.x - 1)
        guard let picture, picture.size.width > 0 else { return NSRect(x: 0, y: -8, width: min(available, 420), height: 40) }
        let width = min(available, picture.size.width)
        return NSRect(x: 0, y: 0, width: width, height: width * picture.size.height / picture.size.width)
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        guard let picture else {
            if loading {
                soft.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9).fill()
                return
            }
            line.setStroke()
            NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).stroke()
            let text = String(format: NSLocalizedString("Изображение недоступно: %@", comment: ""), name) as NSString
            text.draw(at: NSPoint(x: frame.minX + 12, y: frame.midY - 8), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink])
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
        picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Видео: кадр-обложка со значком воспроизведения и длительностью; нажатие открывает проигрыватель.
final class VideoBlockCell: NSTextAttachmentCell {
    private let poster: NSImage?
    private let loading: Bool
    private let name: String
    private let duration: String?
    private let ink: NSColor
    private let muted: NSColor
    private let line: NSColor
    private let soft: NSColor

    init(poster: NSImage?, loading: Bool, name: String, duration: String?, ink: NSColor, muted: NSColor, line: NSColor, soft: NSColor) {
        self.poster = poster
        self.loading = loading
        self.name = name
        self.duration = duration
        self.ink = ink
        self.muted = muted
        self.line = line
        self.soft = soft
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = min(max(40, lineFrag.width - position.x - 1), 560)
        let aspect = poster.map { $0.size.width > 0 ? $0.size.height / $0.size.width : 9.0 / 16 } ?? 9.0 / 16
        return NSRect(x: 0, y: 0, width: width, height: (width * aspect).rounded())
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let poster {
            poster.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            soft.setFill()
            frame.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if poster == nil, !loading {
            line.setStroke()
            NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
            let text = String(format: NSLocalizedString("Видео недоступно: %@", comment: ""), name) as NSString
            text.draw(at: NSPoint(x: frame.minX + 12, y: frame.minY + 12), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink])
        }
        // Кнопка воспроизведения по центру.
        let radius: CGFloat = 26
        let center = NSPoint(x: frame.midX, y: frame.midY)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: center.x - 8, y: center.y - 12))
        triangle.line(to: NSPoint(x: center.x - 8, y: center.y + 12))
        triangle.line(to: NSPoint(x: center.x + 13, y: center.y))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()
        // Имя и длительность внизу, на тёмной плашке.
        let caption = ([name] + (duration.map { [$0] } ?? [])).joined(separator: " · ") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = caption.size(withAttributes: attributes)
        let badge = NSRect(x: frame.minX + 8, y: frame.maxY - size.height - 14, width: min(size.width + 12, frame.width - 16), height: size.height + 6)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        caption.draw(with: badge.insetBy(dx: 6, dy: 3), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes)
    }
}

/// Файл: значок, имя и размер; нажатие открывает его системным приложением.
final class FileBlockCell: NSTextAttachmentCell {
    private let name: String
    private let detail: String
    private let ink: NSColor
    private let muted: NSColor
    private let line: NSColor

    init(name: String, detail: String, ink: NSColor, muted: NSColor, line: NSColor) {
        self.name = name
        self.detail = detail
        self.ink = ink
        self.muted = muted
        self.line = line
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellSize() -> NSSize { NSSize(width: 420, height: 44) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -14) }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        line.setStroke()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).stroke()
        let icon = NSWorkspace.shared.icon(for: .data)
        icon.draw(in: NSRect(x: frame.minX + 10, y: frame.minY + 8, width: 28, height: 28), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        (name as NSString).draw(in: NSRect(x: frame.minX + 46, y: frame.minY + 6, width: frame.width - 56, height: 17),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink])
        (detail as NSString).draw(at: NSPoint(x: frame.minX + 46, y: frame.minY + 23), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted])
    }
}

/// Простая таблица; нажатие открывает редактор.
/// Что показывает карточка встроенного представления.
struct EmbedSummary: Equatable {
    var title: String
    var lines: [String]
    var total: Int
}

/// Встроенное представление в тексте: заголовок и первые записи. Полный вид открывается нажатием.
final class DatabaseViewBlockCell: NSTextAttachmentCell {
    static let maxLines = 5
    private static let rowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 36
    private let summary: () -> EmbedSummary?
    private let ink: NSColor
    private let muted: NSColor
    private let line: NSColor
    private let soft: NSColor

    init(summary: @escaping () -> EmbedSummary?, ink: NSColor, muted: NSColor, line: NSColor, soft: NSColor) {
        self.summary = summary
        self.ink = ink
        self.muted = muted
        self.line = line
        self.soft = soft
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(40, lineFrag.width - position.x - 1), height: Self.headerHeight + CGFloat(Self.maxLines) * Self.rowHeight + 6)
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let box = frame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        line.setStroke()
        path.stroke()
        let info = summary()
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink]
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: muted]
        let inset: CGFloat = 12
        let width = box.width - inset * 2
        (info?.title ?? NSLocalizedString("Загрузка…", comment: "") as String).draw(in: NSRect(x: box.minX + inset, y: box.minY + 9, width: width - 90, height: 20), withAttributes: bold)
        if let info {
            let count = String(format: NSLocalizedString("Записей: %d", comment: ""), info.total)
            let size = (count as NSString).size(withAttributes: dim)
            count.draw(at: NSPoint(x: box.maxX - inset - size.width, y: box.minY + 10), withAttributes: dim)
            for (i, text) in info.lines.prefix(Self.maxLines).enumerated() {
                let y = box.minY + Self.headerHeight + CGFloat(i) * Self.rowHeight
                soft.setFill()
                NSRect(x: box.minX + inset, y: y - 1, width: width, height: 1).fill()
                text.draw(with: NSRect(x: box.minX + inset, y: y + 3, width: width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: plain)
            }
        }
    }
}

final class TableBlockCell: NSTextAttachmentCell {
    static let rowHeight: CGFloat = 30
    private let rows: [[String]]
    private let ink: NSColor
    private let line: NSColor
    private let soft: NSColor

    init(rows: [[String]], ink: NSColor, line: NSColor, soft: NSColor) {
        self.rows = rows
        self.ink = ink
        self.line = line
        self.soft = soft
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(40, lineFrag.width - position.x - 1), height: CGFloat(max(rows.count, 1)) * Self.rowHeight + 1)
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let columns = max(rows.map(\.count).max() ?? 1, 1)
        let width = (frame.width - 1) / CGFloat(columns)
        if !rows.isEmpty {
            soft.setFill()
            NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.rowHeight).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() {
                let box = NSRect(x: frame.minX + CGFloat(c) * width + 8, y: frame.minY + CGFloat(r) * Self.rowHeight + 7, width: width - 16, height: Self.rowHeight - 10)
                (text as NSString).draw(in: box, withAttributes: attrs)
            }
        }
        line.setStroke()
        let grid = NSBezierPath(rect: NSRect(x: frame.minX + 0.5, y: frame.minY + 0.5, width: frame.width - 1, height: frame.height - 1))
        for c in 1..<max(columns, 1) where columns > 1 {
            grid.move(to: NSPoint(x: frame.minX + CGFloat(c) * width + 0.5, y: frame.minY))
            grid.line(to: NSPoint(x: frame.minX + CGFloat(c) * width + 0.5, y: frame.maxY))
        }
        for r in 1..<max(rows.count, 1) where rows.count > 1 {
            grid.move(to: NSPoint(x: frame.minX, y: frame.minY + CGFloat(r) * Self.rowHeight + 0.5))
            grid.line(to: NSPoint(x: frame.maxX, y: frame.minY + CGFloat(r) * Self.rowHeight + 0.5))
        }
        grid.stroke()
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

/// Закладка (M12): заголовок, описание, адрес и картинка справа, как в Notion. Нажатие открывает адрес в браузере.
final class BookmarkBlockCell: NSTextAttachmentCell {
    private let heading: String
    private let about: String?
    private let address: String
    private let picture: NSImage?
    private let ink: NSColor, muted: NSColor, line: NSColor

    init(title: String, about: String?, address: String, picture: NSImage?, ink: NSColor, muted: NSColor, line: NSColor) {
        self.heading = title
        self.about = about
        self.address = address
        self.picture = picture
        self.ink = ink
        self.muted = muted
        self.line = line
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: min(max(200, lineFrag.width - position.x - 1), 640), height: 96)
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        line.setStroke()
        shape.stroke()
        var textWidth = frame.width - 28
        if let picture, frame.width > 360 {
            let side = NSRect(x: frame.maxX - 170, y: frame.minY + 1, width: 169, height: frame.height - 2)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: side, xRadius: 5, yRadius: 5).addClip()
            let size = picture.size
            let scale = max(side.width / max(size.width, 1), side.height / max(size.height, 1))
            let drawn = NSRect(x: side.midX - size.width * scale / 2, y: side.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
            picture.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            textWidth -= 170
        }
        let left = frame.minX + 14
        (heading as NSString).draw(with: NSRect(x: left, y: frame.minY + 12, width: textWidth, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: ink])
        if let about {
            (about as NSString).draw(with: NSRect(x: left, y: frame.minY + 34, width: textWidth, height: 32), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: muted])
        }
        (address as NSString).draw(with: NSRect(x: left, y: frame.maxY - 24, width: textWidth, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                   attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: ink])
    }
}

/// Встраивание (M12): сервис и адрес; нажатие открывает окно со страницей (ADR-0011), видео — с проигрывателем.
final class EmbedBlockCell: NSTextAttachmentCell {
    private let provider: String
    private let address: String
    private let ink: NSColor, muted: NSColor, line: NSColor, soft: NSColor

    init(provider: String, address: String, ink: NSColor, muted: NSColor, line: NSColor, soft: NSColor) {
        self.provider = provider
        self.address = address
        self.ink = ink
        self.muted = muted
        self.line = line
        self.soft = soft
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = min(max(200, lineFrag.width - position.x - 1), 640)
        return NSRect(x: 0, y: 0, width: width, height: (width * 9 / 16 / 2).rounded())
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        soft.setFill()
        shape.fill()
        line.setStroke()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        let center = NSPoint(x: frame.midX, y: frame.midY - 10)
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: center.x - 9, y: center.y - 12))
        triangle.line(to: NSPoint(x: center.x - 9, y: center.y + 12))
        triangle.line(to: NSPoint(x: center.x + 13, y: center.y))
        triangle.close()
        muted.setFill()
        triangle.fill()
        let caption = String(format: NSLocalizedString("Встраивание: %@", comment: ""), provider) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink]
        let size = caption.size(withAttributes: attrs)
        caption.draw(at: NSPoint(x: frame.midX - min(size.width, frame.width - 24) / 2, y: center.y + 20), withAttributes: attrs)
        (address as NSString).draw(with: NSRect(x: frame.minX + 12, y: frame.maxY - 22, width: frame.width - 24, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                   attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted])
    }
}

/// Подпись синхронизированного блока (ADR-0012): у оригинала — «Синхронизированный блок», у копии — откуда содержимое.
final class SyncedCaptionCell: NSTextAttachmentCell {
    private let text: String
    private let color: NSColor

    init(text: String, color: NSColor) {
        self.text = text
        self.color = color
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    override func cellSize() -> NSSize { NSSize(width: 360, height: 18) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        ("⟳ " + text as NSString).draw(with: frame.insetBy(dx: 2, dy: 1), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color])
    }
}
