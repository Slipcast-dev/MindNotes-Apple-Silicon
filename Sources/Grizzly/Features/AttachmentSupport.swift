import AppKit
import AVFoundation
import PDFKit

extension NSAttributedString.Key {
    /// A line that is an attachment (photo, video, PDF, file); the value is an `AttachmentInfo`.
    static let grizzlyAttachment = NSAttributedString.Key("grizzlyAttachment")
    /// The text of a link to a web page; the value is its address.
    static let grizzlyLink = NSAttributedString.Key("grizzlyLink")
}

extension Notification.Name {
    /// A video preview finished loading: attachments are drawn again.
    static let grizzlyAttachmentReady = Notification.Name("grizzlyAttachmentReady")
}

/// What User mode draws for an attachment line.
final class AttachmentInfo: NSObject {
    let kind: AttachmentKind
    let title: String
    let url: URL?

    init(kind: AttachmentKind, title: String, url: URL?) {
        self.kind = kind
        self.title = title
        self.url = url
    }

    var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}

/// Previews of attachments, made once per file version.
enum AttachmentCache {
    static let maxWidth: CGFloat = 520
    static let maxHeight: CGFloat = 380

    private struct Photo { let image: NSImage; let pixels: CGSize }
    private static var photos: [String: Photo] = [:]
    private static var videos: [String: NSImage] = [:]
    private static var requested: Set<String> = []
    private static var generators: [String: AVAssetImageGenerator] = [:]
    private static var pdfs: [String: (NSImage, Int)] = [:]

    private static func key(_ url: URL) -> String {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return url.path + "|" + String(date?.timeIntervalSince1970 ?? 0)
    }

