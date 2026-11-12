import Foundation

/// Плагины (ADR-0019): код плагина работает вне приложения (браузер, отдельная программа) и обращается к пространству
/// только через локальный API в пределах разрешений, подтверждённых при установке.
enum PluginPermission: String, CaseIterable, Equatable, Codable {
    case pagesList = "pages.list"
    case pagesCreate = "pages.create"
    case pagesOpen = "pages.open"
    case assetsCreate = "assets.create"
    case tagsWrite = "tags.write"
}

struct PluginManifest: Equatable {
    /// Версия локального API, которую понимает это приложение. Растёт только при несовместимых изменениях.
    static let apiVersion = 1
    static let packageExtension = "mnplugin"

    var id: String
    var name: String
    var version: String
    var api: Int
    var summary: String?
    var author: String?
    var permissions: [PluginPermission]
    /// Разрешения более новых версий: плагин с ними не включается.
    var unknownPermissions: [String]
    /// Компоненты, которые ставятся вне приложения: имя → путь внутри пакета.
    var components: [String: String]
    var minApp: AppVersion?

    static func == (a: PluginManifest, b: PluginManifest) -> Bool {
        a.id == b.id && a.version == b.version && a.permissions == b.permissions && a.components == b.components
    }

    enum Problem: Error, Equatable {
        case unreadable
        case notPlugin
        case newerAPI(Int)
        case unknownPermissions([String])
        case badComponent(String)
        case newerApp(String)
    }

    /// Описание плагина из manifest.json. Общие поля (id, name) проверяет `ExtensionManifest.parse`.
    static func parse(_ data: Data) -> Result<PluginManifest, Problem> {
        guard let base = ExtensionManifest.parse(data), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        guard case .plugin = base.kind else { return .failure(.notPlugin) }
        let api = (o["api"] as? Int) ?? 1
        var known: [PluginPermission] = [], unknown: [String] = []
        for raw in (o["permissions"] as? [String]) ?? [] {
            if let p = PluginPermission(rawValue: raw) { if !known.contains(p) { known.append(p) } } else { unknown.append(raw) }
        }
        var components: [String: String] = [:]
        for (key, value) in (o["components"] as? [String: Any]) ?? [:] {
            guard let path = value as? String, isSafeRelativePath(path),
                  key.count <= 40, key.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else { return .failure(.badComponent(key)) }
            components[key] = path
        }
        let manifest = PluginManifest(id: base.id, name: base.name, version: base.version, api: api,
                                      summary: (o["description"] as? String).map { String($0.prefix(300)) },
                                      author: (o["author"] as? String).map { String($0.prefix(80)) },
                                      permissions: known, unknownPermissions: unknown, components: components, minApp: base.minApp)
        return .success(manifest)
    }

    /// Причина, по которой плагин нельзя включить в этой версии приложения; nil — можно.
    func problem(app: AppVersion?) -> Problem? {
        if api > Self.apiVersion { return .newerAPI(api) }
        if !unknownPermissions.isEmpty { return .unknownPermissions(unknownPermissions) }
        if let minApp, let app, app < minApp { return .newerApp(minApp.description) }
        return nil
    }

    /// Путь внутри пакета: без абсолютного начала, `..` и пустых частей.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 300, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
}

/// Привязанный клиент плагина (браузер, программа). Токен не хранится: только его SHA-256.
struct PluginClient: Codable, Equatable, Identifiable {
    var id: UUID
    var plugin: String
    var name: String
    var tokenHash: String
    var createdAt: Int64
    var lastUsedAt: Int64?
    /// Источник запроса привязки (`chrome-extension://…`): одно расширение — одно подключение.
    var origin: String?

    /// Одно подключение на экземпляр расширения: новый ключ того же плагина и источника заменяет прежний.
    /// Расширение при установке подключается из нескольких мест сразу, и без этого список рос дублями.
    static func adding(_ client: PluginClient, to list: [PluginClient]) -> [PluginClient] {
        guard let origin = client.origin else { return list + [client] }
        return list.filter { !($0.plugin == client.plugin && $0.origin == origin) } + [client]
    }

    /// Уборка старых дублей: из записей одного плагина и источника (без источника — одного имени)
    /// остаётся последняя использованная — её ключ и хранит расширение.
    static func deduplicated(_ list: [PluginClient]) -> [PluginClient] {
        func key(_ c: PluginClient) -> String { c.plugin + "\u{1}" + (c.origin ?? "name:" + c.name) }
        func recency(_ c: PluginClient) -> Int64 { max(c.lastUsedAt ?? 0, c.createdAt) }
        var best: [String: PluginClient] = [:]
        for c in list where best[key(c)].map({ recency(c) >= recency($0) }) ?? true { best[key(c)] = c }
        return list.filter { best[key($0)]?.id == $0.id }
    }
}
