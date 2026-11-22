import AppKit
import MembrowCore

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// 侧栏三态布局：左、仅内容、右。
    enum SidebarPlacement: String {
        case leading
        case hidden
        case trailing
    }

    let environment: AppEnvironment
    private let splitViewController = NSSplitViewController()
    private let rootController = MainWindowRootController()
    private let sidebar: SidebarViewController
    private let content: MainContentViewController
    private let statusBar = StatusBarView()
    private var sidebarItem: NSSplitViewItem!
    private let layoutControl = NSSegmentedControl()
    private var placement: SidebarPlacement = .leading
    private var preferredPlacement: SidebarPlacement = .leading
    /// 侧栏显示模式：仅图标栏 / 完整栏，由状态栏左下角按钮循环切换。
    private var sidebarMode: SidebarDisplayMode = .expanded
    private var isHandlingChange = false
    private var occlusionObserver: NSObjectProtocol?
    private var splitViewObserver: NSObjectProtocol?
    /// 站点信息逐个抓完会连续触发 onChange，合并成一次刷新。
    private var siteInfoRefreshWork: DispatchWorkItem?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.sidebar = SidebarViewController(environment: environment)
        self.content = MainContentViewController(environment: environment)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Membrow"
        window.minSize = NSSize(width: 880, height: 560)
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("MembrowMainWindow")

        super.init(window: window)
        window.delegate = self
        buildSplitView()
        wireCallbacks()
        sidebar.reloadAll()

        if let session = environment.store.selectedSession {
            content.showSession(id: session.id)
        } else {
            content.showEmpty()
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                self.content.refreshAll()
                self.sidebar.reloadStatuses()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        if let splitViewObserver {
            NotificationCenter.default.removeObserver(splitViewObserver)
        }
    }

    private func buildSplitView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // 完整模式最小只能拖到“仅图标栏”宽度，是否真的切到图标栏由 sidebarDidResize 判定。
        sidebarItem.minimumThickness = SidebarLayout.railWidth
        sidebarItem.maximumThickness = SidebarLayout.expandedDefaultWidth
        // 折叠只由“仅显示内容”程序控制，不允许用户把侧栏一路拖到 0。
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultHigh
        self.sidebarItem = sidebarItem

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 520

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.autosaveName = "MembrowSplitView"

        // 拖宽小于完整栏下限即视为“收起为图标栏”，并把展开宽度记下来供下次恢复。
        splitViewObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitViewController.splitView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sidebarDidResize()
            }
        }

        // 先按上次布局排好顺序，再挂到窗口：这样 split view 自动保存的宽度按同一顺序套用。
        restorePlacement()
        restoreSidebarMode()
        installLayoutControl()
        installStatusBar()

        // 状态栏通栏在窗口底部：用容器承载 split view + 状态栏，
        // 直接把 splitViewController 设为 contentViewController 会让 split view 占满整个内容视图。
        rootController.view.addSubview(splitViewController.view)
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        rootController.addChild(splitViewController)
        window?.contentViewController = rootController
        layoutSplitAndStatusBar()
        updateLayoutControl()
        updateStatusBar()
    }

    private func layoutSplitAndStatusBar() {
        let rootView = rootController.view
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitViewController.view.topAnchor.constraint(equalTo: rootView.topAnchor),
            splitViewController.view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            splitViewController.view.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            splitViewController.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func installStatusBar() {
        rootController.view.addSubview(statusBar)
        statusBar.onToggle = { [weak self] in
            self?.cycleSidebarMode()
        }
    }

    // MARK: - 侧栏布局

    private static let placementKey = "sidebarPlacement"
    private static let preferredPlacementKey = "sidebarPreferredPlacement"
    private static let sidebarModeKey = "sidebarDisplayMode"
    private static let sidebarExpandedWidthKey = "sidebarExpandedWidth"

    private func restorePlacement() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.placementKey).flatMap(SidebarPlacement.init(rawValue:)) ?? .leading
        let preferred = defaults.string(forKey: Self.preferredPlacementKey)
            .flatMap(SidebarPlacement.init(rawValue:)) ?? .leading
        preferredPlacement = preferred == .hidden ? .leading : preferred
        apply(placement: saved)
    }

    /// 恢复上次的侧栏显示模式；默认完整栏，避免老用户升级后侧栏突然只剩图标。
    private func restoreSidebarMode() {
        let raw = UserDefaults.standard.string(forKey: Self.sidebarModeKey)
            ?? SidebarDisplayMode.expanded.rawValue
        applySidebarMode(SidebarDisplayMode(rawValue: raw) ?? .expanded)
    }

    private func applySidebarMode(_ mode: SidebarDisplayMode, forcePosition: Bool = false) {
        sidebarMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.sidebarModeKey)
        sidebar.applyDisplayMode(mode)
        layoutSidebarThickness(forcePosition: forcePosition)
        updateStatusBar()
    }

    /// 状态栏左下角按钮：在“仅图标栏”和“完整侧栏”之间循环。
    @objc func cycleSidebarMode() {
        // 侧栏处于“仅显示内容”时先恢复位置：rail 模式不改折叠态，否则第一次点击看起来毫无反应。
        if placement == .hidden {
            apply(placement: preferredPlacement)
            updateLayoutControl()
        }
        applySidebarMode(sidebarMode.next, forcePosition: true)
    }

    private func layoutSidebarThickness(forcePosition: Bool = false) {
        switch sidebarMode {
        case .rail:
            sidebarItem.minimumThickness = SidebarLayout.railWidth
            sidebarItem.maximumThickness = SidebarLayout.railWidth
        case .expanded:
            let maxWidth = max(SidebarLayout.expandedMinimumWidth,
                               (window?.frame.width ?? 1200) * SidebarLayout.expandedMaximumWidthRatio)
            sidebarItem.minimumThickness = SidebarLayout.railWidth
            sidebarItem.maximumThickness = maxWidth
            // 折叠只由 placement 控制：这里若解除折叠，启动时恢复的“仅显示内容”会被模式恢复覆盖。
            guard forcePosition, splitViewController.splitView.frame.width > 0 else { return }
            let saved = UserDefaults.standard.double(forKey: Self.sidebarExpandedWidthKey)
            let width = saved > 0 ? CGFloat(saved) : SidebarLayout.expandedDefaultWidth
            let clamped = min(max(width, SidebarLayout.expandedMinimumWidth), maxWidth)
            let position = placement == .trailing
                ? splitViewController.splitView.frame.width - clamped
                : clamped
            splitViewController.splitView.setPosition(max(position, SidebarLayout.railWidth), ofDividerAt: 0)
        }
    }

    /// 拖过完整栏下限就自动收成图标栏；否则记住当前展开宽度。
    private func sidebarDidResize() {
        guard sidebarMode == .expanded, placement != .hidden else { return }
        let splitView = splitViewController.splitView
        guard splitView.frame.width > 0 else { return }
        // 缩放窗口时 AppKit 会把侧栏压到 30% 上限，这不是用户拖出的宽度，不该写回记忆值。
        guard window?.inLiveResize != true else { return }
        let width = sidebar.view.frame.width
        // 分隔条厚度/坐标取整可能让恢复宽度略低于下限，留 1pt 容差避免“展开后立刻弹回收起”。
        if width < SidebarLayout.expandedMinimumWidth - 1 {
            applySidebarMode(.rail)
        } else {
            UserDefaults.standard.set(width, forKey: Self.sidebarExpandedWidthKey)
        }
    }

    private func updateStatusBar() {
        let settings = environment.store.settings
        let text = MemoryStatusFormatter.text(
            totalFootprint: environment.memoryMonitor.lastPlan?.totalFootprint,
            budgetMB: settings.memoryBudgetMB,
            dynamicInstances: environment.runtime.instanceCount,
            snapshots: environment.snapshots.count
        )
        statusBar.configure(mode: sidebarMode, memoryText: text)
    }

    private func installLayoutControl() {
        layoutControl.segmentCount = 3
        layoutControl.trackingMode = .selectOne
        layoutControl.segmentStyle = .capsule
        layoutControl.controlSize = .small
        layoutControl.target = self
        layoutControl.action = #selector(layoutControlChanged)
        let symbols = ["sidebar.left", "rectangle", "sidebar.right"]
        let titles = ["侧栏在左", "仅显示内容", "侧栏在右"]
        for index in 0..<3 {
            if let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: titles[index]) {
                layoutControl.setImage(image, forSegment: index)
            } else {
                layoutControl.setLabel(titles[index], forSegment: index)
            }
            layoutControl.setToolTip(titles[index], forSegment: index)
            layoutControl.setWidth(36, forSegment: index)
        }
        layoutControl.sizeToFit()

        // 标题栏配件要求视图尺寸固定：用无自动布局的容器承载，
        // 直接把控件当 accessory.view 并改宽度会触发 AppKit 断言崩溃。
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: layoutControl.frame.width + 12,
                                             height: 24))
        layoutControl.frame = NSRect(x: 6,
                                     y: (24 - layoutControl.frame.height) / 2,
                                     width: layoutControl.frame.width,
                                     height: layoutControl.frame.height)
        container.addSubview(layoutControl)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func layoutControlChanged() {
        let target: SidebarPlacement
        switch layoutControl.selectedSegment {
        case 1: target = .hidden
        case 2: target = .trailing
        default: target = .leading
        }
        apply(placement: target)
        updateLayoutControl()
    }

    private func apply(placement target: SidebarPlacement) {
        if target != .hidden {
            preferredPlacement = target
        }
        switch target {
        case .hidden:
            sidebarItem.isCollapsed = true
        case .leading:
            moveSidebar(to: 0)
            sidebarItem.isCollapsed = false
        case .trailing:
            moveSidebar(to: splitViewController.splitViewItems.count - 1)
            sidebarItem.isCollapsed = false
        }
        // 先提交新位置：layoutSidebarThickness 要用它决定分隔条从哪一侧算宽度，
        // 否则左右切换时会按旧位置摆错宽度（内容区被压到最小宽度）。
        placement = target
        if target != .hidden {
            // 从“仅显示内容”恢复时 split view 可能把侧栏宽度压到下限以下，按当前模式重新摆好。
            layoutSidebarThickness(forcePosition: sidebarMode == .expanded)
        }
        UserDefaults.standard.set(target.rawValue, forKey: Self.placementKey)
        UserDefaults.standard.set(preferredPlacement.rawValue, forKey: Self.preferredPlacementKey)
    }

    private func moveSidebar(to index: Int) {
        guard let current = splitViewController.splitViewItems.firstIndex(of: sidebarItem),
              current != index else { return }
        splitViewController.removeSplitViewItem(sidebarItem)
        splitViewController.insertSplitViewItem(sidebarItem,
                                               at: min(max(index, 0), splitViewController.splitViewItems.count))
    }

    private func updateLayoutControl() {
        switch placement {
        case .leading: layoutControl.selectedSegment = 0
        case .hidden: layoutControl.selectedSegment = 1
        case .trailing: layoutControl.selectedSegment = 2
        }
    }

    private func wireCallbacks() {
        sidebar.onOpenBookmark = { [weak self] bookmarkID in
            guard let self else { return }
            self.content.showBookmark(id: bookmarkID, explicit: true)
        }
        sidebar.onOpenSession = { [weak self] sessionID in
            guard let self else { return }
            self.content.showSession(id: sessionID)
        }
        sidebar.onCreateBookmark = { [weak self] in
            self?.createBookmark()
        }
        sidebar.onCreateGroup = { [weak self] in
            self?.createGroup()
        }
        sidebar.onCreateSession = { [weak self] in
            self?.createSession()
        }

        content.onSessionStructureChanged = { [weak self] in
            self?.sidebar.reloadStatuses()
        }

        environment.runtime.onChange = { [weak self] in
            self?.handleContentChange()
        }
        environment.staticManager.onChange = { [weak self] in
            self?.handleContentChange()
        }
        environment.memoryMonitor.onChange = { [weak self] in
            self?.handleContentChange()
        }
        environment.runtime.onCredentialCaptured = { [weak self] candidate in
            self?.presentSaveCredential(candidate)
        }
        sidebar.onContentInvalidated = { [weak self] in
            // 详情/聚合可能正显示刚被删除的对象，refreshAll 会据数据是否存在回退到空态。
            self?.content.refreshAll()
        }
        environment.siteInfo.onChange = { [weak self] in
            guard let self else { return }
            // 每个收藏抓完站点信息都会回调一次；逐次 reloadAll 会清空图标缓存并全量重建，
            // n 个收藏就变成 n 次全量磁盘读取。合并到一次（300ms）即可。
            self.siteInfoRefreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.sidebar.reloadAll()
                self.content.refreshStatusOnly()
            }
            self.siteInfoRefreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func handleContentChange() {
        guard !isHandlingChange else { return }
        isHandlingChange = true
        defer { isHandlingChange = false }
        content.refreshStatusOnly()
        content.updateMemoryBanner()
        sidebar.reloadStatuses()
        updateStatusBar()
    }

    // MARK: - Startup policy

    func applyStartupPolicy() {
        let settings = environment.store.settings
        switch settings.startupPolicy {
        case .doNotRestore:
            environment.autoLoadEnabled = false
            if let session = environment.store.selectedSession {
                sidebar.selectSession(id: session.id)
                content.showSession(id: session.id)
            } else {
                content.showEmpty()
            }
        case .resumeLast:
            environment.autoLoadEnabled = true
            if let session = environment.store.selectedSession {
                sidebar.selectSession(id: session.id)
                content.showSession(id: session.id)
            } else {
                content.showEmpty()
            }
        case .openBookmark:
            environment.autoLoadEnabled = true
            if let bookmarkID = settings.startupBookmarkID,
               environment.store.bookmark(id: bookmarkID) != nil {
                sidebar.selectBookmark(id: bookmarkID)
                content.showBookmark(id: bookmarkID, explicit: true, allowStaticCapture: false)
            } else if let session = environment.store.selectedSession {
                content.showSession(id: session.id)
            }
        }
        sidebar.reloadAll()
        // 窗口刚显示时遮挡状态尚未稳定，异步再刷新一次可见性。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.content.refreshAll()
            self.sidebar.reloadStatuses()
        }
    }

    // MARK: - Actions

    /// 菜单/快捷键的开关：在“仅内容”和上次的左右位置之间切换。
    func toggleSidebar() {
        let target: SidebarPlacement = placement == .hidden ? preferredPlacement : .hidden
        apply(placement: target)
        updateLayoutControl()
    }

    func createBookmark() {
        let groupID = sidebar.currentSelectedGroupID
        sidebar.presentEditor(bookmark: nil, defaultGroupID: groupID)
    }

    func createGroup() {
        let alert = NSAlert()
        alert.messageText = "新建分组"
        alert.informativeText = "分组为单层结构，收藏可拖入其中。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "分组名称"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try environment.store.createGroup(name: name)
            sidebar.reloadAll()
        } catch {
            presentOperationError(error)
        }
    }

    func createSession() {
        environment.autoLoadEnabled = true
        let session = environment.store.createSession()
        sidebar.reloadAll()
        sidebar.selectSession(id: session.id)
        content.showSession(id: session.id)
    }

    func reloadCurrent() {
        if let bookmarkID = content.currentBookmarkID,
           let bookmark = environment.store.bookmark(id: bookmarkID) {
            // 刷新页面时顺手补齐缺失图标（老收藏升级后也能自动补上）。
            environment.siteInfo.refreshIconIfMissing(bookmarkID: bookmarkID)
            if bookmark.kind == .staticPage {
                environment.staticManager.forceRefresh(bookmarkID: bookmarkID)
                content.refreshAll()
            } else {
                environment.runtime.reload(bookmarkID: bookmarkID)
                content.refreshAll()
            }
            sidebar.reloadStatuses()
            return
        }

        if let session = content.currentSession {
            for pane in session.allPanes {
                guard let bookmarkID = pane.bookmarkID,
                      let bookmark = environment.store.bookmark(id: bookmarkID) else { continue }
                environment.siteInfo.refreshIconIfMissing(bookmarkID: bookmarkID)
                guard bookmark.kind == .dynamic,
                      environment.runtime.hasInstance(bookmarkID) else { continue }
                environment.runtime.reload(bookmarkID: bookmarkID)
            }
            content.refreshAll()
            sidebar.reloadStatuses()
        }
    }

    func goBack() {
        guard let bookmarkID = content.currentBookmarkID else { return }
        environment.runtime.goBack(bookmarkID: bookmarkID)
        content.refreshStatusOnly()
    }

    func goForward() {
        guard let bookmarkID = content.currentBookmarkID else { return }
        environment.runtime.goForward(bookmarkID: bookmarkID)
        content.refreshStatusOnly()
    }

    func toggleDeveloperTools() {
        guard let bookmarkID = content.currentBookmarkID else { return }
        environment.runtime.toggleWebInspector(bookmarkID: bookmarkID)
    }

    /// 保存登录信息必须由用户确认；已有 sheet 时放弃本次提示（不静默写入）。
    private func presentSaveCredential(_ candidate: BrowserRuntime.CredentialCandidate) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "保存此站点的登录信息？"
        alert.informativeText = """
        站点：\(candidate.host)
        用户名：\(candidate.username)

        密码保存在系统钥匙串中，可在“设置 → 已保存密码”里删除。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "暂不")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.environment.credentials.save(host: candidate.host,
                                                     username: candidate.username,
                                                     password: candidate.password)
            } catch {
                self.presentOperationError(error)
            }
        }
    }

    private func presentOperationError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // 窗口变宽时放开完整栏的最大宽度（30%），变窄时收紧。
        layoutSidebarThickness()
    }

    func windowWillClose(_ notification: Notification) {
        environment.memoryMonitor.stop()
    }
}

/// 窗口根容器：竖向承载 split view 与底部状态栏。
@MainActor
private final class MainWindowRootController: NSViewController {
    override func loadView() {
        let view = NSView()
        view.wantsLayer = false
        self.view = view
    }
}
