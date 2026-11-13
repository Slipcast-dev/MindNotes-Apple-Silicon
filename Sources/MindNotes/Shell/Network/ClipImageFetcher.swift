import Foundation

/// Картинки вырезки, которые браузер не смог скачать сам (другой сайт, CDN), скачивает MindNotes (ADR-0019).
/// Так расширению не нужен доступ ко всем сайтам. Только https и только публичные адреса (`WebClip.isPublicWebURL`),
/// в том числе после переадресации и после DNS (каждый адрес имени); без cookies и кэша. Размер ограничивается
/// во время получения: ответ читается потоком и обрывается на пределе, общий бюджет соблюдается по ходу загрузки.
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

    /// Переадресация разрешена только на публичный https с публичными адресами.
    private final class Guard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(ClipImageFetcher.isAllowed) == true ? request : nil)
        }
    }

    /// Публичный https и все адреса имени после DNS публичные. Ограничение: между этой проверкой и соединением
    /// имя может разрешиться иначе (DNS rebinding); привязать соединение URLSession к проверенному адресу нельзя.
    static func isAllowed(_ url: URL) -> Bool {
        guard WebClip.isPublicWebURL(url), let host = url.host else { return false }
        let addresses = resolve(host)
        return !addresses.isEmpty && addresses.allSatisfy(WebClip.isPublicAddress)
    }

    /// Адреса имени (IPv4 и IPv6) в текстовом виде; пусто — имя не разрешилось.
    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buffer))
            }
        }
        return out
    }

    /// Общий бюджет байт на одну вырезку: место занимается до чтения, освобождается при отказе.
    private actor Budget {
        var left: Int
        init(_ total: Int) { left = total }
        func take(_ n: Int) -> Bool { guard n <= left else { return false }; left -= n; return true }
        func give(_ n: Int) { left += n }
    }

    /// Скачанные картинки по имени из вырезки. Не уложившиеся в `budget` байт и не скачавшиеся — пропускаются
    /// (вырезка оставит их ссылками).
    /// Бюджет соблюдается во время загрузки: в памяти не больше `budget` байт принятых картинок и не больше
    /// `parallel × maxBytes` читаемых. Порядок важности сохраняется лишь приблизительно: место занимает картинка,
    /// которая скачалась раньше.
    static func fetch(_ remotes: [WebClip.RemoteImage], budget: Int) async -> [String: WebClip.Image] {
        var results: [(Int, WebClip.Image)] = []
        let shared = Budget(max(0, budget))
        await withTaskGroup(of: (Int, WebClip.Image?).self) { group in
            var next = 0
            func add() {
                guard next < remotes.count else { return }
                let index = next, remote = remotes[index]
                next += 1
                group.addTask { (index, await one(remote, budget: shared)) }
            }
            for _ in 0..<min(parallel, remotes.count) { add() }
            for await (index, image) in group {
                if let image { results.append((index, image)) }
                add()
            }
        }
        var out: [String: WebClip.Image] = [:]
        for (index, image) in results { out[remotes[index].name] = image }
        return out
    }

    private static func one(_ remote: WebClip.RemoteImage, budget: Budget) async -> WebClip.Image? {
        guard isAllowed(remote.url) else { return nil }
        var request = URLRequest(url: remote.url)
        request.httpMethod = "GET"
        guard let (bytes, response) = try? await session.bytes(for: request, delegate: Guard()) else { return nil }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, WebClip.isPublicWebURL(final) else { return nil }
        // Объявленная длина — ранняя проверка; настоящий предел — счётчик байт ниже (длина может врать или не прийти).
        if http.expectedContentLength > Int64(maxBytes) { return nil }
        var data = Data()
        var reserved = 0
        do {
            for try await byte in bytes {
                if data.count == reserved {
                    // Место в общем бюджете занимается порциями по 64 КиБ, но не больше предела одной картинки.
                    let step = min(64 << 10, maxBytes + 1 - reserved)
                    guard step > 0, await budget.take(step) else { await budget.give(reserved); return nil }
                    reserved += step
                    data.reserveCapacity(reserved)
                }
                data.append(byte)
                if data.count > maxBytes { await budget.give(reserved); return nil }
            }
        } catch {
            await budget.give(reserved)
            return nil
        }
        await budget.give(reserved - data.count)
        guard !data.isEmpty, let (mime, ext) = WebClip.sniffImage(data) else { await budget.give(data.count); return nil }
        // Имя вложения — с настоящим расширением; в тексте ссылка переименуется (`WebClip.resolvingRemote`).
        let base = (remote.name as NSString).deletingPathExtension
        return WebClip.Image(name: "\(base).\(ext)", mime: mime, data: data)
    }
}
