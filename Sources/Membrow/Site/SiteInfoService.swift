import AppKit
import Foundation
import MembrowCore

/// 站点图标文件：按收藏 ID 存放，避免进 JSON / SQLite。
enum SiteIconStore {
    static func directory(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("site-icons", isDirectory: true)
    }

    static func fileURL(for bookmarkID: UUID, in dataDirectory: URL) -> URL {
        directory(in: dataDirectory).appendingPathComponent("\(bookmarkID.uuidString).png")
    }

    static func image(for bookmarkID: UUID, in dataDirectory: URL?) -> NSImage? {
        guard let dataDirectory else { return nil }
        return NSImage(contentsOf: fileURL(for: bookmarkID, in: dataDirectory))
    }

    static func save(_ image: NSImage, for bookmarkID: UUID, in dataDirectory: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let directory = directory(in: dataDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: fileURL(for: bookmarkID, in: dataDirectory), options: .atomic)
    }
}

/// 抓取站点标题与图标：只用 URLSession 请求 HTML / 图标，不创建 WebView、不注入脚本。
@MainActor
final class SiteInfoService {
    private let store: AppStore
    private let dataDirectory: URL
    private var queue: [UUID] = []
    private var inFlight: Set<UUID> = []

    var onChange: (() -> Void)?

    init(store: AppStore, dataDirectory: URL) {
        self.store = store
        self.dataDirectory = dataDirectory
        try? FileManager.default.createDirectory(at: SiteIconStore.directory(in: dataDirectory),
                                                 withIntermediateDirectories: true)
        purgeOrphanIcons()
    }

    func refresh(bookmarkID: UUID) {
        enqueue(bookmarkID)
    }

    /// 只在本地还没有图标时补抓：用于刷新页面时补齐老收藏缺失的站点图标。
    func refreshIconIfMissing(bookmarkID: UUID) {
        guard SiteIconStore.image(for: bookmarkID, in: dataDirectory) == nil else { return }
        enqueue(bookmarkID)
    }

    /// 图标始终自动抓取（站点换图标后下次刷新即生效）；标题只在缺失时抓。
    func refreshAllMetadata() {
        for bookmark in store.library.bookmarks {
            enqueue(bookmark.id)
        }
    }

    private func enqueue(_ bookmarkID: UUID) {
        guard !inFlight.contains(bookmarkID), !queue.contains(bookmarkID) else { return }
        queue.append(bookmarkID)
        startNext()
    }

    private func startNext() {
        guard inFlight.isEmpty, !queue.isEmpty else { return }
        let bookmarkID = queue.removeFirst()
        guard let bookmark = store.bookmark(id: bookmarkID) else {
            startNext()
            return
        }
        inFlight.insert(bookmarkID)
        Task { [weak self] in
            await self?.load(bookmark)
            guard let self else { return }
            self.inFlight.remove(bookmarkID)
            self.onChange?()
            self.startNext()
        }
    }

    // MARK: - 抓取

    private func load(_ bookmark: Bookmark) async {
        guard let url = bookmark.entryURLValue else { return }
        let proxy = store.resolvedProxy(for: bookmark).proxy
        let session = makeSession(proxy: proxy)
        defer { session.invalidateAndCancel() }

        let needsTitle = (bookmark.siteTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let html = await fetchHTML(url: url, session: session)
        if needsTitle, let html, let title = SiteMetadata.title(inHTML: html) {
            store.setSiteTitle(id: bookmark.id, title: title)
        }

        var candidates = html.map { SiteMetadata.iconURLs(inHTML: $0, baseURL: url) } ?? []
        if let fallback = URL(string: "/favicon.ico", relativeTo: url) {
            candidates.append(fallback)
        }
        for candidate in candidates.prefix(4) {
            let ok = await fetchIcon(url: candidate, bookmarkID: bookmark.id, session: session)
            if ok { break }
        }
    }

    private func makeSession(proxy: ProxySettings) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = ProxyResolver.urlSessionProxyDictionary(for: proxy)
        return URLSession(configuration: configuration)
    }

    private func fetchHTML(url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Membrow/0.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        let text = HTTPTextDecoder.decode(data: data, charset: http.textEncodingName)
        // 标题与图标只在 head 附近，截断避免整页解析。
        return text.map { String($0.prefix(200_000)) }
    }

    private func fetchIcon(url: URL, bookmarkID: UUID, session: URLSession) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= 1_000_000,
              let image = NSImage(data: data), image.size.width > 0 else {
            return false
        }
        SiteIconStore.save(image, for: bookmarkID, in: dataDirectory)
        return true
    }

    /// 收藏被删除后清理孤立图标文件。
    private func purgeOrphanIcons() {
        let directory = SiteIconStore.directory(in: dataDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil) else {
            return
        }
        let existing = Set(store.library.bookmarks.map { $0.id.uuidString })
        for file in files where !existing.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
