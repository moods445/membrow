import AppKit
import MembrowCore

@MainActor
final class SidebarItem: NSObject {
    enum Content {
        case group(BookmarkGroup)
        case bookmark(Bookmark)
    }

    let content: Content

    init(group: BookmarkGroup) {
        content = .group(group)
    }

    init(bookmark: Bookmark) {
        content = .bookmark(bookmark)
    }

    var id: UUID {
        switch content {
        case .group(let group): return group.id
        case .bookmark(let bookmark): return bookmark.id
        }
    }

    var group: BookmarkGroup? {
        if case .group(let group) = content { return group }
        return nil
    }

    var bookmark: Bookmark? {
        if case .bookmark(let bookmark) = content { return bookmark }
        return nil
    }
}

@MainActor
final class SidebarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let iconView = NSImageView()
    private let titleLabel = makeLabel("", font: NSFont.systemFont(ofSize: 12))
    private let statusLabel = makeLabel("", font: NSFont.systemFont(ofSize: 10), color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, detail: String?, bold: Bool, icon: NSImage? = nil) {
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        statusLabel.stringValue = detail ?? ""
        statusLabel.isHidden = (detail ?? "").isEmpty
        iconView.image = icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.contentTintColor = icon == nil ? .tertiaryLabelColor : nil
    }
}

@MainActor
final class SidebarViewController: NSViewController {
    private weak var environment: AppEnvironment?

    var onOpenBookmark: ((UUID) -> Void)?
    var onOpenSession: ((UUID) -> Void)?
    var onCreateBookmark: (() -> Void)?
    var onCreateGroup: (() -> Void)?
    var onCreateSession: (() -> Void)?

    private let sessionsTable = NSTableView()
    private let outlineView = NSOutlineView()
    private let sessionsScroll = NSScrollView()
    private let outlineScroll = NSScrollView()
    private let sessionMenu = NSMenu()
    private let bookmarkMenu = NSMenu()

