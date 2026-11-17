import AppKit
import MembrowCore

@MainActor
final class ContentSlotView: NSView, ContentHosting {
    private weak var environment: AppEnvironment?
    private(set) var bookmarkID: UUID?
    private var autoActivate = true
    private var allowStaticCapture = false
    private var originalPageMode = false
    private var lastKind: BookmarkKind?

    private let messageView = MessageView()
    private let returnButton = NSButton(title: "返回静态视图", target: nil, action: nil)
    private var currentContentView: NSView?
    private var staticView: StaticContentView?

    var onDropBookmark: ((UUID) -> Void)?
    var onFocusRequest: (() -> Void)?

    var hostBookmarkID: UUID? { bookmarkID }

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
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        messageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageView)
        NSLayoutConstraint.activate([
            messageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageView.topAnchor.constraint(equalTo: topAnchor),
            messageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        returnButton.translatesAutoresizingMaskIntoConstraints = false
        returnButton.bezelStyle = .rounded
        returnButton.controlSize = .small
        returnButton.font = NSFont.systemFont(ofSize: 11)
        returnButton.target = self
        returnButton.action = #selector(returnToStatic)
        returnButton.isHidden = true
        addSubview(returnButton)
        NSLayoutConstraint.activate([
            returnButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            returnButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
        ])

        registerForDraggedTypes([MembrowPasteboard.bookmark])
    }

    func setBookmark(_ id: UUID?, autoActivate: Bool, allowStaticCapture: Bool = false) {
        let kind = id.flatMap { environment?.store.bookmark(id: $0)?.kind }
        if bookmarkID == id, lastKind == kind {
            let activationChanged = !self.autoActivate && autoActivate
            let captureChanged = !self.allowStaticCapture && allowStaticCapture
            self.autoActivate = autoActivate
            self.allowStaticCapture = self.allowStaticCapture || allowStaticCapture
            if activationChanged || captureChanged {
                render(takeOver: activationChanged)
            }
            return
        }

        if let old = bookmarkID {
            environment?.runtime.unregister(host: self)
            environment?.runtime.setVisible(bookmarkID: old, visible: false)
        }
        bookmarkID = id
        lastKind = kind
        self.autoActivate = autoActivate
        self.allowStaticCapture = allowStaticCapture
        originalPageMode = false
        currentContentView?.removeFromSuperview()
        currentContentView = nil
        staticView?.removeFromSuperview()
        staticView = nil

        if let id {
            environment?.runtime.register(host: self, for: id)
        }
        // 绑定变化＝用户显式打开：实例在别处时搬到这里，不在原位置留占位。
        render(takeOver: true)
    }

    // MARK: - Rendering

    func refresh() {
        render()
        staticView?.refresh()
    }

    /// 显式打开（拖入 pane 等动作）：实例在别处时把 WebView 搬过来。
    func openHere(_ id: UUID) {
        if bookmarkID != id {
            setBookmark(id, autoActivate: true, allowStaticCapture: allowStaticCapture)
        }
        autoActivate = true
        render(takeOver: true)
    }

    func render(takeOver: Bool = false) {
        guard let environment else { return }
        guard let bookmarkID, let bookmark = environment.store.bookmark(id: bookmarkID) else {
            lastKind = nil
            returnButton.isHidden = true
            showMessage(symbol: "＋",
                        title: "把收藏拖进来",
                        detail: "从左侧收藏区拖入动态或静态收藏")
            return
        }

        if bookmark.kind == .staticPage && !originalPageMode {
            returnButton.isHidden = true
            renderStatic(bookmark, environment: environment)
            return
        }

        returnButton.isHidden = !originalPageMode
        renderWeb(bookmark, environment: environment, takeOver: takeOver)
    }

    private func renderStatic(_ bookmark: Bookmark, environment: AppEnvironment) {
        let view: StaticContentView
        if let existing = staticView {
            view = existing
        } else {
            view = StaticContentView(environment: environment)
            view.onUseOriginalPage = { [weak self] _ in
                guard let self else { return }
                self.originalPageMode = true
                self.autoActivate = true
                self.render()
            }
            staticView = view
        }
        installContent(view)
        view.load(bookmarkID: bookmark.id, allowAutoCapture: allowStaticCapture)
    }

    private func renderWeb(_ bookmark: Bookmark, environment: AppEnvironment, takeOver: Bool) {
        if let instance = environment.runtime.instance(for: bookmark.id) {
            if instance.host === self {
                installContent(instance.webView)
            } else if takeOver || takesOverFromHiddenHost(instance) {
                // 复用同一 WebView：直接搬到当前容器，原位置只留占位。
                environment.runtime.move(bookmarkID: bookmark.id, to: self)
            } else {
                showMessage(symbol: "◐",
                            title: "已在别处打开",
                            detail: "该收藏的网页正在其他位置显示。",
                            actionTitle: "移到这里") { [weak self] in
                    guard let self else { return }
                    environment.runtime.move(bookmarkID: bookmark.id, to: self)
                }
            }
            return
        }

        if let termination = environment.runtime.termination(for: bookmark.id) {
            let symbol: String
            let title: String
            let detail: String
            switch termination {
            case .evicted:
                symbol = "▼"
                title = "已回收"
                detail = "内存管控已释放该网页，点击重新载入。"
            case .closed:
                symbol = "○"
                title = "已关闭"
                detail = "网页已关闭，收藏配置与登录态保留。"
            case .crashed:
                symbol = "!"
                title = "网页进程已结束"
                detail = "重新载入会创建新的网页进程。"
            }
            showMessage(symbol: symbol, title: title, detail: detail, actionTitle: "重新载入") { [weak self] in
                guard let self else { return }
                environment.runtime.activate(bookmarkID: bookmark.id, in: self)
            }
            return
        }

        if autoActivate && isEffectivelyVisible {
            environment.runtime.activate(bookmarkID: bookmark.id, in: self)
            return
        }

        showMessage(symbol: "○",
                    title: "未启动",
                    detail: "点击打开该收藏（不会提前创建 WebView）。",
                    actionTitle: "打开") { [weak self] in
            guard let self else { return }
            self.autoActivate = true
            environment.runtime.activate(bookmarkID: bookmark.id, in: self)
        }
    }

    /// 原位置已不可见（例如切到聚合时独立视图被移除）→ 把实例接到当前可见的容器。
    /// 双方都可见时保留占位，避免两个 pane 互相抢实例。
    private func takesOverFromHiddenHost(_ instance: WebInstance) -> Bool {
        guard isEffectivelyVisible, let host = instance.host else { return false }
        return !host.isEffectivelyVisible
    }

    private func showMessage(symbol: String,
                             title: String,
                             detail: String = "",
                             actionTitle: String? = nil,
                             action: (() -> Void)? = nil) {
        messageView.configure(symbol: symbol, title: title, detail: detail, actionTitle: actionTitle, action: action)
        messageView.isHidden = false
        currentContentView?.isHidden = true
        addSubview(messageView, positioned: .above, relativeTo: nil)
    }

    private func installContent(_ view: NSView) {
        if currentContentView !== view || view.superview !== self {
            currentContentView?.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            currentContentView = view
        }
        view.isHidden = false
        messageView.isHidden = true
        addSubview(returnButton, positioned: .above, relativeTo: nil)
    }

    // MARK: - ContentHosting

    func attachWebView(_ webView: NSView) {
        installContent(webView)
    }

    // MARK: - Visibility

    var isEffectivelyVisible: Bool {
        guard let window, window.isVisible else { return false }
        if isHiddenOrHasHiddenAncestor { return false }
        return window.occlusionState.contains(.visible)
    }

    private var lastVisibleState = false

    func refreshVisibility() {
        guard let environment, let bookmarkID else { return }
        let visible = isEffectivelyVisible
        let becameVisible = visible && !lastVisibleState
        lastVisibleState = visible
        environment.runtime.setVisible(bookmarkID: bookmarkID, visible: visible)
        if becameVisible {
            let bookmark = environment.store.bookmark(id: bookmarkID)
            if bookmark?.kind == .staticPage, !originalPageMode {
                staticView?.refresh()
            } else {
                render()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshVisibility()
    }

    // MARK: - Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: MembrowPasteboard.bookmark) != nil else {
            return []
        }
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderWidth = 0
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let raw = sender.draggingPasteboard.string(forType: MembrowPasteboard.bookmark),
              let id = UUID(uuidString: raw) else {
            return false
        }
        onDropBookmark?(id)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }

    @objc private func returnToStatic() {
        originalPageMode = false
        render()
    }
}
