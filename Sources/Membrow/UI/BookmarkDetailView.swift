import AppKit
import MembrowCore

@MainActor
final class BookmarkDetailView: NSView {
    private weak var environment: AppEnvironment?
    private(set) var bookmarkID: UUID?

    private let titleLabel = makeLabel("", font: NSFont.systemFont(ofSize: 14, weight: .semibold))
    private let subtitleLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let statusLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let backButton = makeHeaderButton(title: "‹", toolTip: "后退", target: nil, action: nil)
    private let forwardButton = makeHeaderButton(title: "›", toolTip: "前进", target: nil, action: nil)
    private let reloadButton = makeHeaderButton(title: "刷新", toolTip: "刷新网页", target: nil, action: nil)
    private let closePageButton = makeHeaderButton(title: "关闭网页", toolTip: "关闭网页并释放内存", target: nil, action: nil)
    private let entryButton = makeHeaderButton(title: "从入口打开", toolTip: "从收藏入口地址重新打开", target: nil, action: nil)
    private let slot: ContentSlotView
    private let placeholder = MessageView()
    private let navigationStack = NSStackView()
    private var allowStaticCapture = true

    init(environment: AppEnvironment) {
        self.environment = environment
        self.slot = ContentSlotView(environment: environment)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(subtitleLabel)
        header.addSubview(statusLabel)

        navigationStack.orientation = .horizontal
        navigationStack.spacing = 6
        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(navigationStack)

        for button in [backButton, forwardButton, reloadButton, closePageButton, entryButton] {
            button.target = self
            navigationStack.addArrangedSubview(button)
        }
        backButton.action = #selector(backTapped)
        forwardButton.action = #selector(forwardTapped)
        reloadButton.action = #selector(reloadTapped)
        closePageButton.action = #selector(closePageTapped)
        entryButton.action = #selector(entryTapped)

        slot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slot)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true
        addSubview(placeholder)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 46),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: navigationStack.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: navigationStack.leadingAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 1),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: navigationStack.leadingAnchor, constant: -8),

            navigationStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            navigationStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            slot.topAnchor.constraint(equalTo: header.bottomAnchor),
            slot.leadingAnchor.constraint(equalTo: leadingAnchor),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor),
            slot.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: header.bottomAnchor),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        placeholder.configure(symbol: "○", title: "选择左侧收藏")
    }

    func show(bookmarkID: UUID, allowStaticCapture: Bool = true) {
        self.bookmarkID = bookmarkID
        self.allowStaticCapture = allowStaticCapture
        slot.setBookmark(bookmarkID, autoActivate: true, allowStaticCapture: allowStaticCapture)
        refresh()
    }

    /// 窗口遮挡状态变化时同步一次可见性：聚合视图走 PaneLayoutView.update，详情视图没人触发。
    func refreshVisibility() {
        slot.refreshVisibility()
    }

    func refresh() {
        guard let environment, let bookmarkID, let bookmark = environment.store.bookmark(id: bookmarkID) else {
            titleLabel.stringValue = ""
            subtitleLabel.stringValue = ""
            statusLabel.stringValue = ""
            navigationStack.isHidden = true
            placeholder.isHidden = false
            return
        }

        placeholder.isHidden = true
        titleLabel.stringValue = bookmark.displayTitle
        titleLabel.toolTip = bookmark.displayTitle

        let proxy = environment.store.resolvedProxy(for: bookmark).proxy
        subtitleLabel.stringValue = "\(bookmark.entryURL) · \(proxy.displayDescription)"
        subtitleLabel.toolTip = subtitleLabel.stringValue

        let status = environment.status(for: bookmark)
        statusLabel.stringValue = status.detail.isEmpty ? status.display : "\(status.display) · \(status.detail)"
        statusLabel.toolTip = status.detail

        let isDynamic = bookmark.kind == .dynamic
        navigationStack.isHidden = !isDynamic

        if let instance = environment.runtime.instance(for: bookmark.id) {
            backButton.isEnabled = instance.webView.canGoBack
            forwardButton.isEnabled = instance.webView.canGoForward
            reloadButton.isEnabled = true
            closePageButton.isEnabled = true
            entryButton.isEnabled = true
        } else {
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            reloadButton.isEnabled = false
            closePageButton.isEnabled = false
            entryButton.isEnabled = isDynamic
        }

        slot.setBookmark(bookmarkID, autoActivate: true, allowStaticCapture: allowStaticCapture)
        slot.refresh()
    }

    @objc private func backTapped() {
        guard let bookmarkID else { return }
        environment?.runtime.goBack(bookmarkID: bookmarkID)
    }

    @objc private func forwardTapped() {
        guard let bookmarkID else { return }
        environment?.runtime.goForward(bookmarkID: bookmarkID)
    }

    @objc private func reloadTapped() {
        guard let bookmarkID else { return }
        // 图标缺失时随刷新补抓，老收藏不重配也能补上。
        environment?.siteInfo.refreshIconIfMissing(bookmarkID: bookmarkID)
        environment?.runtime.reload(bookmarkID: bookmarkID)
    }

    @objc private func closePageTapped() {
        guard let bookmarkID else { return }
        environment?.runtime.closeWebPage(bookmarkID: bookmarkID)
    }

    @objc private func entryTapped() {
        guard let bookmarkID, let environment else { return }
        if environment.runtime.hasInstance(bookmarkID) {
            environment.runtime.openFromEntry(bookmarkID: bookmarkID)
        } else {
            environment.runtime.activate(bookmarkID: bookmarkID, in: slot, useEntry: true)
        }
    }
}

extension ProxySettings {
    var displayDescription: String {
        switch mode {
        case .direct:
            return "直连"
        case .system:
            return "系统代理"
        case .custom:
            return "HTTP 代理 \(host):\(port)"
        }
    }
}
