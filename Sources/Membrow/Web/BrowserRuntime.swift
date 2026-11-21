import AppKit
import Foundation
import MembrowCore
import WebKit

@MainActor
final class BrowserRuntime {
    enum Termination: Equatable {
        case evicted
        case closed
        case crashed
    }

    private struct WeakHost {
        weak var host: (any ContentHosting)?
    }

    /// 页面上捕获到的一次登录提交，等待用户确认后再写入钥匙串。
    struct CredentialCandidate {
        let bookmarkID: UUID
        let host: String
        let username: String
        let password: String
    }

    let store: AppStore
    let sharedWebData: SharedWebData
    let blocker: ContentBlocker
    let credentials: CredentialStore

    private var instances: [UUID: WebInstance] = [:]
    private var hosts: [UUID: [WeakHost]] = [:]
    private var terminations: [UUID: Termination] = [:]

    var onChange: (() -> Void)?
    var onCredentialCaptured: ((CredentialCandidate) -> Void)?

    init(store: AppStore,
         sharedWebData: SharedWebData,
         blocker: ContentBlocker,
         credentials: CredentialStore) {
        self.store = store
        self.sharedWebData = sharedWebData
        self.blocker = blocker
        self.credentials = credentials
    }

    // MARK: - Host registry

    func register(host: any ContentHosting, for bookmarkID: UUID) {
        purgeDeadHosts()
        var list = hosts[bookmarkID] ?? []
        if !list.contains(where: { $0.host === host }) {
            list.append(WeakHost(host: host))
            hosts[bookmarkID] = list
        }
    }

    func unregister(host: any ContentHosting) {
        for key in hosts.keys {
            hosts[key]?.removeAll { $0.host == nil || $0.host === host }
            if hosts[key]?.isEmpty == true {
                hosts[key] = nil
            }
        }
    }

    private func purgeDeadHosts() {
        for key in hosts.keys {
            hosts[key]?.removeAll { $0.host == nil }
            if hosts[key]?.isEmpty == true {
                hosts[key] = nil
            }
        }
    }

    // MARK: - Queries

    func instance(for bookmarkID: UUID) -> WebInstance? {
        instances[bookmarkID]
    }

    func hasInstance(_ bookmarkID: UUID) -> Bool {
        instances[bookmarkID] != nil
    }

    func termination(for bookmarkID: UUID) -> Termination? {
        terminations[bookmarkID]
    }

    func clearTermination(for bookmarkID: UUID) {
        terminations[bookmarkID] = nil
    }

    var instanceCount: Int { instances.count }

    // MARK: - Activation

    func activate(bookmarkID: UUID, in host: any ContentHosting, useEntry: Bool = false) {
        guard let bookmark = store.bookmark(id: bookmarkID) else { return }
        let instance: WebInstance
        if let existing = instances[bookmarkID] {
            instance = existing
        } else {
            instance = makeInstance(for: bookmark)
            instances[bookmarkID] = instance
        }

        terminations[bookmarkID] = nil
        instance.host = host
        applyAppearance(bookmark.effectivePageAppearance, to: instance)
        host.attachWebView(instance.webView)

        if useEntry {
            load(instance, url: bookmark.entryURLValue)
        } else if !instance.didLoadOnce {
            let target = bookmark.lastURLValue ?? bookmark.entryURLValue
            load(instance, url: target)
        }
        notifyChange()
    }

    /// 将已在别处显示的实例移动到新容器。
    func move(bookmarkID: UUID, to host: any ContentHosting) {
        activate(bookmarkID: bookmarkID, in: host, useEntry: false)
    }

