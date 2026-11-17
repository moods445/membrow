import AppKit
import MembrowCore

@MainActor
final class MainContentViewController: NSViewController {
    private enum Mode {
        case none
        case session(UUID)
        case detail(UUID)
    }

    let environment: AppEnvironment
    private let banner = MemoryBannerView()
    private let container = NSView()
    private let sessionView: SessionContentView
    private let detailView: BookmarkDetailView
    private let emptyView = MessageView()
    private var mode: Mode = .none
    private var bannerHeight: NSLayoutConstraint!
    private var isRefreshing = false

    var onSessionStructureChanged: (() -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.sessionView = SessionContentView(environment: environment)
        self.detailView = BookmarkDetailView(environment: environment)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        root.addSubview(banner)

        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)

        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bannerHeight,

            container.topAnchor.constraint(equalTo: banner.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.configure(symbol: "◫", title: "选择左侧聚合或收藏", detail: "收藏会在这里以浏览器视图打开。")

        sessionView.onStructureChanged = { [weak self] in
            self?.handleStructureChange()
        }

        banner.onUnpin = { [weak self] bookmarkID in
            guard let self else { return }
            self.environment.store.setBookmarkPinned(id: bookmarkID, pinned: false)
            self.refreshAll()
        }
        banner.onClosePage = { [weak self] bookmarkID in
            guard let self else { return }
            self.environment.runtime.closeWebPage(bookmarkID: bookmarkID)
            // 静态收藏常驻的是精简快照：回收快照即可（视图会回退到 Markdown）。
            if self.environment.store.bookmark(id: bookmarkID)?.kind == .staticPage {
                self.environment.snapshots.evict(bookmarkID: bookmarkID)
            }
            self.refreshAll()
        }
    }

    func showSession(id: UUID) {
        loadViewIfNeeded()
        guard let session = environment.store.session(id: id) else {
            showEmpty()
            return
        }
        mode = .session(id)
        sessionView.update(session: session)
        install(sessionView)
        updateWindowTitle()
        updateMemoryBanner()
    }

    /// 聚合标题并入窗口标题，内容区不再单独占一行。
    private func updateWindowTitle() {
        guard let window = view.window else { return }
        switch mode {
        case .session(let id):
            window.title = "Membrow — \(environment.store.session(id: id)?.name ?? "聚合")"
        case .detail, .none:
            window.title = "Membrow"
        }
    }

    func showBookmark(id: UUID, explicit: Bool, allowStaticCapture: Bool = true) {
        loadViewIfNeeded()
        if explicit {
            environment.autoLoadEnabled = true
        }
        guard environment.store.bookmark(id: id) != nil else {
            showEmpty()
            return
        }
        mode = .detail(id)
        detailView.show(bookmarkID: id, allowStaticCapture: allowStaticCapture)
        install(detailView)
        updateWindowTitle()
        updateMemoryBanner()
    }

    func showEmpty() {
        loadViewIfNeeded()
        mode = .none
        install(emptyView)
        updateWindowTitle()
        updateMemoryBanner()
    }

    func refreshAll() {
        guard isViewLoaded, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        switch mode {
        case .session(let id):
            if let session = environment.store.session(id: id) {
                sessionView.update(session: session)
            } else {
                showEmpty()
            }
        case .detail(let id):
            if environment.store.bookmark(id: id) != nil {
                detailView.refresh()
                // 窗口遮挡状态变化只会调到这里：详情视图没有 PaneLayoutView.update 的兜底，
                // 不主动同步就会拿着旧的可见性标记决定谁该被回收。
                detailView.refreshVisibility()
            } else {
                showEmpty()
            }
        case .none:
            break
        }
        updateMemoryBanner()
    }

    func refreshStatusOnly() {
        guard isViewLoaded else { return }
        if case .session = mode {
            sessionView.update(session: currentSession)
        } else if case .detail = mode {
            detailView.refresh()
        }
        updateWindowTitle()
    }

    func updateMemoryBanner() {
        guard isViewLoaded else { return }
        // 正在看的页面不弹提示：可见实例本来就不参与回收，提示只会让人去关他正用着的那一页。
        let items = environment.memoryMonitor.overageItems.filter { !$0.isVisible }
        banner.update(items: items)
        banner.isHidden = items.isEmpty
        bannerHeight.constant = items.isEmpty ? 0 : 46
    }

    var currentSession: Session? {
        if case .session(let id) = mode {
            return environment.store.session(id: id)
        }
        return nil
    }

    var currentBookmarkID: UUID? {
        if case .detail(let id) = mode {
            return id
        }
        return nil
    }

    private func install(_ content: NSView) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func handleStructureChange() {
        if let session = currentSession {
            sessionView.update(session: session)
        }
        onSessionStructureChanged?()
    }
}
