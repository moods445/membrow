import AppKit
import MembrowCore

@MainActor
final class BookmarkEditorController: NSWindowController {
    private let environment: AppEnvironment
    private let existing: Bookmark?
    private var defaultGroupID: UUID?
    private var groupIDs: [UUID?] = []

    var onSaved: ((UUID) -> Void)?

    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let kindPopup = NSPopUpButton()
    private let groupPopup = NSPopUpButton()
    private let proxyPopup = NSPopUpButton()
    private let proxyHostField = NSTextField()
    private let proxyPortField = NSTextField()
    private let blockingCheckbox = NSButton(checkboxWithTitle: "启用内容拦截", target: nil, action: nil)
    private let pageAppearancePopup = NSPopUpButton()
    private let capturePopup = NSPopUpButton()
    private let ttlPopup = NSPopUpButton()
    private let ttlMinutesField = NSTextField()
    private let extractionPopup = NSPopUpButton()
    private let selectorField = NSTextField()
    private let waitSelectorField = NSTextField()
    private let displayPopup = NSPopUpButton()
    private let errorLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11), color: .systemRed)
    private let staticNote = makeLabel("", font: NSFont.systemFont(ofSize: 10), color: .secondaryLabelColor)
    private let displayNote = makeLabel("", font: NSFont.systemFont(ofSize: 10), color: .secondaryLabelColor)

    init(environment: AppEnvironment, bookmark: Bookmark?, defaultGroupID: UUID?) {
        self.environment = environment
        self.existing = bookmark
        self.defaultGroupID = defaultGroupID
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 645),
                            styleMask: [.titled],
                            backing: .buffered,
                            defer: false)
        panel.title = bookmark == nil ? "新建收藏" : "编辑收藏"
        panel.isReleasedWhenClosed = false
        // NSPanel 默认 becomesKeyOnlyIfNeeded，作为 sheet 时显式关闭，避免输入焦点落空。
        panel.becomesKeyOnlyIfNeeded = false
        super.init(window: panel)
        buildUI()
        populate()
        updateEnabledState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let panel = window else { return }
        let root = NSView(frame: panel.contentLayoutRect)
        root.wantsLayer = true

        nameField.placeholderString = "例如：Hacker News"
        urlField.placeholderString = "https://example.com"
        proxyHostField.placeholderString = "127.0.0.1"
        proxyPortField.placeholderString = "8080"
        ttlMinutesField.placeholderString = "60"
        selectorField.placeholderString = "article .content"
        waitSelectorField.placeholderString = "可留空"

        kindPopup.addItems(withTitles: BookmarkKind.allCases.map { $0.displayName })
        proxyPopup.addItems(withTitles: ["继承全局", "直连", "系统代理", "自定义 HTTP 代理"])
        capturePopup.addItems(withTitles: CaptureMode.allCases.map { $0.displayName })
        ttlPopup.addItems(withTitles: ["继承全局", "不使用缓存", "永不过期", "自定义分钟"])
        extractionPopup.addItems(withTitles: ExtractionKind.allCases.map { $0.displayName })
        displayPopup.addItems(withTitles: StaticDisplayMode.allCases.map { $0.displayName })
        pageAppearancePopup.addItems(withTitles: PageAppearance.allCases.map(\.displayName))

        for field in [nameField, urlField, proxyHostField, proxyPortField, ttlMinutesField, selectorField, waitSelectorField] {
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        // 每个字段只能有一条确定宽度：循环里给所有字段都设 380 会与下面的窄宽度约束互斥。
        for field in [nameField, urlField, selectorField, waitSelectorField] {
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        proxyHostField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        proxyPortField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        ttlMinutesField.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let proxyRow = NSStackView(views: [proxyPopup, proxyHostField, proxyPortField])
        proxyRow.orientation = .horizontal
        proxyRow.spacing = 6

        let captureRow = NSStackView(views: [capturePopup, staticNote])
        captureRow.orientation = .horizontal
        captureRow.spacing = 8

        let ttlRow = NSStackView(views: [ttlPopup, ttlMinutesField])
        ttlRow.orientation = .horizontal
        ttlRow.spacing = 6

        let extractionRow = NSStackView(views: [extractionPopup, selectorField])
        extractionRow.orientation = .horizontal
        extractionRow.spacing = 6

        let displayRow = NSStackView(views: [displayPopup, displayNote])
        displayRow.orientation = .horizontal
        displayRow.spacing = 8

        let blockingHint = makeLabel("切换只更新配置，已打开的网页刷新后生效",
                                     font: .systemFont(ofSize: 10),
                                     color: .secondaryLabelColor)
        let blockingRow = NSStackView(views: [blockingCheckbox, blockingHint])
        blockingRow.orientation = .vertical
        blockingRow.alignment = .leading
        blockingRow.spacing = 2

        let grid = NSGridView(views: [
            [makeLabel("名称", font: .systemFont(ofSize: 12)), nameField],
            [makeLabel("入口 URL", font: .systemFont(ofSize: 12)), urlField],
            [makeLabel("类型", font: .systemFont(ofSize: 12)), kindPopup],
            [makeLabel("分组", font: .systemFont(ofSize: 12)), groupPopup],
            [makeLabel("代理", font: .systemFont(ofSize: 12)), proxyRow],
            [makeLabel("内容拦截", font: .systemFont(ofSize: 12)), blockingRow],
            [makeLabel("页面外观", font: .systemFont(ofSize: 12)), pageAppearancePopup],
            [makeLabel("抓取方式", font: .systemFont(ofSize: 12)), captureRow],
            [makeLabel("缓存有效期", font: .systemFont(ofSize: 12)), ttlRow],
            [makeLabel("正文提取", font: .systemFont(ofSize: 12)), extractionRow],
            [makeLabel("显示方式", font: .systemFont(ofSize: 12)), displayRow],
            [makeLabel("等待选择器", font: .systemFont(ofSize: 12)), waitSelectorField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        root.addSubview(grid)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.maximumNumberOfLines = 2
        root.addSubview(errorLabel)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),

            errorLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            buttons.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        kindPopup.target = self
        kindPopup.action = #selector(updateEnabledState)
        proxyPopup.target = self
        proxyPopup.action = #selector(updateEnabledState)
        ttlPopup.target = self
        ttlPopup.action = #selector(updateEnabledState)
        extractionPopup.target = self
        extractionPopup.action = #selector(updateEnabledState)
        capturePopup.target = self
        capturePopup.action = #selector(updateEnabledState)

        panel.contentView = root
        // 打开即聚焦名称输入框，可直接输入或 ⌘V 粘贴。
        panel.initialFirstResponder = nameField
    }

    private func populate() {
        groupPopup.removeAllItems()
        groupIDs = [nil] + environment.store.library.groups.map { Optional($0.id) }
        groupPopup.addItem(withTitle: "未分组")
        for group in environment.store.library.groups {
            groupPopup.addItem(withTitle: group.name)
        }

        if let bookmark = existing {
            nameField.stringValue = bookmark.name
            urlField.stringValue = bookmark.entryURL
            kindPopup.selectItem(at: bookmark.kind == .dynamic ? 0 : 1)
            if let groupID = bookmark.groupID, let index = groupIDs.firstIndex(where: { $0 == groupID }) {
                groupPopup.selectItem(at: index)
            } else {
                groupPopup.selectItem(at: 0)
            }
            if let proxy = bookmark.proxy {
                switch proxy.mode {
                case .direct:
                    proxyPopup.selectItem(at: 1)
                case .system:
                    proxyPopup.selectItem(at: 2)
                case .custom:
                    proxyPopup.selectItem(at: 3)
                    proxyHostField.stringValue = proxy.host
                    proxyPortField.stringValue = proxy.port > 0 ? "\(proxy.port)" : ""
                }
            } else {
                proxyPopup.selectItem(at: 0)
            }
            blockingCheckbox.state = bookmark.blockingEnabled ? .on : .off
            if let index = PageAppearance.allCases.firstIndex(of: bookmark.effectivePageAppearance) {
                pageAppearancePopup.selectItem(at: index)
            }

            switch bookmark.staticConfig.captureMode {
            case .webView: capturePopup.selectItem(at: 0)
            case .http: capturePopup.selectItem(at: 1)
            }

            switch bookmark.staticConfig.ttl {
            case .inherit: ttlPopup.selectItem(at: 0)
            case .noCache: ttlPopup.selectItem(at: 1)
            case .neverExpires: ttlPopup.selectItem(at: 2)
            case .minutes(let value):
                ttlPopup.selectItem(at: 3)
                ttlMinutesField.stringValue = "\(value)"
            }

            if let index = ExtractionKind.allCases.firstIndex(of: bookmark.staticConfig.extraction.kind) {
                extractionPopup.selectItem(at: index)
            }
            if let index = StaticDisplayMode.allCases.firstIndex(of: bookmark.staticConfig.displayMode) {
                displayPopup.selectItem(at: index)
            }
            selectorField.stringValue = bookmark.staticConfig.extraction.cssSelector
            waitSelectorField.stringValue = bookmark.staticConfig.extraction.waitSelector
        } else {
            kindPopup.selectItem(at: 0)
            if let defaultGroupID, let index = groupIDs.firstIndex(where: { $0 == defaultGroupID }) {
                groupPopup.selectItem(at: index)
            } else {
                groupPopup.selectItem(at: 0)
            }
            proxyPopup.selectItem(at: 0)
            blockingCheckbox.state = .on
            pageAppearancePopup.selectItem(at: PageAppearance.allCases.firstIndex(of: .dark) ?? 0)
            capturePopup.selectItem(at: 0)
            ttlPopup.selectItem(at: 0)
            extractionPopup.selectItem(at: ExtractionKind.allCases.firstIndex(of: .fullPage) ?? 0)
            displayPopup.selectItem(at: StaticDisplayMode.allCases.firstIndex(of: .preferred) ?? 0)
        }
        updateEnabledState()
    }

    private var selectedDisplayMode: StaticDisplayMode {
        let index = displayPopup.indexOfSelectedItem
        guard index >= 0, index < StaticDisplayMode.allCases.count else { return .preferred }
        return StaticDisplayMode.allCases[index]
    }

    private var selectedExtractionKind: ExtractionKind {
        let index = extractionPopup.indexOfSelectedItem
        guard index >= 0, index < ExtractionKind.allCases.count else { return .fullPage }
        return ExtractionKind.allCases[index]
    }

    private var selectedPageAppearance: PageAppearance {
        let index = pageAppearancePopup.indexOfSelectedItem
        guard index >= 0, index < PageAppearance.allCases.count else { return .system }
        return PageAppearance.allCases[index]
    }

    @objc private func updateEnabledState() {
        // 这些弹出按钮用 addItems(withTitles:) 创建，item 的 tag 全为 0，
        // 因此必须按索引判断；此前用 selectedTag() 导致静态配置永远判定为“动态”。
        let isStatic = kindPopup.indexOfSelectedItem == 1
        capturePopup.isEnabled = isStatic
        ttlPopup.isEnabled = isStatic
        ttlMinutesField.isEnabled = isStatic && ttlPopup.indexOfSelectedItem == 3
        extractionPopup.isEnabled = isStatic
        displayPopup.isEnabled = isStatic
        displayNote.stringValue = selectedDisplayMode.note ?? ""
        selectorField.isEnabled = isStatic && selectedExtractionKind == .css
        waitSelectorField.isEnabled = isStatic
        staticNote.isHidden = !isStatic
        blockingCheckbox.isEnabled = !isStatic

        let isCustomProxy = proxyPopup.indexOfSelectedItem == 3
        proxyHostField.isEnabled = isCustomProxy
        proxyPortField.isEnabled = isCustomProxy

        switch capturePopup.indexOfSelectedItem {
        case 1:
            staticNote.stringValue = CaptureMode.http.limitationNote ?? ""
        default:
            staticNote.stringValue = ""
        }
    }

    @objc private func cancelTapped() {
        closeSheet()
    }

    @objc private func saveTapped() {
        errorLabel.stringValue = ""

        guard let url = BookmarkValidation.url(from: urlField.stringValue) else {
            errorLabel.stringValue = "请输入有效的 http 或 https 地址。"
            return
        }
        // 只填 URL 也能直接保存：名称留空时先用主机名占位，
        // 站点标题/图标由 SiteInfoService 抓取后自动替换左栏显示。
        let name = BookmarkValidation.resolvedName(nameField.stringValue, url: url)

        let proxy: ProxySettings?
        switch proxyPopup.indexOfSelectedItem {
        case 1:
            proxy = ProxySettings(mode: .direct)
        case 2:
            proxy = ProxySettings(mode: .system)
        case 3:
            let host = proxyHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, let port = Int(proxyPortField.stringValue), (1...65535).contains(port) else {
                errorLabel.stringValue = "请输入有效的代理主机和端口（1–65535）。"
                return
            }
            proxy = ProxySettings(mode: .custom, host: host, port: port)
        default:
            proxy = nil
        }
        if let proxy, let message = proxy.validationError {
            errorLabel.stringValue = message
            return
        }

        let isStatic = kindPopup.indexOfSelectedItem == 1
        // 静态专属配置：仅在编辑静态收藏时覆盖，动态收藏保留旧配置不生效（T036）。
        var staticConfig = existing?.staticConfig ?? StaticConfig()
        if isStatic {
            switch ttlPopup.indexOfSelectedItem {
            case 1: staticConfig.ttl = .noCache
            case 2: staticConfig.ttl = .neverExpires
            case 3:
                guard let minutes = Int(ttlMinutesField.stringValue), minutes > 0 else {
                    errorLabel.stringValue = "自定义缓存有效期必须是大于 0 的分钟数。"
                    return
                }
                staticConfig.ttl = .minutes(minutes)
            default: staticConfig.ttl = .inherit
            }

            let extractionKind = selectedExtractionKind
            let extraction: ExtractionRule
            if extractionKind == .css {
                let selector = selectorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !selector.isEmpty else {
                    errorLabel.stringValue = "CSS 选择器不能为空。"
                    return
                }
                do {
                    try CSSSelector.validate(selector)
                } catch {
                    errorLabel.stringValue = "CSS 选择器无效：\(error.localizedDescription)"
                    return
                }
                extraction = ExtractionRule(kind: .css, cssSelector: selector,
                                            waitSelector: waitSelectorField.stringValue)
            } else {
                // 整页/通用提取不需要选择器，即使输入框里残留旧值也不写入。
                extraction = ExtractionRule(kind: extractionKind,
                                            cssSelector: "",
                                            waitSelector: waitSelectorField.stringValue)
            }
            staticConfig.extraction = extraction
            staticConfig.displayMode = selectedDisplayMode
            staticConfig.captureMode = capturePopup.indexOfSelectedItem == 1 ? .http : .webView
        }

        let groupID = groupPopup.indexOfSelectedItem >= 0 && groupPopup.indexOfSelectedItem < groupIDs.count
            ? groupIDs[groupPopup.indexOfSelectedItem]
            : nil
        let kind: BookmarkKind = isStatic ? .staticPage : .dynamic
        // 默认深色，选择“页面默认”时也显式落盘，避免与旧数据的默认深色混淆。
        let pageAppearance: PageAppearance? = selectedPageAppearance

        do {
            let finalID: UUID
            if var bookmark = existing {
                let oldKind = bookmark.kind
                bookmark.name = name
                bookmark.entryURL = url.absoluteString
                bookmark.kind = kind
                bookmark.groupID = groupID
                bookmark.proxy = proxy
                bookmark.blockingEnabled = blockingCheckbox.state == .on
                bookmark.pageAppearance = pageAppearance
                bookmark.staticConfig = staticConfig
                // 归属变更由 updateBookmark 负责（会追加到目标列表末尾），
                // 之前额外调用 moveBookmark 会让每次“编辑”都把收藏挪到分组末尾。
                try environment.store.updateBookmark(bookmark)
                if oldKind == .dynamic && kind == .staticPage {
                    environment.runtime.discardInstance(bookmarkID: bookmark.id)
                }
                finalID = bookmark.id
            } else {
                var created = try environment.store.createBookmark(name: name,
                                                                   entryURL: url.absoluteString,
                                                                   kind: kind,
                                                                   groupID: groupID,
                                                                   proxy: proxy,
                                                                   blockingEnabled: blockingCheckbox.state == .on)
                created.staticConfig = staticConfig
                created.pageAppearance = pageAppearance
                try environment.store.updateBookmark(created)
                finalID = created.id
            }
            // 已打开的网页立即换外观；未打开的下次创建时生效。
            environment.runtime.applyPageAppearance(bookmarkID: finalID)
            let savedID = finalID
            onSaved?(savedID)
            closeSheet()
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }

    private func closeSheet() {
        guard let panel = window else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            close()
        }
    }
}