    private func makeInstance(for bookmark: Bookmark) -> WebInstance {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedWebData.dataStore(for: bookmark, settings: store.settings)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if bookmark.blockingEnabled, let ruleList = blocker.ruleList {
            configuration.userContentController.add(ruleList)
        }

        let handler = WebViewHandler(bookmarkID: bookmark.id)
        handler.runtime = self
        // 登录凭据桥：脚本只在表单提交时回传一次用户名/密码，填充按需由宿主触发。
        configuration.userContentController.add(handler, name: CredentialScript.handlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: CredentialScript.capture,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = store.settings.developerMode
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = handler
        webView.uiDelegate = handler

        let instance = WebInstance(bookmarkID: bookmark.id,
                                   webView: webView,
                                   handler: handler,
                                   blockingEnabled: bookmark.blockingEnabled)
        applyAppearance(bookmark.effectivePageAppearance, to: instance)
        return instance
    }

    private func load(_ instance: WebInstance, url: URL?) {
        guard let url else { return }
        instance.didLoadOnce = true
        instance.lastError = nil
        instance.webView.load(URLRequest(url: url))
    }

    func loadInCurrentInstance(bookmarkID: UUID, url: URL) {
        guard let instance = instances[bookmarkID] else { return }
        instance.lastError = nil
        instance.didLoadOnce = true
        instance.webView.load(URLRequest(url: url))
    }

    // MARK: - Navigation

    func reload(bookmarkID: UUID) {
        guard let instance = instances[bookmarkID] else { return }
        if let bookmark = store.bookmark(id: bookmarkID) {
            applyBlocking(bookmarkID: bookmarkID, enabled: bookmark.blockingEnabled)
        }
        instance.lastError = nil
        instance.webView.reload()
    }

    func goBack(bookmarkID: UUID) {
        instances[bookmarkID]?.webView.goBack()
    }

    func goForward(bookmarkID: UUID) {
        instances[bookmarkID]?.webView.goForward()
    }

    func openFromEntry(bookmarkID: UUID) {
        guard let bookmark = store.bookmark(id: bookmarkID) else { return }
        guard let instance = instances[bookmarkID] else { return }
        load(instance, url: bookmark.entryURLValue)
    }

    /// 从入口地址重新打开；实例已被关闭/回收时在当前容器中重新创建。
    func openFromEntry(bookmarkID: UUID, in host: any ContentHosting) {
        guard let bookmark = store.bookmark(id: bookmarkID) else { return }
        guard let instance = instances[bookmarkID] else {
            activate(bookmarkID: bookmarkID, in: host, useEntry: true)
            return
        }
        instance.host = host
        host.attachWebView(instance.webView)
        load(instance, url: bookmark.entryURLValue)
        notifyChange()
    }

    func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    func closeWebPage(bookmarkID: UUID) {
        guard let instance = instances.removeValue(forKey: bookmarkID) else { return }
        terminations[bookmarkID] = .closed
        teardown(instance)
        log(.info, "关闭网页", category: "memory", bookmarkID: bookmarkID)
        notifyChange()
    }

    func evict(bookmarkID: UUID) {
        guard let instance = instances.removeValue(forKey: bookmarkID) else { return }
        terminations[bookmarkID] = .evicted
        teardown(instance)
        log(.info, "回收网页实例", category: "memory", bookmarkID: bookmarkID)
        notifyChange()
    }

    func discardInstance(bookmarkID: UUID) {
        guard let instance = instances.removeValue(forKey: bookmarkID) else { return }
        terminations[bookmarkID] = nil
        teardown(instance)
        notifyChange()
    }

    private func teardown(_ instance: WebInstance) {
        instance.webView.stopLoading()
        instance.webView.navigationDelegate = nil
        instance.webView.uiDelegate = nil
        instance.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: CredentialScript.handlerName)
        instance.webView.removeFromSuperview()
        instance.host = nil
    }

    // MARK: - Visibility

    func setVisible(bookmarkID: UUID, visible: Bool) {
        guard let instance = instances[bookmarkID] else { return }
        guard instance.isVisible != visible else { return }
        instance.isVisible = visible
        if visible {
            instance.lastVisibleAt = Date()
        }
    }

    // MARK: - Blocking

