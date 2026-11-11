import AppKit
import WebKit

/// Единственное место приложения, где есть сеть (ADR-0011, проверка AT-15 в `tests/edition.test.cjs`).
/// Запросы — только по действию пользователя и только при включённом «Превью ссылок».
enum LinkPreviewFetcher {
    static let settingKey = "linkPreviewsEnabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    struct Result {
        var preview: LinkCard.Preview
        var image: (data: Data, ext: String)?
    }

    /// Без cookies, кэша и учётных данных; только https; размер ответа ограничен.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["User-Agent": "MindNotes link preview", "Accept-Language": Locale.preferredLanguages.prefix(2).joined(separator: ",")]
        return URLSession(configuration: config)
    }()

    static func fetch(_ url: URL) async throws -> Result {
        guard isEnabled, url.scheme?.lowercased() == "https" else { throw URLError(.cancelled) }
        let html = try await download(url, limit: LinkCard.maxHTMLBytes) { $0.hasPrefix("text/html") || $0.hasPrefix("application/xhtml") }
        let text = String(decoding: html, as: UTF8.self)
        var result = Result(preview: LinkCard.parse(html: text, base: url))
        if let image = result.preview.image,
           let data = try? await download(image, limit: LinkCard.maxImageBytes, accept: { $0.hasPrefix("image/") }),
           NSImage(data: data) != nil {
            result.image = (data, image.pathExtension.isEmpty ? "jpg" : image.pathExtension.lowercased())
        }
        return result
    }

    private static func download(_ url: URL, limit: Int, accept: (String) -> Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https", accept((http.mimeType ?? "").lowercased()) else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(limit) { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }

    /// Окно встраивания: свой временный набор данных сайта, без общих cookies. При выключенном превью — браузер по умолчанию.
    @MainActor
    static func openEmbed(_ url: URL, title: String) {
        let target = LinkCard.embed(url).url
        guard isEnabled else {
            NSWorkspace.shared.open(url)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 600), configuration: config)
        web.load(URLRequest(url: target))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        openWindows.insert(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow else { return }
                (closing.contentView as? WKWebView)?.stopLoading()
                openWindows.remove(closing)
            }
        }
    }

    @MainActor private static var openWindows: Set<NSWindow> = []
}
