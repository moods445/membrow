import AppKit
import MembrowCore
import WebKit

@MainActor
final class StaticContentView: NSView {
    private weak var environment: AppEnvironment?
    private(set) var bookmarkID: UUID?
    private var allowAutoCapture = false
    private var didAutoCapture = false

    private let statusLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let webButton = NSButton(title: "使用原网页", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let messageView = MessageView()
    private var contentTopConstraint: NSLayoutConstraint?
    private var messageTopConstraint: NSLayoutConstraint?
    private var headerView: NSView?
    /// 精简快照用的 WebView（禁用 JS），只在快照模式下存在，切页/刷新即释放。
    private var snapshotWebView: WKWebView?
    private var snapshotTopConstraint: NSLayoutConstraint?
    private var usesSnapshot = false
    /// 快照因内存预算被回收后不再自动重建，直到用户点刷新或切换收藏。
    private var snapshotEvicted = false

    var onUseOriginalPage: ((UUID) -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        headerView = header

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(statusLabel)

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.font = NSFont.systemFont(ofSize: 11)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        header.addSubview(refreshButton)

        webButton.translatesAutoresizingMaskIntoConstraints = false
        webButton.bezelStyle = .inline
        webButton.isBordered = false
        webButton.font = NSFont.systemFont(ofSize: 11)
        webButton.target = self
        webButton.action = #selector(webTapped)
        header.addSubview(webButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        messageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scrollView)
        addSubview(messageView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            webButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            webButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: webButton.leadingAnchor, constant: -4),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -8),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            messageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        contentTopConstraint = scrollView.topAnchor.constraint(equalTo: header.bottomAnchor)
        messageTopConstraint = messageView.topAnchor.constraint(equalTo: header.bottomAnchor)
        contentTopConstraint?.isActive = true
        messageTopConstraint?.isActive = true
    }

    func load(bookmarkID: UUID, allowAutoCapture: Bool) {
        if self.bookmarkID != bookmarkID {
            self.bookmarkID = bookmarkID
            didAutoCapture = false
            textView.string = ""
            snapshotEvicted = false
            teardownSnapshot()
        }
        self.allowAutoCapture = allowAutoCapture
        reload()
    }

    func refresh() {
        reload()
    }

    private func reload() {
        guard let environment,
              let bookmarkID,
              let bookmark = environment.store.bookmark(id: bookmarkID) else {
            messageView.configure(symbol: "○", title: "没有可展示的收藏")
            showMessage(true)
            statusLabel.stringValue = ""
            return
        }

        usesSnapshot = bookmark.staticConfig.displayMode == .snapshot
        let phase = environment.staticManager.phase(for: bookmark.id)
        let document = environment.staticManager.document(for: bookmark.id)
        let freshness = environment.store.freshness(for: bookmark)
        // 快照模式下缓存里没有快照（刚切换显示方式、或旧版本缓存）也要补抓。
        let snapshotMissing = usesSnapshot && (document?.snapshotHTML?.isEmpty ?? true)

        if allowAutoCapture && !didAutoCapture && phase != .updating
            && (freshness != .fresh || snapshotMissing) {
            didAutoCapture = true
            environment.staticManager.present(bookmarkID: bookmark.id,
                                              allowAutoCapture: true,
                                              forceRefresh: snapshotMissing)
            return
        }

        var statusText: String
        switch phase {
        case .updating:
            statusText = document == nil ? "抓取中…" : "更新中…（显示旧缓存）"
        case .failed(let message):
            if document != nil {
                statusText = "更新失败：\(message)（旧缓存保留）"
            } else {
                statusText = "抓取失败"
            }
        case .idle:
            if let document {
                let time = Self.formatter.string(from: document.fetchedAt)
                if usesSnapshot {
                    statusText = snapshotMissing ? "快照未生成 · 显示 Markdown" : "已缓存 · 快照 · \(time)"
                } else {
                    statusText = freshness == .fresh ? "已缓存 · \(time)" : "缓存已过期 · \(time)"
                }
            } else {
                statusText = "尚无缓存"
            }
        }
        statusLabel.stringValue = statusText
        statusLabel.toolTip = statusText

        if let document {
            render(document)
            showMessage(false)
            return
        }

        showMessage(true)
        switch phase {
        case .updating:
            messageView.configure(symbol: "↻", title: "正在抓取正文…", detail: "抓取完成后会立即显示")
        case .failed(let message):
            messageView.configure(symbol: "!", title: "抓取失败", detail: message, actionTitle: "重试") { [weak self] in
                self?.forceRefresh()
            }
        case .idle:
            messageView.configure(symbol: "○",
                                  title: "尚无缓存",
                                  detail: "静态收藏只展示已抓取的正文，启动时不会自动抓取。",
                                  actionTitle: "抓取正文") { [weak self] in
                self?.forceRefresh()
            }
        }
    }