    func applyBlocking(bookmarkID: UUID, enabled: Bool) {
        guard let instance = instances[bookmarkID] else { return }
        let controller = instance.webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if enabled, let ruleList = blocker.ruleList {
            controller.add(ruleList)
        }
        instance.blockingEnabled = enabled
    }

    func reapplyBlockingRules() {
        for bookmarkID in instances.keys {
            guard let bookmark = store.bookmark(id: bookmarkID) else { continue }
            applyBlocking(bookmarkID: bookmarkID, enabled: bookmark.blockingEnabled)
        }
    }

    /// 收藏级外观变更后立即应用：WebKit 会重新计算 prefers-color-scheme，无需刷新。
    func applyPageAppearance(bookmarkID: UUID) {
        guard let instance = instances[bookmarkID],
              let bookmark = store.bookmark(id: bookmarkID) else { return }
        applyAppearance(bookmark.effectivePageAppearance, to: instance)
    }

    /// NSAppearance 负责 prefers-color-scheme；强制深色再叠加 CSS 反色（无深色样式的站点也能变暗）。
    private func applyAppearance(_ appearance: PageAppearance, to instance: WebInstance) {
        instance.webView.appearance = appearance.webAppearance
        let controller = instance.webView.configuration.userContentController
        switch (appearance, instance.forcedDarkStyleSheet) {
        case (.dark, nil):
            instance.forcedDarkStyleSheet = ForcedDarkStyleSheet.add(to: controller)
        case (.system, let sheet?):
            ForcedDarkStyleSheet.remove(sheet, from: controller)
            instance.forcedDarkStyleSheet = nil
        case (.dark, _), (.system, nil):
            break
        }
    }

    // MARK: - Memory samples

    func memorySamples() -> [InstanceMemorySample] {
        let now = Date()
        return instances.values.map { instance in
            let bookmark = store.bookmark(id: instance.bookmarkID)
            // 直接看实例自己的 WebView：挂在窗口里且没被隐藏＝激活中。
            // 不看遮挡状态——应用退到后台或被别的窗口盖住时，这一页仍是用户要回来的页面，
            // 不能因为一分钟没看到就把它淘汰掉。被移出容器/隐藏 pane 的 WebView 不在此列。
            // 例外：当前聚合面板里的 pane 全部算前台激活，放大时被盖住的 pane 也豁免回收。
            let inAggregationPane = instance.host?.isAggregationPane == true
            let visible = instance.webView.window.map { $0.isVisible } == true
                && (inAggregationPane || !instance.webView.isHiddenOrHasHiddenAncestor)
            instance.isVisible = visible
            if visible { instance.lastVisibleAt = now }
            let pid = MemoryProbe.webProcessIdentifier(of: instance.webView)
            return InstanceMemorySample(bookmarkID: instance.bookmarkID,
                                        footprint: pid.flatMap { MemoryProbe.footprint(of: $0) },
                                        isVisible: visible,
                                        isPinned: bookmark?.isPinned ?? false,
                                        lastVisibleAt: instance.lastVisibleAt,
                                        processIdentifier: pid)
        }
    }

    // MARK: - Delegate callbacks

    func handleDidStart(bookmarkID: UUID) {
        guard let instance = instances[bookmarkID] else { return }
        instance.lastError = nil
        instance.navigationStartedAt = Date()
        log(.info, "开始加载", category: "web", bookmarkID: bookmarkID)
    }

    func handleDidFinish(bookmarkID: UUID, url: URL?) {
        guard let instance = instances[bookmarkID] else { return }
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            instance.currentURL = url
            store.updateLastURL(bookmarkID: bookmarkID, url: url.absoluteString)
            autofillCredentials(instance: instance, host: url.host)
        }
        instance.lastError = nil
        terminations[bookmarkID] = nil
        var fields = ["url": logURL(instance.currentURL)]
        if let startedAt = instance.navigationStartedAt {
            fields["ms"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
        }
        instance.navigationStartedAt = nil
        log(.info, "加载完成", category: "web", bookmarkID: bookmarkID, fields: fields)
        notifyChange()
    }

