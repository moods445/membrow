import AppKit
import MembrowCore

@MainActor
final class PaneContainerView: NSView {
    let paneID: UUID
    let slot: ContentSlotView
    private weak var environment: AppEnvironment?

    private let header = PaneHeaderView()
    private let titleLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11, weight: .medium))
    private let statusLabel = makeLabel("", font: NSFont.systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let splitHorizontalButton = makeHeaderButton(title: "▤",
                                                        toolTip: "水平分割（上下）",
                                                        target: nil,
                                                        action: nil)
    private let splitVerticalButton = makeHeaderButton(title: "◫",
                                                       toolTip: "竖直分割（左右）",
                                                       target: nil,
                                                       action: nil)
    private let zoomButton = makeHeaderButton(title: "⤢",
                                              toolTip: "放大 / 还原",
                                              target: nil,
                                              action: nil)
    private let closeButton = makeHeaderButton(title: "✕",
                                               toolTip: "关闭 Pane",
                                               target: nil,
                                               action: nil)

    private var bookmark: Bookmark?
    private var isZoomed = false

    var onFocus: (() -> Void)?
    var onSplit: ((SplitAxis) -> Void)?
    var onZoom: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseWebPage: (() -> Void)?
    var onOpenFromEntry: (() -> Void)?

    init(environment: AppEnvironment, paneID: UUID) {
        self.environment = environment
        self.paneID = paneID
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
        layer?.cornerRadius = 4

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.onFocus?() }
        addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(titleLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        header.addSubview(statusLabel)

        let buttons = [closeButton, zoomButton, splitVerticalButton, splitHorizontalButton]
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            header.addSubview(button)
        }
        splitHorizontalButton.action = #selector(splitHorizontalTapped)
        splitVerticalButton.action = #selector(splitVerticalTapped)
        zoomButton.action = #selector(zoomTapped)
        closeButton.action = #selector(closeTapped)

        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.onFocusRequest = { [weak self] in self?.onFocus?() }
        addSubview(slot)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: splitHorizontalButton.leadingAnchor, constant: -6),

            splitHorizontalButton.trailingAnchor.constraint(equalTo: splitVerticalButton.leadingAnchor, constant: -2),
            splitVerticalButton.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -2),
            zoomButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            zoomButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitVerticalButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitHorizontalButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            slot.topAnchor.constraint(equalTo: header.bottomAnchor),
            slot.leadingAnchor.constraint(equalTo: leadingAnchor),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor),
            slot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 页面里的点击会被 WKWebView 吃掉，`mouseDown` 到不了本视图；
    /// 用本地事件监听兜底：点在本 pane 范围内即切换焦点，切分按钮才会作用于“选中的 pane”。
    private var clickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeClickMonitor()
        } else if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) {
                    self.onFocus?()
                }
                return event
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    func update(bookmark: Bookmark?, status: BookmarkStatus?, focused: Bool, zoomed: Bool) {
        self.bookmark = bookmark
        self.isZoomed = zoomed
        titleLabel.stringValue = bookmark?.trimmedName ?? "空 Pane"
        statusLabel.stringValue = status?.display ?? "拖入收藏"
        statusLabel.toolTip = status?.detail
        zoomButton.title = zoomed ? "⤡" : "⤢"
        layer?.borderWidth = focused ? 2 : 1
        layer?.borderColor = (focused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onFocus?()
        let menu = NSMenu()

        let horizontal = NSMenuItem(title: "水平分割（上下）", action: #selector(splitHorizontalTapped), keyEquivalent: "")
        horizontal.target = self
        menu.addItem(horizontal)

        let vertical = NSMenuItem(title: "竖直分割（左右）", action: #selector(splitVerticalTapped), keyEquivalent: "")
        vertical.target = self
        menu.addItem(vertical)

        menu.addItem(.separator())

        let zoom = NSMenuItem(title: isZoomed ? "还原 Pane" : "放大 Pane",
                              action: #selector(zoomTapped),
                              keyEquivalent: "")
        zoom.target = self
        menu.addItem(zoom)

        let close = NSMenuItem(title: "关闭 Pane", action: #selector(closeTapped), keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        if let bookmark, bookmark.kind == .dynamic {
            menu.addItem(.separator())
            if environment?.runtime.hasInstance(bookmark.id) == true {
                let closePage = NSMenuItem(title: "关闭网页", action: #selector(closePageTapped), keyEquivalent: "")
                closePage.target = self
                menu.addItem(closePage)
            }
            let entry = NSMenuItem(title: "从入口重新打开", action: #selector(openEntryTapped), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }

        return menu
    }

    @objc private func splitHorizontalTapped() {
        onFocus?()
        onSplit?(.horizontal)
    }

    @objc private func splitVerticalTapped() {
        onFocus?()
        onSplit?(.vertical)
    }

    @objc private func zoomTapped() {
        onFocus?()
        onZoom?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func closePageTapped() {
        onCloseWebPage?()
    }

    @objc private func openEntryTapped() {
        onOpenFromEntry?()
    }
}

@MainActor
final class PaneHeaderView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

@MainActor
final class PaneLayoutView: NSView {
    private weak var environment: AppEnvironment?
    private(set) var session: Session?
    private var paneViews: [UUID: PaneContainerView] = [:]
    private var explicitPanes: Set<UUID> = []

    var onStructureChanged: (() -> Void)?
    var onDropBookmark: ((UUID, UUID) -> Void)?
    var onEmptyDrop: ((UUID) -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        registerForDraggedTypes([MembrowPasteboard.bookmark])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(session: Session?) {
        self.session = session
        syncPaneViews()
        // 只标脏，不同步布局：从布局回调进来时同步触发会递归并触发 AppKit 告警。
        needsLayout = true
        refreshStatuses()
        for view in paneViews.values {
            view.slot.refresh()
        }
        updateVisibility()
    }

    private func syncPaneViews() {
        guard let environment else { return }
        let panes = session?.allPanes ?? []
        let validIDs = Set(panes.map(\.id))
        // 放大时只有目标 pane 可见；此处先判定可见性，避免隐藏 pane 在下方 layout() 隐藏它们之前
        // 就被自动激活，凭空创建 WebView（“继续上次”只应加载当前可见 pane）。
        let visiblePaneIDs: Set<UUID>
        if let zoomed = session?.zoomedPaneID {
            visiblePaneIDs = [zoomed]
        } else {
            visiblePaneIDs = validIDs
        }
        for (id, view) in paneViews where !validIDs.contains(id) {
            view.removeFromSuperview()
            paneViews[id] = nil
        }
        explicitPanes = explicitPanes.intersection(validIDs)

        for pane in panes {
            let view: PaneContainerView
            if let existing = paneViews[pane.id] {
                view = existing
            } else {
                view = PaneContainerView(environment: environment, paneID: pane.id)
                view.onFocus = { [weak self] in
                    guard let self, let session = self.session else { return }
                    guard session.focusedPaneID != pane.id else { return }
                    environment.store.focusPane(sessionID: session.id, paneID: pane.id)
                    // store 已持久化，但本视图持有的是旧快照：不同步这里边框不会变，看起来“选不中 pane”。
                    self.session?.focusedPaneID = pane.id
                    self.refreshStatuses()
                }
                view.onSplit = { [weak self] axis in
                    guard let self, let session = self.session else { return }
                    environment.store.splitPane(sessionID: session.id, paneID: pane.id, axis: axis)
                    self.onStructureChanged?()
                }
                view.onClose = { [weak self] in
                    guard let self, let session = self.session else { return }
                    environment.store.closePane(sessionID: session.id, paneID: pane.id)
                    self.onStructureChanged?()
                }
                view.onZoom = { [weak self] in
                    guard let self, let session = self.session, let current = self.session else { return }
                    let zoomed = current.zoomedPaneID == pane.id
                    environment.store.zoomPane(sessionID: session.id, paneID: pane.id, zoomed: !zoomed)
                    self.onStructureChanged?()
                }
                view.onCloseWebPage = {
                    guard let bookmarkID = pane.bookmarkID else { return }
                    environment.runtime.closeWebPage(bookmarkID: bookmarkID)
                }
                view.onOpenFromEntry = {
                    guard let bookmarkID = pane.bookmarkID else { return }
                    environment.runtime.openFromEntry(bookmarkID: bookmarkID, in: view.slot)
                }
                view.slot.onDropBookmark = { [weak self] bookmarkID in
                    self?.handleDrop(bookmarkID: bookmarkID, paneID: pane.id)
                }
                paneViews[pane.id] = view
            }
            if view.superview == nil {
                addSubview(view)
            }
            view.slot.setBookmark(pane.bookmarkID,
                                  autoActivate: (environment.autoLoadEnabled || explicitPanes.contains(pane.id))
                                      && visiblePaneIDs.contains(pane.id),
                                  allowStaticCapture: explicitPanes.contains(pane.id))
        }
    }

    private func handleDrop(bookmarkID: UUID, paneID: UUID) {
        guard let environment, let session else { return }
        environment.runtime.clearTermination(for: bookmarkID)
        explicitPanes.insert(paneID)
        environment.store.assignBookmark(bookmarkID, sessionID: session.id, paneID: paneID)
        environment.store.focusPane(sessionID: session.id, paneID: paneID)
        // 拖入＝显式打开：该收藏已在别处显示时把 WebView 搬过来。
        paneViews[paneID]?.slot.openHere(bookmarkID)
        onStructureChanged?()
    }

    override func layout() {
        super.layout()
        for view in paneViews.values {
            view.isHidden = true
        }
        guard let session, let root = session.root else {
            updateVisibility()
            return
        }

        if let zoomedID = session.zoomedPaneID, let view = paneViews[zoomedID] {
            view.frame = bounds
            view.isHidden = false
        } else {
            layoutNode(root, in: bounds)
        }
        updateVisibility()
    }

    private func layoutNode(_ node: PaneNode, in rect: NSRect) {
        switch node {
        case .pane(let pane):
            guard let view = paneViews[pane.id] else { return }
            // 尺寸可能为 0（首次布局、窗口极小）：负宽高会让 AppKit 生成超限的 autoresizing 约束。
            view.frame = NSRect(x: rect.minX + 1,
                                y: rect.minY + 1,
                                width: max(rect.width - 2, 0),
                                height: max(rect.height - 2, 0))
            view.isHidden = false
        case .split(let split):
            let divider: CGFloat = 2
            if split.axis == .horizontal {
                let available = max(rect.height - divider, 0)
                let firstHeight = min(max(floor(available * CGFloat(split.ratio)), 0), available)
                let firstRect = NSRect(x: rect.minX,
                                       y: rect.minY + available - firstHeight,
                                       width: rect.width,
                                       height: firstHeight)
                let secondRect = NSRect(x: rect.minX,
                                        y: rect.minY,
                                        width: rect.width,
                                        height: max(available - firstHeight, 0))
                layoutNode(split.first, in: firstRect)
                layoutNode(split.second, in: secondRect)
            } else {
                let available = max(rect.width - divider, 0)
                let firstWidth = min(max(floor(available * CGFloat(split.ratio)), 0), available)
                let firstRect = NSRect(x: rect.minX,
                                       y: rect.minY,
                                       width: firstWidth,
                                       height: rect.height)
                let secondRect = NSRect(x: rect.minX + firstWidth + divider,
                                        y: rect.minY,
                                        width: max(available - firstWidth, 0),
                                        height: rect.height)
                layoutNode(split.first, in: firstRect)
                layoutNode(split.second, in: secondRect)
            }
        }
    }

    func refreshStatuses() {
        guard let environment, let session else { return }
        for pane in session.allPanes {
            guard let view = paneViews[pane.id] else { continue }
            let bookmark = pane.bookmarkID.flatMap { environment.store.bookmark(id: $0) }
            let status = bookmark.map { environment.status(for: $0) }
            view.update(bookmark: bookmark,
                        status: status,
                        focused: session.focusedPaneID == pane.id,
                        zoomed: session.zoomedPaneID == pane.id)
        }
    }

    /// 聚合“打开全部网页”：逐 pane 复用或创建实例。
    /// 不做可见性过滤（放大时隐藏的 pane 也打开）；静态收藏走静态视图，不在此列。
    func loadAllPages() {
        guard let environment, let session else { return }
        for pane in session.allPanes {
            guard let bookmarkID = pane.bookmarkID,
                  environment.store.bookmark(id: bookmarkID)?.kind == .dynamic,
                  let slot = paneViews[pane.id]?.slot else { continue }
            explicitPanes.insert(pane.id)
            environment.runtime.clearTermination(for: bookmarkID)
            if environment.runtime.instance(for: bookmarkID) == nil {
                environment.runtime.activate(bookmarkID: bookmarkID, in: slot)
            } else {
                slot.openHere(bookmarkID)
            }
        }
        refreshAllSlots()
    }

    func refreshAllSlots() {
        for view in paneViews.values {
            view.slot.refresh()
        }
        refreshStatuses()
    }

    private func updateVisibility() {
        for view in paneViews.values {
            view.slot.refreshVisibility()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard session?.root == nil,
              sender.draggingPasteboard.string(forType: MembrowPasteboard.bookmark) != nil else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard session?.root == nil,
              let raw = sender.draggingPasteboard.string(forType: MembrowPasteboard.bookmark),
              let id = UUID(uuidString: raw) else {
            return false
        }
        onEmptyDrop?(id)
        return true
    }
}
