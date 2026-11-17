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
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = handler
        webView.uiDelegate = handler

        return WebInstance(bookmarkID: bookmark.id,
                           webView: webView,
                           handler: handler,
                           blockingEnabled: bookmark.blockingEnabled)
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
        notifyChange()
    }

    func evict(bookmarkID: UUID) {
        guard let instance = instances.removeValue(forKey: bookmarkID) else { return }
        terminations[bookmarkID] = .evicted
        teardown(instance)
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

    // MARK: - Memory samples

    func memorySamples() -> [InstanceMemorySample] {
        let now = Date()
        return instances.values.map { instance in
            let bookmark = store.bookmark(id: instance.bookmarkID)
            // 可见性以宿主实时状态为准：instance.isVisible 只在 refreshVisibility 时更新，
            // 切换收藏后新实例、窗口遮挡变化都可能让它滞后为 false，
            // 那会把前台正在看的页面喂成"可淘汰"。
            let visible = instance.host?.isEffectivelyVisible ?? false
            instance.isVisible = visible
            if visible { instance.lastVisibleAt = now }
            return InstanceMemorySample(bookmarkID: instance.bookmarkID,
                                        footprint: MemoryProbe.footprint(of: instance.webView),
                                        isVisible: visible,
                                        isPinned: bookmark?.isPinned ?? false,
                                        lastVisibleAt: instance.lastVisibleAt)
        }
    }

    // MARK: - Delegate callbacks

    func handleDidStart(bookmarkID: UUID) {
        instances[bookmarkID]?.lastError = nil
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
        notifyChange()
    }

    // MARK: - Credentials

    /// 页面表单提交后回传的凭据：内容未变化时不打扰用户。
    func handleCredentialCapture(bookmarkID: UUID, host: String, username: String, password: String) {
        let host = SiteMatcher.normalizedHost(host)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty,
              username.count <= 256, password.count <= 512 else { return }
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
        notifyChange()
    }

    func handleProcessTermination(bookmarkID: UUID) {
        guard let instance = instances.removeValue(forKey: bookmarkID) else { return }
        terminations[bookmarkID] = .crashed
        teardown(instance)
        notifyChange()
    }

    private func notifyChange() {
        onChange?()
    }
}