    // MARK: - Credentials

    /// 页面表单提交后回传的凭据：内容未变化时不打扰用户。
    func handleCredentialCapture(bookmarkID: UUID, host: String, username: String, password: String) {
        let host = SiteMatcher.normalizedHost(host)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty,
              username.count <= 256, password.count <= 512 else { return }
        // 消息来源已由 handler 校验；这里再确认提交页面就是当前主框架，避免跨站导航瞬间的错配。
        if let currentHost = instances[bookmarkID]?.currentURL?.host,
           !currentHost.isEmpty,
           SiteMatcher.normalizedHost(currentHost) != host {
            return
        }
        guard credentials.password(forHost: host, username: username) != password else { return }
        onCredentialCaptured?(CredentialCandidate(bookmarkID: bookmarkID,
                                                  host: host,
                                                  username: username,
                                                  password: password))
    }

    /// 导航完成后自动填充：仅在页面存在空密码框时写入，不覆盖用户已输入的内容。
    private func autofillCredentials(instance: WebInstance, host: String?) {
        guard let host, !host.isEmpty,
              let credential = credentials.credentials(forHost: host).first,
              let password = credentials.password(forHost: host, username: credential.username) else {
            return
        }
        let script = CredentialScript.fill(username: credential.username, password: password)
        instance.webView.evaluateJavaScript(script) { _, _ in }
    }

    func handleLoadFailure(bookmarkID: UUID, error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        guard let instance = instances[bookmarkID] else { return }
        instance.lastError = error.localizedDescription
        instance.navigationStartedAt = nil
        log(.error, "导航失败", category: "web", bookmarkID: bookmarkID, fields: [
            "domain": nsError.domain,
            "code": String(nsError.code),
            "detail": error.localizedDescription,
            "url": logURL(instance.currentURL ?? instance.webView.url),
        ])
        notifyChange()
    }

    func handleProcessTermination(bookmarkID: UUID) {
        guard let instance = instances.removeValue(forKey: bookmarkID) else { return }
        terminations[bookmarkID] = .crashed
        teardown(instance)
        log(.error, "网页进程终止", category: "web", bookmarkID: bookmarkID)
        notifyChange()
    }

    /// HTTP 4xx/5xx：4xx 记 warn（多为页面/接口自身问题），5xx 记 error（服务端故障）。
    func handleNavigationResponse(bookmarkID: UUID, statusCode: Int, url: URL?) {
        guard statusCode >= 400 else { return }
        log(statusCode >= 500 ? .error : .warn,
            "HTTP \(statusCode)",
            category: "http",
            bookmarkID: bookmarkID,
            fields: ["status": String(statusCode), "url": logURL(url)])
    }

    // MARK: - Diagnostics

    /// 开发者模式只影响能否打开 Web Inspector；诊断日志始终记录。
    func applyDeveloperMode() {
        let enabled = store.settings.developerMode
        for instance in instances.values {
            instance.webView.isInspectable = enabled
        }
    }

    private func log(_ level: DiagnosticLog.Level,
                     _ message: String,
                     category: String,
                     bookmarkID: UUID,
                     fields: [String: String] = [:]) {
        var fields = fields
        fields["bookmark"] = store.bookmark(id: bookmarkID)?.trimmedName ?? ""
        switch level {
        case .info:
            DiagnosticLog.shared.info(message, category: category, fields: fields)
        case .warn:
            DiagnosticLog.shared.warn(message, category: category, fields: fields)
        case .error:
            DiagnosticLog.shared.error(message, category: category, fields: fields)
        }
    }

    /// 日志里的 URL 去掉 query 与 fragment：避免把令牌、会话 ID 写进磁盘。
    private func logURL(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ""
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    private func notifyChange() {
        onChange?()
    }
}

extension PageAppearance {
    /// 页面默认交还系统外观；深色模式让 WebKit 的 prefers-color-scheme 判定为 dark。
    var webAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