    private func render(_ document: CachedDocument) {
        if usesSnapshot, !snapshotEvicted, let html = document.snapshotHTML, !html.isEmpty {
            showSnapshot(html, baseURL: URL(string: document.metadata.sourceURL))
            return
        }
        teardownSnapshot()
        renderMarkdown(document)
    }

    /// 精简快照：禁用 JS 的 WebView，数据仓库用非持久化，退出即释放。
    private func showSnapshot(_ html: String, baseURL: URL?) {
        let web: WKWebView
        if let existing = snapshotWebView {
            web = existing
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            web = WKWebView(frame: .zero, configuration: configuration)
            web.translatesAutoresizingMaskIntoConstraints = false
            addSubview(web)
            let top = web.topAnchor.constraint(equalTo: headerView?.bottomAnchor ?? topAnchor)
            NSLayoutConstraint.activate([
                top,
                web.leadingAnchor.constraint(equalTo: leadingAnchor),
                web.trailingAnchor.constraint(equalTo: trailingAnchor),
                web.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            snapshotTopConstraint = top
            snapshotWebView = web
        }
        snapshotWebView?.isHidden = false
        // 纳入内存监控：可见时免淘汰，隐藏 pane 的快照按 LRU 回收。
        if let bookmarkID {
            environment?.snapshots.register(
                bookmarkID: bookmarkID,
                webView: web,
                isVisible: { [weak self] in self?.isSnapshotVisible ?? false },
                onEvict: { [weak self] in self?.releaseSnapshotForMemory() }
            )
        }
        web.loadHTMLString(html, baseURL: baseURL)
    }

    private var isSnapshotVisible: Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// 内存预算回收快照：销毁 WebView 并回退到已缓存的 Markdown。
    private func releaseSnapshotForMemory() {
        guard snapshotWebView != nil else { return }
        snapshotEvicted = true
        teardownSnapshot()
        if let bookmarkID, let document = environment?.staticManager.document(for: bookmarkID) {
            renderMarkdown(document)
            showMessage(false)
        }
        statusLabel.stringValue = "快照已按内存预算回收 · 显示 Markdown"
        statusLabel.toolTip = statusLabel.stringValue
    }

    private func teardownSnapshot() {
        guard let web = snapshotWebView else { return }
        if let bookmarkID {
            environment?.snapshots.unregister(bookmarkID: bookmarkID)
        }
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
        snapshotTopConstraint?.isActive = false
        snapshotTopConstraint = nil
        snapshotWebView = nil
    }

    private func renderMarkdown(_ document: CachedDocument) {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let attributed: NSAttributedString
        if let parsed = try? AttributedString(markdown: document.markdown, options: options) {
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            if mutable.length > 0 {
                mutable.addAttribute(.foregroundColor,
                                     value: NSColor.labelColor,
                                     range: NSRange(location: 0, length: mutable.length))
            }
            attributed = mutable
        } else {
            attributed = NSAttributedString(string: document.markdown,
                                            attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                         .foregroundColor: NSColor.labelColor])
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func showMessage(_ show: Bool) {
        messageView.isHidden = !show
        let snapshotActive = usesSnapshot && snapshotWebView != nil
        scrollView.isHidden = show || snapshotActive
        snapshotWebView?.isHidden = show
    }

    private func forceRefresh() {
        guard let bookmarkID else { return }
        snapshotEvicted = false
        didAutoCapture = true
        environment?.staticManager.forceRefresh(bookmarkID: bookmarkID)
    }

    @objc private func refreshTapped() {
        forceRefresh()
    }

    @objc private func webTapped() {
        guard let bookmarkID else { return }
        onUseOriginalPage?(bookmarkID)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
