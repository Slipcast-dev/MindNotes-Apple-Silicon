import Foundation

/// Расширения (ADR-0015): только описания и картинки, чужой код не исполняется.
struct ExtensionManifest: Equatable, Identifiable {
    enum Kind: Equatable {
        case theme, appIcon
        /// Вид более новой версии или неизвестный: показывается, но не используется.
        case unsupported(String)
    }

    var id: String
    var name: String
    var version: String
    var kind: Kind
    var minApp: AppVersion?

    static func == (a: ExtensionManifest, b: ExtensionManifest) -> Bool { a.id == b.id && a.version == b.version && a.kind == b.kind }

    static let maxFile = 512 * 1024

    static func parse(_ data: Data) -> ExtensionManifest? {
        guard data.count <= maxFile, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? String, !id.isEmpty, id.count <= 120,
              id.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
              let name = o["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let kind = o["kind"] as? String else { return nil }
        let k: Kind
        switch kind {
        case "theme": k = .theme
        case "appIcon": k = .appIcon
        default: k = .unsupported(kind)
        }
        return ExtensionManifest(id: id, name: String(name.prefix(80)), version: (o["version"] as? String) ?? "1.0", kind: k,
                                 minApp: (o["minApp"] as? String).flatMap(AppVersion.init))
    }

    /// Подходит ли этой версии приложения.
    func supported(by app: AppVersion?) -> Bool {
        if case .unsupported = kind { return false }
        guard let minApp, let app else { return true }
        return !(app < minApp)
    }
}

/// Палитра пользовательской темы: те же поля, что у встроенных, цвета `#RRGGBB`.
struct ThemeColors: Equatable {
    static let fields = ["paper", "side", "ink", "muted", "line", "accent", "soft", "card", "primary", "logo", "danger"]

    var light: [String: UInt32]
    var dark: [String: UInt32]

    /// Нужны все поля обоих режимов; одна ошибка — тема не принимается (причина — в `error`).
    static func parse(_ data: Data) -> (colors: ThemeColors?, error: String?) {
        guard data.count <= ExtensionManifest.maxFile, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "theme.json не читается")
        }
        func palette(_ key: String) -> ([String: UInt32]?, String?) {
            guard let p = o[key] as? [String: String] else { return (nil, "нет раздела «\(key)»") }
            var out: [String: UInt32] = [:]
            for field in fields {
                guard let raw = p[field], let value = hex(raw) else { return (nil, "\(key).\(field): нужен цвет #RRGGBB") }
                out[field] = value
            }
            return (out, nil)
        }
        let (light, e1) = palette("light"), (dark, e2) = palette("dark")
        guard let light, let dark else { return (nil, e1 ?? e2) }
        return (ThemeColors(light: light, dark: dark), nil)
    }

    static func hex(_ text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(s, radix: 16)
    }
}