    private var rootItems: [SidebarItem] = []
    private var childrenByGroup: [UUID: [SidebarItem]] = [:]
    private var itemByID: [UUID: SidebarItem] = [:]
    private var suppressSelection = false
    private var selectedBookmarkID: UUID?
    private(set) var selectedGroupID: UUID?
    private var editorController: BookmarkEditorController?
    private var iconCache: [UUID: NSImage] = [:]
    private var missingIconIDs: Set<UUID> = []

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        let sessionsHeader = makeSectionHeader(title: "聚合",
                                               addAction: #selector(addSessionTapped),
                                               addToolTip: "新建聚合")
        let bookmarksHeader = makeSectionHeader(title: "收藏",
                                                addAction: #selector(addBookmarkTapped),
                                                addToolTip: "新建收藏",
                                                extraAction: #selector(addGroupTapped),
                                                extraTitle: "▱",
                                                extraToolTip: "新建分组")
        sessionsHeader.translatesAutoresizingMaskIntoConstraints = false
        bookmarksHeader.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sessionsHeader)
        root.addSubview(bookmarksHeader)

        sessionsTable.headerView = nil
        sessionsTable.rowHeight = 24
        sessionsTable.intercellSpacing = NSSize(width: 0, height: 0)
        sessionsTable.selectionHighlightStyle = .regular
        sessionsTable.allowsEmptySelection = false
        sessionsTable.dataSource = self
        sessionsTable.delegate = self
        sessionsTable.menu = sessionMenu
        sessionMenu.delegate = self
        // 选中变化不覆盖“再次点击已选中行”的场景，需要单独的点击 action。
        sessionsTable.target = self
        sessionsTable.action = #selector(sessionRowClicked)

        let sessionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        sessionColumn.width = 220
        sessionsTable.addTableColumn(sessionColumn)

        sessionsScroll.documentView = sessionsTable
        sessionsScroll.hasVerticalScroller = true
        sessionsScroll.autohidesScrollers = true
        sessionsScroll.drawsBackground = false
        sessionsScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sessionsScroll)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.width = 220
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = 36
        outlineView.indentationPerLevel = 14
        outlineView.autosaveExpandedItems = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = bookmarkMenu
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked)
        bookmarkMenu.delegate = self
        outlineView.registerForDraggedTypes([MembrowPasteboard.bookmark, MembrowPasteboard.group])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outlineScroll)

        NSLayoutConstraint.activate([
            sessionsHeader.topAnchor.constraint(equalTo: root.topAnchor),
            sessionsHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sessionsHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sessionsHeader.heightAnchor.constraint(equalToConstant: 26),

            sessionsScroll.topAnchor.constraint(equalTo: sessionsHeader.bottomAnchor),
            sessionsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sessionsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sessionsScroll.heightAnchor.constraint(equalToConstant: 150),

            divider.topAnchor.constraint(equalTo: sessionsScroll.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            divider.heightAnchor.constraint(equalToConstant: 1),

            bookmarksHeader.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            bookmarksHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bookmarksHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bookmarksHeader.heightAnchor.constraint(equalToConstant: 26),

            outlineScroll.topAnchor.constraint(equalTo: bookmarksHeader.bottomAnchor),
            outlineScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func makeSectionHeader(title: String,
                                   addAction: Selector,
                                   addToolTip: String,
                                   extraAction: Selector? = nil,
                                   extraTitle: String = "",
                                   extraToolTip: String = "") -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let label = makeLabel(title, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let addButton = makeHeaderButton(title: "＋", toolTip: addToolTip, target: self, action: addAction)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addButton)

        var extraButton: NSButton?
        if let extraAction {
            let button = makeHeaderButton(title: extraTitle, toolTip: extraToolTip, target: self, action: extraAction)
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
            extraButton = button
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        if let extraButton {
            NSLayoutConstraint.activate([
                extraButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -6),
                extraButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }
        return container
    }

    // MARK: - Data

    func reloadAll() {
        iconCache.removeAll()
        missingIconIDs.removeAll()
        rebuildItems()
        suppressSelection = true
        sessionsTable.reloadData()
        outlineView.reloadData()
        restoreExpansion()
        restoreSelection()
        suppressSelection = false
    }

    func reloadStatuses() {
        guard isViewLoaded else { return }
        rebuildItems()
        suppressSelection = true
        sessionsTable.reloadData()
        sessionsTable.selectRowIndexes(sessionRowIndexes(), byExtendingSelection: false)
        if outlineView.numberOfRows > 0 {
            outlineView.reloadData(forRowIndexes: IndexSet(0..<outlineView.numberOfRows),
                                   columnIndexes: IndexSet(integer: 0))
        }
        suppressSelection = false
    }

    private func rebuildItems() {
        guard let environment else { return }
        rootItems = []
        childrenByGroup = [:]
        itemByID = [:]

        for entry in environment.store.library.rootOrder {
            if let group = environment.store.library.group(id: entry) {
                let groupItem = SidebarItem(group: group)
                rootItems.append(groupItem)
                itemByID[group.id] = groupItem
                var children: [SidebarItem] = []
                for bookmarkID in environment.store.library.groupOrders[group.id] ?? [] {
                    if let bookmark = environment.store.library.bookmark(id: bookmarkID) {
                        let item = SidebarItem(bookmark: bookmark)
                        children.append(item)
                        itemByID[bookmark.id] = item
                    }
                }
                childrenByGroup[group.id] = children
            } else if let bookmark = environment.store.library.bookmark(id: entry) {
                let item = SidebarItem(bookmark: bookmark)
                rootItems.append(item)
                itemByID[bookmark.id] = item
            }
        }
    }

    private func restoreExpansion() {
        guard let environment else { return }
        for group in environment.store.library.groups where group.isExpanded {
            if let item = itemByID[group.id] {
                outlineView.expandItem(item)
            }
        }
    }

    private func restoreSelection() {
        guard let environment else { return }
        if let bookmarkID = selectedBookmarkID,
           let item = itemByID[bookmarkID],
           outlineView.row(forItem: item) >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: item)), byExtendingSelection: false)
        }
        let indexes = sessionRowIndexes()
        if !indexes.isEmpty {
            sessionsTable.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        _ = environment
    }

    private func sessionRowIndexes() -> IndexSet {
        guard let environment,
              let selected = environment.store.settings.lastSessionID,
              let index = environment.store.sessions.firstIndex(where: { $0.id == selected }) else {
            return IndexSet()
        }
        return IndexSet(integer: index)
    }

    func selectSession(id: UUID) {
        guard let environment,
              let index = environment.store.sessions.firstIndex(where: { $0.id == id }) else { return }
        suppressSelection = true
        sessionsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        suppressSelection = false
    }

    func selectBookmark(id: UUID) {
        selectedBookmarkID = id
        guard let item = itemByID[id], outlineView.row(forItem: item) >= 0 else { return }
        suppressSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: item)), byExtendingSelection: false)
        suppressSelection = false
    }

    func presentEditor(bookmark: Bookmark?, defaultGroupID: UUID?) {
        guard let environment, let window = view.window else { return }
        let editor = BookmarkEditorController(environment: environment,
                                              bookmark: bookmark,
                                              defaultGroupID: defaultGroupID)
        editor.onSaved = { [weak self] savedID in
            self?.environment?.siteInfo.refresh(bookmarkID: savedID)
            self?.reloadAll()
            self?.onOpenBookmark?(savedID)
        }
        editorController = editor
        window.beginSheet(editor.window!) { [weak self] _ in
            self?.editorController = nil
        }
    }

    var currentSelectedGroupID: UUID? {
        selectedGroupID
    }

    private func siteIcon(for bookmarkID: UUID) -> NSImage? {
        if let cached = iconCache[bookmarkID] { return cached }
        guard !missingIconIDs.contains(bookmarkID) else { return nil }
        guard let image = SiteIconStore.image(for: bookmarkID, in: environment?.dataDirectory) else {
            missingIconIDs.insert(bookmarkID)
            return nil
        }
        iconCache[bookmarkID] = image
        return image
    }

    // MARK: - Actions

    @objc private func addSessionTapped() {
        onCreateSession?()
    }

    @objc private func addBookmarkTapped() {
        onCreateBookmark?()
    }

    @objc private func addGroupTapped() {
        onCreateGroup?()
    }

    @objc private func openBookmarkAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let bookmark = item.bookmark else { return }
        onOpenBookmark?(bookmark.id)
    }

    @objc private func editBookmarkAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let bookmark = item.bookmark else { return }
        presentEditor(bookmark: bookmark, defaultGroupID: bookmark.groupID)
    }

    @objc private func renameBookmarkAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem,
              let bookmark = item.bookmark,
              let environment else { return }
        prompt(title: "重命名收藏",
               message: "输入新的收藏名称。",
               defaultValue: bookmark.name) { value in
            try? environment.store.renameBookmark(id: bookmark.id, name: value)
            self.reloadAll()
        }
    }

    @objc private func deleteBookmarkAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem,
              let bookmark = item.bookmark,
              let environment else { return }
        confirm(title: "删除收藏",
                message: "删除“\(bookmark.trimmedName)”？该收藏的会话绑定与静态缓存也会被清理。") {
            environment.runtime.discardInstance(bookmarkID: bookmark.id)
            environment.staticManager.clearPhase(for: bookmark.id)
            environment.store.deleteBookmark(id: bookmark.id)
            if self.selectedBookmarkID == bookmark.id {
                self.selectedBookmarkID = nil
            }
            self.reloadAll()
        }
    }

    @objc private func copyURLAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let bookmark = item.bookmark else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bookmark.entryURL, forType: .string)
    }

    @objc private func togglePinAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem,
              let bookmark = item.bookmark,
              let environment else { return }
        environment.store.setBookmarkPinned(id: bookmark.id, pinned: !bookmark.isPinned)
        reloadAll()
    }

    @objc private func closeWebPageAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem,
              let bookmark = item.bookmark,
              let environment else { return }
        environment.runtime.closeWebPage(bookmarkID: bookmark.id)
    }

    @objc private func openEntryAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem,
              let bookmark = item.bookmark,
              let environment else { return }
        if environment.runtime.hasInstance(bookmark.id) {
            environment.runtime.openFromEntry(bookmarkID: bookmark.id)
        } else {
            // 实例已关闭/回收：先让收藏出现在可见视图并创建实例，再按入口地址加载。
            onOpenBookmark?(bookmark.id)
            environment.runtime.openFromEntry(bookmarkID: bookmark.id)
        }
    }

    @objc private func renameGroupAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem,
              let group = item.group,
              let environment else { return }
        prompt(title: "重命名分组",
               message: "输入新的分组名称。",
               defaultValue: group.name) { value in
            try? environment.store.renameGroup(id: group.id, name: value)
            self.reloadAll()
        }
    }

    @objc private func deleteGroupAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem,
              let group = item.group,
              let environment else { return }
        confirm(title: "删除分组",
                message: "删除分组“\(group.name)”？组内收藏会移动到根层。") {
            environment.store.deleteGroup(id: group.id)
            if self.selectedGroupID == group.id {
                self.selectedGroupID = nil
            }
            self.reloadAll()
        }
    }

    @objc private func newBookmarkInGroupAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let group = item.group else { return }
        selectedGroupID = group.id
        onCreateBookmark?()
    }

    @objc private func renameSessionAction(_ sender: NSMenuItem) {
        guard let environment, sessionsTable.clickedRow >= 0,
              sessionsTable.clickedRow < environment.store.sessions.count else { return }
        let session = environment.store.sessions[sessionsTable.clickedRow]
        prompt(title: "重命名聚合",
               message: "输入新的聚合名称。",
               defaultValue: session.name) { value in
            try? environment.store.renameSession(id: session.id, name: value)
            self.reloadAll()
        }
    }

    @objc private func deleteSessionAction(_ sender: NSMenuItem) {
        guard let environment, sessionsTable.clickedRow >= 0,
              sessionsTable.clickedRow < environment.store.sessions.count else { return }
        let session = environment.store.sessions[sessionsTable.clickedRow]
        confirm(title: "删除聚合",
                message: "删除聚合“\(session.name)”？其中的 Pane 布局会一并移除，绑定的网页转为不可见并由内存管控回收。") {
            environment.store.deleteSession(id: session.id)
            self.reloadAll()
        }
    }

    private func prompt(title: String,
                        message: String,
                        defaultValue: String,
                        completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        completion(value)
    }

    private func confirm(title: String, message: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        action()
    }
}