    /// A photo scaled down for the screen, and its size in pixels (orientation applied).
    private static func photo(_ url: URL) -> Photo? {
        let k = key(url)
        if let cached = photos[k] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1300,
              ] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var w = CGFloat((props?[kCGImagePropertyPixelWidth] as? Int) ?? thumb.width)
        var h = CGFloat((props?[kCGImagePropertyPixelHeight] as? Int) ?? thumb.height)
        if let o = props?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let entry = Photo(image: NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height)), pixels: CGSize(width: w, height: h))
        photos[k] = entry
        return entry
    }

    private static func video(_ url: URL) -> NSImage? {
        let k = key(url)
        if let cached = videos[k] { return cached }
        if requested.insert(k).inserted {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1100, height: 1100)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            generators[k] = generator
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.5, preferredTimescale: 600))]) { _, cg, _, _, _ in
                DispatchQueue.main.async {
                    if let cg { videos[k] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
                    generators[k] = nil
                    NotificationCenter.default.post(name: .grizzlyAttachmentReady, object: nil)
                }
            }
        }
        return nil
    }

    private static func pdf(_ url: URL) -> (NSImage, Int)? {
        let k = key(url)
        if let cached = pdfs[k] { return cached }
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let entry = (page.thumbnail(of: CGSize(width: 150, height: 190), for: .mediaBox), document.pageCount)
        pdfs[k] = entry
        return entry
    }

    /// Height of the line that carries the attachment.
    static func height(for info: AttachmentInfo) -> CGFloat {
        guard info.exists, let url = info.url else { return 44 }
        switch info.kind {
        case .image:
            guard let p = photo(url), p.pixels.width > 0, p.pixels.height > 0 else { return 44 }
            return imageSize(p.pixels).height
        case .video: return (maxWidth * 9 / 16).rounded()
        case .pdf: return 96
        case .file: return 56
        }
    }

    private static func imageSize(_ pixels: CGSize) -> CGSize {
        let scale = min(1, maxWidth / pixels.width, maxHeight / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }

    // MARK: Drawing

    static func draw(_ info: AttachmentInfo, in frame: NSRect, theme: Theme) {
        let secondary = NSColor(theme.secondary)
        func card(_ rect: NSRect) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSColor(theme.codeBackground).withAlphaComponent(0.7).setFill()
            path.fill()
            NSColor(theme.rule).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        func text(_ s: String, at p: NSPoint, size: CGFloat, bold: Bool = false, color: NSColor, width: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: style,
            ]).draw(in: NSRect(x: p.x, y: p.y, width: width, height: size * 1.5))
        }

        guard info.exists, let url = info.url else {
            let rect = NSRect(x: frame.minX, y: frame.minY, width: min(frame.width, 360), height: 36)
            card(rect)
            text("⚠︎  " + L("Файл не найден") + ": " + info.title, at: NSPoint(x: rect.minX + 12, y: rect.minY + 9), size: 13, color: NSColor(theme.warning), width: rect.width - 24)
            return
        }
        switch info.kind {
        case .image:
            guard let p = photo(url) else { return }
            let size = imageSize(p.pixels)
            let rect = NSRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            p.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            NSColor(theme.rule).setStroke()
            let outline = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            outline.lineWidth = 0.5
            outline.stroke()
        case .video:
            let rect = NSRect(x: frame.minX, y: frame.minY, width: min(frame.width, maxWidth), height: frame.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
            NSColor.black.setFill()
            rect.fill()
            if let thumb = video(url) {
                // Fill the frame, cropping what does not fit.
                let s = max(rect.width / thumb.size.width, rect.height / thumb.size.height)
                let target = NSSize(width: thumb.size.width * s, height: thumb.size.height * s)
                thumb.draw(in: NSRect(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2, width: target.width, height: target.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSRect(x: rect.minX, y: rect.maxY - 30, width: rect.width, height: 30).fill()
            NSGraphicsContext.restoreGraphicsState()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.white.withAlphaComponent(0.88).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)).fill()
            NSColor.black.withAlphaComponent(0.75).setFill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: center.x - 8, y: center.y - 12))
            triangle.line(to: NSPoint(x: center.x - 8, y: center.y + 12))
            triangle.line(to: NSPoint(x: center.x + 14, y: center.y))
            triangle.close()
            triangle.fill()
            text("▶︎  " + info.title, at: NSPoint(x: rect.minX + 12, y: rect.maxY - 25), size: 12.5, bold: true, color: .white, width: rect.width - 24)
        case .pdf:
            let rect = NSRect(x: frame.minX, y: frame.minY, width: min(frame.width, 380), height: frame.height)
            card(rect)
            var textX = rect.minX + 14
            var pages = 0
            if let (thumb, count) = pdf(url) {
                pages = count
                let h = rect.height - 16
                let w = min(thumb.size.width * h / max(thumb.size.height, 1), 70)
                thumb.draw(in: NSRect(x: rect.minX + 10, y: rect.minY + 8, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                textX = rect.minX + 10 + w + 12
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            text(info.title, at: NSPoint(x: textX, y: rect.minY + 26), size: 14, bold: true, color: NSColor(theme.text), width: rect.maxX - textX - 12)
            text("PDF" + (pages > 0 ? " · " + L("%lld стр.", pages) : "") + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                 at: NSPoint(x: textX, y: rect.minY + 50), size: 12, color: secondary, width: rect.maxX - textX - 12)
        case .file:
            let rect = NSRect(x: frame.minX, y: frame.minY, width: min(frame.width, 380), height: frame.height)
            card(rect)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.draw(in: NSRect(x: rect.minX + 10, y: rect.minY + 8, width: 40, height: 40), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            text(info.title, at: NSPoint(x: rect.minX + 62, y: rect.minY + 10), size: 14, bold: true, color: NSColor(theme.text), width: rect.width - 74)
            text(url.pathExtension.uppercased() + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                 at: NSPoint(x: rect.minX + 62, y: rect.minY + 31), size: 12, color: secondary, width: rect.width - 74)
        }
    }
}

/// Puts attached files next to the document and writes the Markdown for them.
enum AttachmentStore {
    /// Files larger than this are not copied: the document points at them where they are.
    static let copyLimit: Int64 = 300 * 1024 * 1024

    private static func assets(for document: URL) -> URL {
        document.deletingLastPathComponent().appendingPathComponent(Attachments.assetsFolderName(for: document), isDirectory: true)
    }

    private static func uniqueURL(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// The path to write into the document for `source`: relative to the document after copying into `<name>.assets`,
    /// or the absolute path for a file that is too large to copy.
    static func place(_ source: URL, for document: URL) throws -> String {
        let folder = assets(for: document)
        let src = source.standardizedFileURL.path
        if src.hasPrefix(folder.standardizedFileURL.path + "/") { return Attachments.assetsFolderName(for: document) + "/" + source.lastPathComponent }
        let size = (try? FileManager.default.attributesOfItem(atPath: src))?[.size] as? Int64 ?? 0
        if size > copyLimit { return src }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = uniqueURL(source.lastPathComponent, in: folder)
        try FileManager.default.copyItem(at: source, to: target)
        return Attachments.assetsFolderName(for: document) + "/" + target.lastPathComponent
    }

    /// A pasted picture (a screenshot, an image copied from a web page).
    static func place(imageData: Data, ext: String, for document: URL) throws -> String {
        let folder = assets(for: document)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let target = uniqueURL("Image \(f.string(from: Date())).\(ext)", in: folder)
        try imageData.write(to: target)
        return Attachments.assetsFolderName(for: document) + "/" + target.lastPathComponent
    }
}
