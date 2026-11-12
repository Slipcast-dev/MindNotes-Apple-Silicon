import Foundation

/// Картинки вырезки, которые браузер не смог скачать сам (другой сайт, CDN), скачивает MindNotes (ADR-0019).
/// Так расширению не нужен доступ ко всем сайтам. Только https и только публичные адреса (`WebClip.isPublicWebURL`),
/// в том числе после переадресации; без cookies и кэша; размер и тип проверяются, тип — ещё и по содержимому.
enum ClipImageFetcher {
    static let maxBytes = 8 * 1024 * 1024
    static let parallel = 4

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["User-Agent": "MindNotes web clipper", "Accept": "image/avif;q=0,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.5"]
        return URLSession(configuration: config)
    }()

    /// Переадресация разрешена только на публичный https.
    private final class Guard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(WebClip.isPublicWebURL) == true ? request : nil)
        }
    }

    /// Скачанные картинки по имени из вырезки. Не уложившиеся в `budget` байт и не скачавшиеся — пропускаются
    /// (вырезка оставит их ссылками).
    static func fetch(_ remotes: [WebClip.RemoteImage], budget: Int) async -> [String: WebClip.Image] {
        var results: [(Int, WebClip.Image)] = []
        await withTaskGroup(of: (Int, WebClip.Image?).self) { group in
            var next = 0
            func add() {
                guard next < remotes.count else { return }
                let index = next, remote = remotes[index]
                next += 1
                group.addTask { (index, await one(remote)) }
            }
            for _ in 0..<min(parallel, remotes.count) { add() }
            for await (index, image) in group {
                if let image { results.append((index, image)) }
                add()
            }
        }
        // Бюджет — в порядке картинок в тексте: первые важнее.
        var out: [String: WebClip.Image] = [:], used = 0
        for (index, image) in results.sorted(by: { $0.0 < $1.0 }) where used + image.data.count <= budget {
            used += image.data.count
            out[remotes[index].name] = image
        }
        return out
    }

    private static func one(_ remote: WebClip.RemoteImage) async -> WebClip.Image? {
        guard WebClip.isPublicWebURL(remote.url) else { return nil }
        var request = URLRequest(url: remote.url)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request, delegate: Guard()),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, WebClip.isPublicWebURL(final),
              !data.isEmpty, data.count <= maxBytes, let (mime, ext) = WebClip.sniffImage(data) else { return nil }
        // Имя вложения — с настоящим расширением; в тексте ссылка переименуется (`WebClip.resolvingRemote`).
        let base = (remote.name as NSString).deletingPathExtension
        return WebClip.Image(name: "\(base).\(ext)", mime: mime, data: data)
    }
}
