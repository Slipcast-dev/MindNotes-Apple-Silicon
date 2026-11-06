import Foundation

/// A published GitHub release that can be installed.
struct ReleaseInfo: Equatable {
    let version: String
    let notes: String
    let assetName: String
    let assetURL: URL
    /// SHA-256 of the asset when the release notes publish one next to the file name.
    let sha256: String?
    /// A small patch from the installed version to this one, when the release carries one.
    var patch: PatchAsset? = nil
}

/// The update patch of a release: only what changed between two versions (see `AppPatch`).
struct PatchAsset: Equatable {
    let name: String
    let url: URL
    let sha256: String?
}

/// Pure logic of the update check (no UI, no network), so it can be tested.
enum UpdateCheck {
    static let repository = "Slipcast-dev/Grizzly"
    static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// "v1.2.0" -> "1.2.0"
    static func normalized(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        return s
    }

    private static func components(_ version: String) -> [Int] {
        normalized(version).split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    /// Numeric comparison of dotted versions: 1.10.0 is newer than 1.9.0, 1.2 equals 1.2.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads the `releases/latest` answer and picks the file whose name ends with `assetSuffix`
    /// (e.g. "-arm64.dmg"). Nil when the release has no such file.
    /// `patchFrom`: the installed version and the architecture tag ("arm64"); with them the release's patch for exactly that
    /// version is picked up too (`Grizzly-patch-<from>-to-<to>-<arch>.zip`).
    static func parse(_ data: Data, assetSuffix: String, patchFrom: (version: String, arch: String)? = nil) throws -> ReleaseInfo? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw CocoaError(.coderReadCorrupt) }
        let notes = json["body"] as? String ?? ""
        let assets = json["assets"] as? [[String: Any]] ?? []
        var patch: PatchAsset?
        if let patchFrom {
            let prefix = "Grizzly-patch-\(normalized(patchFrom.version))-to-", suffix = "-\(patchFrom.arch).zip"
            for asset in assets {
                guard let name = asset["name"] as? String, name.hasPrefix(prefix), name.hasSuffix(suffix),
                      let link = asset["browser_download_url"] as? String, let url = URL(string: link),
                      isTrustedDownload(url) else { continue }
                patch = PatchAsset(name: name, url: url, sha256: checksum(in: notes, for: name))
                break
            }
        }
        for asset in assets {
            guard let name = asset["name"] as? String, name.hasSuffix(assetSuffix),
                  let link = asset["browser_download_url"] as? String, let url = URL(string: link),
                  isTrustedDownload(url) else { continue }
            return ReleaseInfo(version: normalized(tag), notes: notes, assetName: name, assetURL: url,
                               sha256: checksum(in: notes, for: name), patch: patch)
        }
        return nil
    }

    /// Downloads only come from GitHub itself, over HTTPS.
    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Finds `<64 hex digits>` on the line of the release notes that names the asset.
    static func checksum(in notes: String, for assetName: String) -> String? {
        for line in notes.components(separatedBy: .newlines) where line.contains(assetName) {
            let hex = Set("0123456789abcdefABCDEF")
            var run = ""
            for ch in line + " " {
                if hex.contains(ch) { run.append(ch); continue }
                if run.count == 64 { return run.lowercased() }
                run = ""
            }
        }
        return nil
    }
}
