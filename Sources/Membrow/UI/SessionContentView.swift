import AppKit
import MembrowCore

@MainActor
final class SessionContentView: NSView {
    private weak var environment: AppEnvironment?
    private(set) var sessionID: UUID?

    private let splitControl = NSSegmentedControl()
    private let restoreButton = NSButton()
    private let openAllButton = NSButton()
    private let paneLayout: PaneLayoutView
    private let emptyView = MessageView()

    var onStructureChanged: (() -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.paneLayout = PaneLayoutView(environment: environment)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        registerForDraggedTypes([MembrowPasteboard.bookmark])

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(header)

        splitControl.translatesAutoresizingMaskIntoConstraints = false
        splitControl.segmentCount = 2
        splitControl.trackingMode = .momentary
        splitControl.segmentStyle = .capsule
        splitControl.controlSize = .small
        splitControl.target = self
        splitControl.action = #selector(splitControlChanged)
        let splitSymbols = ["rectangle.split.1x2", "rectangle.split.2x1"]
        let splitTitles = ["水平分割（上下）", "竖直分割（左右）"]
        for index in 0..<2 {
            if let image = NSImage(systemSymbolName: splitSymbols[index],
                                   accessibilityDescription: splitTitles[index]) {
                splitControl.setImage(image, forSegment: index)
            }
            splitControl.setToolTip(splitTitles[index], forSegment: index)
            splitControl.setWidth(34, forSegment: index)
        }
        header.addSubview(splitControl)

        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.bezelStyle = .inline
        restoreButton.isBordered = false
        restoreButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left",
                                      accessibilityDescription: "还原放大")
        restoreButton.toolTip = "还原放大"
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        header.addSubview(restoreButton)

        openAllButton.translatesAutoresizingMaskIntoConstraints = false
        openAllButton.bezelStyle = .inline
        openAllButton.isBordered = false
        openAllButton.image = NSImage(systemSymbolName: "play.rectangle",
                                      accessibilityDescription: "打开全部网页")
        openAllButton.toolTip = "打开全部网页（复用已运行的实例）"
        openAllButton.target = self
        openAllButton.action = #selector(openAllTapped)
        header.addSubview(openAllButton)

        paneLayout.translatesAutoresizingMaskIntoConstraints = false
        paneLayout.onStructureChanged = { [weak self] in
            self?.onStructureChanged?()
        }
        paneLayout.onEmptyDrop = { [weak self] bookmarkID in
            self?.dropIntoEmptySession(bookmarkID)
        }
        addSubview(paneLayout)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            splitControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            splitControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            restoreButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            restoreButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            openAllButton.trailingAnchor.constraint(equalTo: restoreButton.leadingAnchor, constant: -8),
            openAllButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            paneLayout.topAnchor.constraint(equalTo: header.bottomAnchor),
            paneLayout.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneLayout.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneLayout.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyView.leadingAnchor.constraint(equalTo: paneLayout.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: paneLayout.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: paneLayout.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: paneLayout.bottomAnchor),
        ])
    }

    func update(session: Session?) {
        sessionID = session?.id
        restoreButton.isHidden = session?.zoomedPaneID == nil
        let hasDynamicPane = session?.allPanes.contains { pane in
            guard let id = pane.bookmarkID else { return false }
            return environment?.store.bookmark(id: id)?.kind == .dynamic
        } ?? false
        openAllButton.isHidden = !hasDynamicPane

        let isEmpty = session?.root == nil
        emptyView.isHidden = !isEmpty
        paneLayout.update(session: session)

        if isEmpty {
            emptyView.configure(symbol: "◫",
                                title: "空聚合",
                                detail: "拖入收藏，或点击右上角的分割按钮创建 Pane。",
                                actionTitle: "水平分割") { [weak self] in
                self?.split(.horizontal)
            }
        }
    }

    private func split(_ axis: SplitAxis) {
        guard let environment, let sessionID, let session = environment.store.session(id: sessionID) else { return }
        let target = session.root == nil ? nil : session.focusedPaneID
        environment.store.splitPane(sessionID: sessionID, paneID: target, axis: axis)
        onStructureChanged?()
    }

    private func dropIntoEmptySession(_ bookmarkID: UUID) {
        guard let environment, let sessionID else { return }
        environment.runtime.clearTermination(for: bookmarkID)
        environment.store.splitPane(sessionID: sessionID, paneID: nil, axis: .vertical)
        guard let session = environment.store.session(id: sessionID),
              let pane = session.allPanes.last else { return }
        environment.store.assignBookmark(bookmarkID, sessionID: sessionID, paneID: pane.id)
        environment.store.focusPane(sessionID: sessionID, paneID: pane.id)
        onStructureChanged?()
    }

    @objc private func splitControlChanged() {
        split(splitControl.selectedSegment == 1 ? .vertical : .horizontal)
    }

    @objc private func openAllTapped() {
        paneLayout.loadAllPages()
    }

    @objc private func restoreTapped() {
        guard let environment, let sessionID, let session = environment.store.session(id: sessionID),
              let zoomed = session.zoomedPaneID else { return }
        environment.store.zoomPane(sessionID: sessionID, paneID: zoomed, zoomed: false)
        onStructureChanged?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard environment?.store.session(id: sessionID)?.root == nil,
              sender.draggingPasteboard.string(forType: MembrowPasteboard.bookmark) != nil else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard environment?.store.session(id: sessionID)?.root == nil,
              let raw = sender.draggingPasteboard.string(forType: MembrowPasteboard.bookmark),
              let id = UUID(uuidString: raw) else {
            return false
        }
        dropIntoEmptySession(id)
        return true
    }
}
