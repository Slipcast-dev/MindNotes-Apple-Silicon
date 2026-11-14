import Foundation

/// Обновления (ADR-0014): сравнение версий, разбор выпуска GitHub и файла контрольных сумм. Без сети.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    /// «1.3.0», «v1.3», «1.3.0-beta» (суффикс отбрасывается); иначе nil.
    init?(_ text: String) {
        var clean = text.trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("v") || clean.hasPrefix("V") { clean.removeFirst() }
        clean = String(clean.prefix { $0 != "-" && $0 != "+" })
        let numbers = clean.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

struct ReleaseInfo: Equatable {
    var version: AppVersion
    var title: String
    var notes: String
    var image: URL
    var checksums: URL

    static func == (a: ReleaseInfo, b: ReleaseInfo) -> Bool { a.version == b.version && a.image == b.image }

    /// Ответ `releases/latest`: нужны версия, образ `.dmg` и `SHA256SUMS.txt`, оба по https с GitHub.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, let version = AppVersion(tag),
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let assets = object["assets"] as? [[String: Any]] else { return nil }
        func asset(_ match: (String) -> Bool) -> URL? {
            for a in assets {
                guard let name = a["name"] as? String, match(name), let raw = a["browser_download_url"] as? String,
                      let url = URL(string: raw), url.scheme == "https", url.host?.hasSuffix("github.com") == true else { continue }
                return url
            }
            return nil
        }
        guard let image = asset({ $0.hasPrefix("MindNotes-") && $0.hasSuffix(".dmg") }), let sums = asset({ $0 == "SHA256SUMS.txt" }) else { return nil }
        return ReleaseInfo(version: version, title: (object["name"] as? String) ?? "MindNotes \(version)",
                           notes: String(((object["body"] as? String) ?? "").prefix(4000)), image: image, checksums: sums)
    }

    /// Строки вида «<64 hex>  имя»; имя может начинаться с «*» (двоичный режим).
    static func checksums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            out[(name as NSString).lastPathComponent] = hash
        }
        return out
    }
}

/// Минимальная система новой программы (ADR-0020): `LSMinimumSystemVersion` из Info.plist в образе.
/// Возвращает требуемую версию, только если текущая система старее; без ключа или с неразборчивым значением — nil.
enum SystemRequirement {
    static func unmet(infoPlist: [String: Any], system: OperatingSystemVersion) -> AppVersion? {
        guard let raw = infoPlist["LSMinimumSystemVersion"] as? String, let required = AppVersion(raw) else { return nil }
        let current = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")!
        return current < required ? required : nil
    }
}

/// Режим обновлений в настройках.
enum UpdateMode: String, CaseIterable {
    case automatic, manual
    static let checkInterval: TimeInterval = 24 * 60 * 60
}

/// Замена установленной программы новой версией после выхода приложения (ADR-0014). Прежняя версия сначала
/// переносится в резервный путь и удаляется только после успешной установки новой; при сбое возвращается на место.
enum UpdateReplacement {
    /// Сценарий для `/bin/sh`: ждёт завершения `pid`, заменяет `current` на `staged` с откатом.
    /// `relaunch` — открыть программу после замены (новую, а при откате — прежнюю).
    static func script(current: URL, staged: URL, backup: URL, pid: Int32, relaunch: Bool = true) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cur = q(current.path), new = q(staged.path), old = q(backup.path)
        let open = relaunch ? "open \(cur)" : ":"
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        if [ ! -d \(new) ]; then \(open); exit 1; fi
        if ! mv \(cur) \(old); then \(open); exit 1; fi
        if mv \(new) \(cur); then
          rm -rf \(old)
          xattr -dr com.apple.quarantine \(cur) 2>/dev/null
          \(open)
        else
          mv \(old) \(cur)
          \(open)
          exit 1
        fi
        """
    }
}

/// Временные файлы обновлений приложения и плагинов (ADR-0014, ADR-0019): скачанные образы и суммы,
/// папки, куда монтируется образ. Приложение убирает их само, а при запуске подметает остатки прежних версий,
/// в которых уборки не было. Здесь только правило отбора; файлами занимается `UpdateTempCleanup`.
enum UpdateTempFiles {
    /// Скачанные файлы: `MindNotes-update-<uuid>-<имя>` (приложение), `MindNotes-plugin-<uuid>-<имя>` (плагины).
    static let downloadPrefixes = ["MindNotes-update-", "MindNotes-plugin-"]
    /// Папки монтирования образа.
    static let mountPrefixes = ["MindNotes-mount-", "MindNotes-plugin-mount-"]
    /// Скачанное младше суток не трогаем: вдруг идёт загрузка во втором окне или проверка.
    static let downloadMaxAge: TimeInterval = 24 * 60 * 60
    /// Пустая папка монтирования младше 10 минут может ждать `hdiutil attach`.
    static let mountMaxAge: TimeInterval = 10 * 60

    /// Остаток ли это. Папка монтирования убирается только пустой — это проверяет вызывающий.
    static func isLeftover(name: String, isDirectory: Bool, age: TimeInterval) -> Bool {
        let isMount = mountPrefixes.contains { name.hasPrefix($0) }
        if isDirectory { return isMount && age >= mountMaxAge }
        return !isMount && downloadPrefixes.contains { name.hasPrefix($0) } && age >= downloadMaxAge
    }
}