// MARK: - Sessions table

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView === sessionsTable else { return 0 }
        return environment?.store.sessions.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === sessionsTable,
              let environment,
              row >= 0, row < environment.store.sessions.count else { return nil }
        let session = environment.store.sessions[row]
        let cell = tableView.makeView(withIdentifier: SidebarCellView.identifier, owner: self) as? SidebarCellView
            ?? SidebarCellView()
        cell.configure(title: session.name,
                       detail: session.id == environment.store.settings.lastSessionID ? "当前" : nil,
                       bold: session.id == environment.store.settings.lastSessionID,
                       icon: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openSession(at: sessionsTable.selectedRow)
    }

    /// 点击已在选中状态的行时 `tableViewSelectionDidChange` 不会触发，靠 action 补齐。
    @objc private func sessionRowClicked() {
        openSession(at: sessionsTable.clickedRow)
    }

    private func openSession(at row: Int) {
        guard !suppressSelection,
              let environment,
              row >= 0, row < environment.store.sessions.count else { return }
        let session = environment.store.sessions[row]
        environment.store.selectSession(id: session.id)
        environment.autoLoadEnabled = true
        onOpenSession?(session.id)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sessionMenu else {
            rebuildBookmarkMenu(menu)
            return
        }
        menu.removeAllItems()
        guard let environment, sessionsTable.clickedRow >= 0,
              sessionsTable.clickedRow < environment.store.sessions.count else { return }
        let session = environment.store.sessions[sessionsTable.clickedRow]
        menu.addItem(withTitle: "打开“\(session.name)”", action: #selector(openSessionFromMenu(_:)), keyEquivalent: "")
        menu.items.last?.target = self
        menu.items.last?.representedObject = session.id.uuidString
        menu.addItem(.separator())
        let rename = NSMenuItem(title: "重命名…", action: #selector(renameSessionAction(_:)), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let delete = NSMenuItem(title: "删除…", action: #selector(deleteSessionAction(_:)), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
    }

    @objc private func openSessionFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let environment else { return }
        environment.store.selectSession(id: id)
        environment.autoLoadEnabled = true
        onOpenSession?(id)
        reloadAll()
    }

    private func rebuildBookmarkMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        let item = row >= 0 ? outlineView.item(atRow: row) as? SidebarItem : nil

        if let item, let bookmark = item.bookmark {
            let open = NSMenuItem(title: "打开", action: #selector(openBookmarkAction(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = item
            menu.addItem(open)

            let edit = NSMenuItem(title: "编辑…", action: #selector(editBookmarkAction(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = item
            menu.addItem(edit)

            let rename = NSMenuItem(title: "重命名…", action: #selector(renameBookmarkAction(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = item
            menu.addItem(rename)

            menu.addItem(.separator())

            let pin = NSMenuItem(title: bookmark.isPinned ? "取消固定" : "固定（不回收）",
                                 action: #selector(togglePinAction(_:)),
                                 keyEquivalent: "")
            pin.target = self
            pin.representedObject = item
            menu.addItem(pin)

            if bookmark.kind == .dynamic {
                if environment?.runtime.hasInstance(bookmark.id) == true {
                    let close = NSMenuItem(title: "关闭网页", action: #selector(closeWebPageAction(_:)), keyEquivalent: "")
                    close.target = self
                    close.representedObject = item
                    menu.addItem(close)
                }

                let entry = NSMenuItem(title: "从入口重新打开", action: #selector(openEntryAction(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item
                menu.addItem(entry)
            }

            menu.addItem(.separator())

            let copy = NSMenuItem(title: "复制链接", action: #selector(copyURLAction(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = item
            menu.addItem(copy)

            let delete = NSMenuItem(title: "删除…", action: #selector(deleteBookmarkAction(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = item
            menu.addItem(delete)
            return
        }

        if let item, item.group != nil {
            let rename = NSMenuItem(title: "重命名分组…", action: #selector(renameGroupAction(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = item
            menu.addItem(rename)

            let newBookmark = NSMenuItem(title: "在此分组新建收藏…",
                                         action: #selector(newBookmarkInGroupAction(_:)),
                                         keyEquivalent: "")
            newBookmark.target = self
            newBookmark.representedObject = item
            menu.addItem(newBookmark)

            menu.addItem(.separator())

            let delete = NSMenuItem(title: "删除分组…", action: #selector(deleteGroupAction(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = item
            menu.addItem(delete)
            return
        }

        let newBookmark = NSMenuItem(title: "新建收藏…", action: #selector(addBookmarkTapped), keyEquivalent: "")
        newBookmark.target = self
        menu.addItem(newBookmark)
        let newGroup = NSMenuItem(title: "新建分组…", action: #selector(addGroupTapped), keyEquivalent: "")
        newGroup.target = self
        menu.addItem(newGroup)
    }
}

// MARK: - Outline

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SidebarItem else { return rootItems.count }
        if let group = item.group {
            return childrenByGroup[group.id]?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let list: [SidebarItem]
        if let item = item as? SidebarItem, let group = item.group {
            list = childrenByGroup[group.id] ?? []
        } else {
            list = rootItems
        }
        // 数据源与视图缓存不同步时钳制索引，避免越界崩溃。
        guard !list.isEmpty else { return NSNull() }
        return list[min(max(index, 0), list.count - 1)]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.group != nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.group != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: SidebarCellView.identifier, owner: self) as? SidebarCellView
            ?? SidebarCellView()

        switch item.content {
        case .group(let group):
            let count = childrenByGroup[group.id]?.count ?? 0
            cell.configure(title: group.name,
                           detail: "\(count) 个收藏",
                           bold: true,
                           icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil))
        case .bookmark(let bookmark):
            let status = environment?.status(for: bookmark)
            let detail = status.map { "\($0.display) · \(bookmark.kind.displayName)" }
            cell.configure(title: bookmark.displayTitle,
                           detail: detail,
                           bold: false,
                           icon: siteIcon(for: bookmark.id))
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        activate(row: outlineView.selectedRow, fromClick: false)
    }

    /// 再次点击已选中的收藏时同样要打开；分组行点击则展开/收起。
    @objc private func outlineRowClicked() {
        activate(row: outlineView.clickedRow, fromClick: true)
    }

    private func activate(row: Int, fromClick: Bool) {
        guard !suppressSelection, row >= 0,
              let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        switch item.content {
        case .bookmark(let bookmark):
            selectedBookmarkID = bookmark.id
            selectedGroupID = bookmark.groupID
            environment?.autoLoadEnabled = true
            onOpenBookmark?(bookmark.id)
        case .group(let group):
            selectedGroupID = group.id
            guard fromClick else { return }
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem,
              let group = item.group,
              let environment else { return }
        environment.store.setGroupExpanded(id: group.id, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem,
              let group = item.group,
              let environment else { return }
        environment.store.setGroupExpanded(id: group.id, expanded: false)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem else { return nil }
        let pasteboardItem = NSPasteboardItem()
        switch item.content {
        case .bookmark(let bookmark):
            pasteboardItem.setString(bookmark.id.uuidString, forType: MembrowPasteboard.bookmark)
        case .group(let group):
            pasteboardItem.setString(group.id.uuidString, forType: MembrowPasteboard.group)
        }
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let environment else { return [] }
        let pasteboard = info.draggingPasteboard

        guard let rawBookmark = pasteboard.string(forType: MembrowPasteboard.bookmark) else {
            // 分组拖动只允许根层排序。
            guard pasteboard.string(forType: MembrowPasteboard.group) != nil, item == nil else {
                return []
            }
            outlineView.setDropItem(nil, dropChildIndex: index == NSOutlineViewDropOnItemIndex
                                    ? environment.store.library.rootOrder.count : index)
            return .move
        }

        _ = rawBookmark
        guard let sidebarItem = item as? SidebarItem else {
            outlineView.setDropItem(nil, dropChildIndex: index == NSOutlineViewDropOnItemIndex
                                    ? environment.store.library.rootOrder.count : index)
            return .move
        }

        switch sidebarItem.content {
        case .group:
            outlineView.setDropItem(sidebarItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        case .bookmark(let bookmark):
            let list = bookmark.groupID.flatMap { environment.store.library.groupOrders[$0] }
                ?? environment.store.library.rootOrder
            let position = list.firstIndex(of: bookmark.id) ?? 0
            let childIndex = index == NSOutlineViewDropOnItemIndex
                ? position + 1
                : max(0, min(index, list.count))
            let parent = bookmark.groupID.flatMap { itemByID[$0] }
            outlineView.setDropItem(parent, dropChildIndex: childIndex)
            return .move
        }
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let environment else { return false }
        let pasteboard = info.draggingPasteboard

        if let rawGroup = pasteboard.string(forType: MembrowPasteboard.group),
           let groupID = UUID(uuidString: rawGroup) {
            let target = index == NSOutlineViewDropOnItemIndex
                ? environment.store.library.rootOrder.count
                : max(0, min(index, environment.store.library.rootOrder.count))
            environment.store.moveRootItem(id: groupID, to: target)
            reloadAll()
            return true
        }

        guard let rawBookmark = pasteboard.string(forType: MembrowPasteboard.bookmark),
              let bookmarkID = UUID(uuidString: rawBookmark) else {
            return false
        }

        let groupID: UUID?
        if let sidebarItem = item as? SidebarItem, let group = sidebarItem.group {
            groupID = group.id
        } else {
            groupID = nil
        }
        let count: Int
        if let groupID {
            count = environment.store.library.groupOrders[groupID]?.count ?? 0
        } else {
            count = environment.store.library.rootOrder.count
        }
        let target = index == NSOutlineViewDropOnItemIndex ? count : max(0, min(index, count))
        environment.store.moveBookmark(id: bookmarkID, toGroup: groupID, at: target)
        reloadAll()
        return true
    }
}
