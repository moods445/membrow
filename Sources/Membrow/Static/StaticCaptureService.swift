import AppKit
import Foundation
import MembrowCore
import WebKit

struct StaticCaptureResult {
    let html: String
    let finalURL: URL
}

enum StaticCaptureError: LocalizedError {
    case invalidURL
    case timeout
    case selectorTimeout(String)
    case httpStatus(Int)
    case emptyResponse
    case navigationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "收藏地址无效"
        case .timeout: return "抓取超时"
        case .selectorTimeout(let selector):
            return "等待选择器超时：\(selector)"
        case .httpStatus(let code): return "HTTP 状态码 \(code)"
        case .emptyResponse: return "页面内容为空"
        case .navigationFailed(let message): return "页面加载失败：\(message)"
        }
    }
}

@MainActor
final class StaticCaptureService {
    private let store: AppStore
    private let sharedWebData: SharedWebData
    private let limiter: ConcurrencyLimiter
    private var currentLimit: Int

    init(store: AppStore, sharedWebData: SharedWebData) {
        self.store = store
        self.sharedWebData = sharedWebData
        let limit = min(max(store.settings.staticConcurrency, 1), AppSettings.staticConcurrencyHardLimit)
        self.currentLimit = limit
        self.limiter = ConcurrencyLimiter(limit: limit)
    }

    private func updateConcurrency() async {
        let limit = min(max(store.settings.staticConcurrency, 1), AppSettings.staticConcurrencyHardLimit)
        guard limit != currentLimit else { return }
        currentLimit = limit
        // 复用同一个 limiter：重建会丢弃正在占槽的任务，导致并发突破硬上限 4。
        await limiter.setLimit(limit)
    }

    func capture(bookmark: Bookmark) async throws -> StaticCaptureResult {
        await updateConcurrency()
        let settings = store.settings
        let proxy = ProxyResolver.resolve(bookmark: bookmark, settings: settings).proxy
        let timeout = settings.staticCaptureTimeout
        let mode = bookmark.staticConfig.captureMode

        return try await limiter.withSlot {
            switch mode {
            case .webView:
                return try await self.captureWithWebView(bookmark: bookmark, proxy: proxy, timeout: timeout)
            case .http:
                return try await self.captureWithHTTP(bookmark: bookmark, proxy: proxy, timeout: timeout)
            }
        }
    }

    // MARK: - WebView capture

    private func captureWithWebView(bookmark: Bookmark,
                                    proxy: ProxySettings,
                                    timeout: TimeInterval) async throws -> StaticCaptureResult {
        guard let url = BookmarkValidation.url(from: bookmark.lastURL ?? bookmark.entryURL)
            ?? bookmark.entryURLValue else {
            throw StaticCaptureError.invalidURL
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedWebData.dataStore(for: proxy, settings: store.settings)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 静态抓取不挂载内容拦截规则，避免媒体资源被拦截。

        let frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let webView = WKWebView(frame: frame, configuration: configuration)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: frame)
        window.contentView?.addSubview(webView)

        let captureDelegate = CaptureNavigationDelegate()
        webView.navigationDelegate = captureDelegate

        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }

        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()

        webView.load(URLRequest(url: url))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = captureDelegate.error {
                throw StaticCaptureError.navigationFailed(error.localizedDescription)
            }
            if captureDelegate.didFinish { break }
            try await sleep(0.1)
        }

        guard captureDelegate.didFinish else {
            throw StaticCaptureError.timeout
        }

        // didFinish 只代表首帧到了，SPA 之后还会继续挂载内容（首帧常常只有“加载中…”占位）。
        // AGENTS.md #3 只允许 CredentialScript 一类页面脚本，不能用 DOM 签名/内容比对脚本，
        // 因此这里固定等一小段再取 outerHTML。
        // ponytail: 固定延迟替代内容稳定判定，慢站可能在正文挂载前抓取；需要时再换允许的机制。
        let settle = min(1.0, max(deadline.timeIntervalSinceNow, 0))
        if settle > 0 { try await sleep(settle) }

        let waitSelector = bookmark.staticConfig.extraction.trimmedWaitSelector
        if !waitSelector.isEmpty {
            let script = try Self.selectorCheckScript(waitSelector)
            // 独立预算：前面的加载/等待可能已经用掉整个 deadline，否则元素已存在也会直接误报超时。
            let selectorDeadline = Date().addingTimeInterval(min(timeout, 5))
            var matched = false
            while true {
                if let value = try? await webView.evaluateJavaScript(script) as? Bool, value {
                    matched = true
                    break
                }
                if Date() >= selectorDeadline { break }
                try await sleep(0.2)
            }
            guard matched else {
                throw StaticCaptureError.selectorTimeout(waitSelector)
            }
        }

        guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String,
              !html.isEmpty else {
            throw StaticCaptureError.emptyResponse
        }

        return StaticCaptureResult(html: html, finalURL: webView.url ?? url)
    }

    private static func selectorCheckScript(_ selector: String) throws -> String {
        let data = try JSONEncoder().encode(selector)
        let literal = String(data: data, encoding: .utf8) ?? "\"\""
        return "document.querySelector(\(literal)) !== null"
    }

    // MARK: - HTTP capture

    private func captureWithHTTP(bookmark: Bookmark,
                                 proxy: ProxySettings,
                                 timeout: TimeInterval) async throws -> StaticCaptureResult {
        guard let url = BookmarkValidation.url(from: bookmark.lastURL ?? bookmark.entryURL)
            ?? bookmark.entryURLValue else {
            throw StaticCaptureError.invalidURL
        }

        let dataStore = sharedWebData.dataStore(for: proxy, settings: store.settings)
        let cookies = await dataStore.httpCookieStore.allCookies()
        let host = url.host ?? ""
        let applicableCookies = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Membrow/0.1", forHTTPHeaderField: "User-Agent")
        if !applicableCookies.isEmpty {
            let header = applicableCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = ProxyResolver.urlSessionProxyDictionary(for: proxy)

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StaticCaptureError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StaticCaptureError.httpStatus(http.statusCode)
        }
        guard let html = HTTPTextDecoder.decode(data: data, charset: http.textEncodingName), !html.isEmpty else {
            throw StaticCaptureError.emptyResponse
        }
        return StaticCaptureResult(html: html, finalURL: http.url ?? url)
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if Task.isCancelled { throw StaticCaptureError.timeout }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

@MainActor
private final class CaptureNavigationDelegate: NSObject, WKNavigationDelegate {
    var didFinish = false
    var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        self.error = error
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = StaticCaptureError.navigationFailed("网页进程已结束")
    }
}
