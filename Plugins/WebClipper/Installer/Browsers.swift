import AppKit
import Foundation
import SafariServices

/// Перевод интерфейса установщика: русский или английский по системе.
func tr(_ ru: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? ru : en
}

enum Paths {
    static let pluginID = "minerva.webclipper"
    static let mindNotesBundleID = "local.personal.MindNotes"
    static let safariExtensionID = "local.personal.MindNotes.WebClipper.Extension"

    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    /// Пакет плагина внутри установщика.
    static var payload: URL { Bundle.main.resourceURL!.appendingPathComponent("WebClipper.mnplugin", isDirectory: true) }
    /// Постоянное место расширения для браузеров на Chromium: браузер читает его отсюда при каждом запуске.
    static var chromeExtension: URL { support.appendingPathComponent("MindNotes Web Clipper/chrome", isDirectory: true) }
    static var installedPlugin: URL { support.appendingPathComponent("MindNotes/Extensions/\(pluginID).mnplugin", isDirectory: true) }

    /// Понимает ли эта сборка MindNotes плагины: она объявляет тип пакета .mnplugin (ADR-0019).
    static func supportsPlugins(_ app: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let types = info["UTExportedTypeDeclarations"] as? [[String: Any]] else { return false }
        return types.contains { ($0["UTTypeIdentifier"] as? String) == "local.personal.mindnotes.plugin" }
    }

    static func version(of manifest: URL) -> String? {
        guard let data = try? Data(contentsOf: manifest), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o["version"] as? String
    }
    static var payloadVersion: String { version(of: payload.appendingPathComponent("manifest.json")) ?? "?" }
}

/// Браузер на этом Mac.
struct Browser: Identifiable, Equatable {
    enum Kind: Equatable { case safari, chromium(dataDir: String, extensionsPage: String) }
    var id: String { bundleID }
    var name: String
    var bundleID: String
    var kind: Kind
    var appURL: URL

    static let known: [(String, String, Kind)] = [
        ("Safari", "com.apple.Safari", .safari),
        ("Google Chrome", "com.google.Chrome", .chromium(dataDir: "Google/Chrome", extensionsPage: "chrome://extensions")),
        ("Arc", "company.thebrowser.Browser", .chromium(dataDir: "Arc/User Data", extensionsPage: "chrome://extensions")),
        ("Brave", "com.brave.Browser", .chromium(dataDir: "BraveSoftware/Brave-Browser", extensionsPage: "brave://extensions")),
        ("Microsoft Edge", "com.microsoft.edgemac", .chromium(dataDir: "Microsoft Edge", extensionsPage: "edge://extensions")),
        ("Vivaldi", "com.vivaldi.Vivaldi", .chromium(dataDir: "Vivaldi", extensionsPage: "vivaldi://extensions")),
        ("Opera", "com.operasoftware.Opera", .chromium(dataDir: "com.operasoftware.Opera", extensionsPage: "opera://extensions")),
        ("Яндекс Браузер", "ru.yandex.desktop.yandex-browser", .chromium(dataDir: "Yandex/YandexBrowser", extensionsPage: "browser://extensions")),
        ("Chromium", "org.chromium.Chromium", .chromium(dataDir: "Chromium", extensionsPage: "chrome://extensions")),
    ]

    static func installed() -> [Browser] {
        known.compactMap { name, id, kind in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { Browser(name: name, bundleID: id, kind: kind, appURL: $0) }
        }
    }

    var isSafari: Bool { kind == .safari }

    /// Как MindNotes называет этот браузер в списке подключений (`LocalAPI.browserName`).
    var clientName: String {
        switch bundleID {
        case "com.apple.Safari": return "Safari"
        case "com.microsoft.edgemac": return "Edge"
        case "com.operasoftware.Opera": return "Opera"
        case "ru.yandex.desktop.yandex-browser": return "Yandex"
        case "company.thebrowser.Browser": return "Arc"
        default: return "Chrome"
        }
    }

    /// Браузеры, уже подключённые к MindNotes: надёжный признак, что расширение стоит и работает.
    /// Профиль браузера macOS может не дать прочитать, а список подключений MindNotes доступен всегда.
    static func connectedClientNames() -> Set<String> {
        guard let data = UserDefaults(suiteName: Paths.mindNotesBundleID)?.data(forKey: "plugins.clients"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return Set(list.filter { ($0["plugin"] as? String) == Paths.pluginID }.compactMap { $0["name"] as? String })
    }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Есть ли наше расширение в каком-нибудь профиле браузера: путь из настроек профиля совпадает с нашей папкой.
    func hasChromeExtension() -> Bool {
        guard case .chromium(let dataDir, _) = kind else { return false }
        let root = Paths.support.appendingPathComponent(dataDir, isDirectory: true)
        let target = Paths.chromeExtension.standardizedFileURL.path
        var profiles = [root]
        if let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { profiles += dirs }
        for profile in profiles {
            for name in ["Secure Preferences", "Preferences"] {
                let file = profile.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: file), data.range(of: Data("MindNotes Web Clipper".utf8)) != nil,
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (o["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
                for case let entry as [String: Any] in settings.values {
                    if let path = entry["path"] as? String, URL(fileURLWithPath: path).standardizedFileURL.path == target { return true }
                }
            }
        }
        return false
    }

    /// Открывает страницу расширений браузера.
    func openExtensionsPage() {
        guard case .chromium(_, let page) = kind, let url = URL(string: page) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }
}

/// Safari: расширение живёт внутри этой программы; включить его может только пользователь в настройках Safari.
enum SafariExtension {
    static func isEnabled() async -> Bool {
        await withCheckedContinuation { done in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Paths.safariExtensionID) { state, _ in
                done.resume(returning: state?.isEnabled ?? false)
            }
        }
    }

    static func openSettings() async -> Bool {
        await withCheckedContinuation { done in
            SFSafariApplication.showPreferencesForExtension(withIdentifier: Paths.safariExtensionID) { error in
                done.resume(returning: error == nil)
            }
        }
    }
}
