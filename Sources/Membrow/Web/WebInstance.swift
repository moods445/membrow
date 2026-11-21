import Foundation
import MembrowCore
import WebKit

@MainActor
final class WebInstance {
    let bookmarkID: UUID
    let webView: WKWebView
    let handler: WebViewHandler

    weak var host: (any ContentHosting)?
    var lastVisibleAt: Date
    var isVisible = false
    var didLoadOnce = false
    var lastError: String?
    var currentURL: URL?
    /// 本次导航开始时间，用于日志里的耗时（秒级精度够用，不参与业务判断）。
    var navigationStartedAt: Date?
    var blockingEnabled: Bool
    /// 强制深色样式表实例；私有接口不可用时为 nil。
    var forcedDarkStyleSheet: NSObject?

    init(bookmarkID: UUID,
         webView: WKWebView,
         handler: WebViewHandler,
         blockingEnabled: Bool) {
        self.bookmarkID = bookmarkID
        self.webView = webView
        self.handler = handler
        self.blockingEnabled = blockingEnabled
        self.lastVisibleAt = Date()
    }
}

@MainActor
final class WebViewHandler: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let bookmarkID: UUID
    weak var runtime: BrowserRuntime?

    init(bookmarkID: UUID) {
        self.bookmarkID = bookmarkID
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // 只接受主框架、且 host 与真实安全来源一致的提交：
        // WKScriptMessageHandler 对同进程所有 frame 可见，不校验就能被第三方 iframe 伪造成任意站点凭据。
        guard message.name == CredentialScript.handlerName,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let host = body["host"] as? String,
              let password = body["password"] as? String,
              SiteMatcher.normalizedHost(message.frameInfo.securityOrigin.host) == SiteMatcher.normalizedHost(host)
        else { return }
        let username = body["username"] as? String ?? ""
        runtime?.handleCredentialCapture(bookmarkID: bookmarkID,
                                         host: host,
                                         username: username,
                                         password: password)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        runtime?.handleDidFinish(bookmarkID: bookmarkID, url: webView.url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        runtime?.handleDidStart(bookmarkID: bookmarkID)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        runtime?.handleLoadFailure(bookmarkID: bookmarkID, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        runtime?.handleLoadFailure(bookmarkID: bookmarkID, error: error)
    }

    /// 主框架响应：把 4xx/5xx 记进诊断日志。WKWebView 不会把“服务器返回 500”当导航失败，
    /// 这里读 statusCode 是唯一能拿到 HTTP 错误的公开入口；决策仍是放行，页面照常显示错误页。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame,
              let http = navigationResponse.response as? HTTPURLResponse else {
            decisionHandler(.allow)
            return
        }
        runtime?.handleNavigationResponse(bookmarkID: bookmarkID,
                                          statusCode: http.statusCode,
                                          url: http.url)
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        runtime?.handleProcessTermination(bookmarkID: bookmarkID)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let runtime else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" {
            decisionHandler(.cancel)
            runtime.openExternally(url)
            return
        }

        let isNewWindow = navigationAction.targetFrame == nil
        let isLinkClick = navigationAction.navigationType == .linkActivated
        let sameSite = SiteMatcher.isSameSite(webView.url, url)

        if isNewWindow {
            decisionHandler(.cancel)
            if sameSite {
                runtime.loadInCurrentInstance(bookmarkID: bookmarkID, url: url)
            } else {
                runtime.openExternally(url)
            }
            return
        }

        if isLinkClick && !sameSite {
            decisionHandler(.cancel)
            runtime.openExternally(url)
            return
        }

        decisionHandler(.allow)
    }

    /// 网页请求媒体采集权限。
    ///
    /// 只放行麦克风，且以设置项为准：允许时直接 `grant`，刷新页面/重开网页都不再追问；
    /// 真正的“这台机器能不能录”由系统隐私授权（TCC，首次会弹一次）负责。
    /// 摄像头等其它类型仍一律拒绝，需要时再加开关。
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard case .microphone = type,
              runtime?.store.settings.microphoneEnabled == true else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            runtime?.openExternally(url)
            return nil
        }
        if SiteMatcher.isSameSite(webView.url, url) {
            runtime?.loadInCurrentInstance(bookmarkID: bookmarkID, url: url)
        } else {
            runtime?.openExternally(url)
        }
        return nil
    }
}
