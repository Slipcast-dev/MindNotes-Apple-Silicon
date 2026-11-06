import AppKit
import CoreText

/// Fonts that come with the app (`Contents/Resources/Fonts`, all under the SIL Open Font License) plus the choice of the
/// reading font. The files are registered for this process only; nothing is installed in the system.
enum FontLibrary {
    /// Families found in the bundled font files, sorted. Registering happens the first time anything asks.
    static let bundledFamilies: [String] = registerBundled()

    private static func registerBundled() -> [String] {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var families = Set<String>()
        for case let url as URL in walker where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            for d in descriptors {
                if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String { families.insert(family) }
            }
        }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The font for a family name from the settings. Any installed or bundled family works; an unknown one gives the system font.
    static func font(family: String, size: CGFloat, bold: Bool = false, italic wantsItalic: Bool = false) -> NSFont {
        _ = bundledFamilies
        let manager = NSFontManager.shared
        let weight = bold ? 9 : 5
        var traits: NSFontTraitMask = []
        if wantsItalic { traits.insert(.italicFontMask) }
        if bold { traits.insert(.boldFontMask) }
        if let font = manager.font(withFamily: family, traits: traits, weight: weight, size: size) { return font }
        // A family without an italic (Inter, Montserrat, Fira Code ...) is slanted artificially, not swapped for another font.
        let upright = manager.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: weight, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return wantsItalic ? italic(upright) : upright
    }

    /// The italic of a font; a font that has none is slanted a little.
    static func italic(_ font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        let converted = manager.convert(font, toHaveTrait: .italicFontMask)
        if manager.traits(of: converted).contains(.italicFontMask) { return converted }
        let slant = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
        return NSFont(descriptor: font.fontDescriptor.withMatrix(slant), size: font.pointSize) ?? font
    }
}
