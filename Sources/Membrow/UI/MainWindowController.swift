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
    private let sidebar: SidebarViewController
    private let content: MainContentViewController
    private var sidebarItem: NSSplitViewItem!
    private let layoutControl = NSSegmentedControl()
    private var placement: SidebarPlacement = .leading
    private var preferredPlacement: SidebarPlacement = .leading
    private var isHandlingChange = false
    private var occlusionObserver: NSObjectProtocol?

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
    }

    private func buildSplitView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        // 宽度可自由拖动：上限交给内容区 minimumThickness 约束，避免把主体挤没。
        sidebarItem.maximumThickness = 10_000
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultHigh
        self.sidebarItem = sidebarItem

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 520

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.autosaveName = "MembrowSplitView"

        // 先按上次布局排好顺序，再挂到窗口：这样 split view 自动保存的宽度按同一顺序套用。
        restorePlacement()
        installLayoutControl()

        window?.contentViewController = splitViewController
        updateLayoutControl()
    }

    // MARK: - 侧栏布局

    private static let placementKey = "sidebarPlacement"
    private static let preferredPlacementKey = "sidebarPreferredPlacement"

    private func restorePlacement() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.placementKey).flatMap(SidebarPlacement.init(rawValue:)) ?? .leading
        let preferred = defaults.string(forKey: Self.preferredPlacementKey)
            .flatMap(SidebarPlacement.init(rawValue:)) ?? .leading
        preferredPlacement = preferred == .hidden ? .leading : preferred
        apply(placement: saved)
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
        placement = target
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
        environment.siteInfo.onChange = { [weak self] in
            self?.sidebar.reloadAll()
        }
    }

    private func handleContentChange() {
        guard !isHandlingChange else { return }
        isHandlingChange = true
        defer { isHandlingChange = false }
        content.refreshStatusOnly()
        content.updateMemoryBanner()
        sidebar.reloadStatuses()
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
                      let bookmark = environment.store.bookmark(id: bookmarkID),
                      bookmark.kind == .dynamic,
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

    func windowWillClose(_ notification: Notification) {
        environment.memoryMonitor.stop()
    }
}
