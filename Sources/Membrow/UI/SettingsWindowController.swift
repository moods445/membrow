import AppKit
import MembrowCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let environment: AppEnvironment

    private let proxyPopup = NSPopUpButton()
    private let proxyHostField = NSTextField()
    private let proxyPortField = NSTextField()
    private let startupPopup = NSPopUpButton()
    private let startupBookmarkPopup = NSPopUpButton()
    private let degradedLimitField = NSTextField()
    private let memoryBudgetField = NSTextField()
    private let staticTimeoutField = NSTextField()
    private let staticConcurrencyField = NSTextField()
    private let globalTTLField = NSTextField()
    private let faultInjectionCheckbox = NSButton(checkboxWithTitle: "注入私有内存接口失效（降级模式）",
                                                   target: nil, action: nil)
    private let microphoneCheckbox = NSButton(checkboxWithTitle: "允许网页使用麦克风（系统首次仍会询问一次）",
                                              target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机自启（登录时自动打开 Membrow）",
                                                 target: nil, action: nil)
    private let openLogsButton = NSButton(title: "打开日志", target: nil, action: nil)
    private let errorLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11), color: .systemRed)
    private let modeLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let diagnosticsTables = DiagnosticsTablesView()
    private let hintLabel = makeLabel("代理与拦截变更在重新打开网页后生效。",
                                      font: NSFont.systemFont(ofSize: 10),
                                      color: .secondaryLabelColor)

    private let credentialPopup = NSPopUpButton()
    private let deleteCredentialButton = NSButton(title: "删除", target: nil, action: nil)
    private let clearCredentialsButton = NSButton(title: "全部清除", target: nil, action: nil)

    private var bookmarkIDs: [UUID?] = []
    private var credentialItems: [StoredCredential] = []

    init(environment: AppEnvironment) {
        self.environment = environment
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 940),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "设置"
        panel.isReleasedWhenClosed = false
        // NSPanel 默认 hidesOnDeactivate = true：应用一失去焦点设置窗口就“消失”，
        // 看起来像打不开。设置窗口应像普通窗口一样常驻。
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildUI()
        populate()
        updateEnabledState()
        refreshDiagnostics()
        // 常驻巡检约每 30 秒通知一次，诊断表格因此不用手动刷新。
        environment.memoryMonitor.onDiagnosticsChange = { [weak self] in
            self?.refreshDiagnosticsIfVisible()
        }
    }

    /// 面板不可见时直接返回：常驻通知不会带来任何表格重建开销。
    private func refreshDiagnosticsIfVisible() {
        guard window?.isVisible == true else { return }
        refreshDiagnostics()
    }

    /// 每次打开都重新读取设置与凭据，避免窗口里显示上次的旧快照。
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        populate()
        updateEnabledState()
        refreshDiagnostics()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func buildUI() {
        guard let panel = window, let contentView = panel.contentView else { return }

        proxyPopup.addItems(withTitles: ["直连", "系统代理", "自定义 HTTP 代理"])
        proxyPopup.target = self
        proxyPopup.action = #selector(proxyModeChanged)

        proxyHostField.placeholderString = "127.0.0.1"
        proxyPortField.placeholderString = "8080"

        startupPopup.addItems(withTitles: StartupPolicy.allCases.map(\.displayName))
        startupPopup.target = self
        startupPopup.action = #selector(startupPolicyChanged)

        degradedLimitField.placeholderString = "4"
        memoryBudgetField.placeholderString = "1024"
        staticTimeoutField.placeholderString = "15"
        staticConcurrencyField.placeholderString = "2"
        globalTTLField.placeholderString = "1440"

        faultInjectionCheckbox.target = self
        faultInjectionCheckbox.action = #selector(refreshDiagnostics)

        openLogsButton.target = self
        openLogsButton.action = #selector(openLogs)
        openLogsButton.bezelStyle = .rounded
        openLogsButton.controlSize = .small

        let proxyHostRow = NSStackView(views: [proxyHostField, makeLabel(":", font: .systemFont(ofSize: 12)), proxyPortField])
        proxyHostRow.orientation = .horizontal
        proxyHostRow.spacing = 6
        proxyHostField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        proxyPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let startupRow = NSStackView(views: [startupPopup, startupBookmarkPopup])
        startupRow.orientation = .horizontal
        startupRow.spacing = 8
        startupPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        startupBookmarkPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let numericRow = NSStackView(views: [
            makeLabel("内存上限(MB)", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
            memoryBudgetField,
            makeLabel("降级实例上限", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
            degradedLimitField,
            makeLabel("抓取超时(秒)", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
            staticTimeoutField,
            makeLabel("并发", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
            staticConcurrencyField,
            makeLabel("全局 TTL(分钟)", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
            globalTTLField,
        ])
        numericRow.orientation = .horizontal
        numericRow.spacing = 6
        for field in [memoryBudgetField, degradedLimitField, staticTimeoutField, staticConcurrencyField, globalTTLField] {
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }

        for button in [deleteCredentialButton, clearCredentialsButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        deleteCredentialButton.action = #selector(deleteCredential)
        clearCredentialsButton.action = #selector(clearCredentials)
        credentialPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let credentialRow = NSStackView(views: [credentialPopup, deleteCredentialButton, clearCredentialsButton])
        credentialRow.orientation = .horizontal
        credentialRow.spacing = 6

        let diagnosticsScroll = NSScrollView()
        diagnosticsScroll.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsScroll.documentView = diagnosticsTables
        diagnosticsScroll.hasVerticalScroller = true
        diagnosticsScroll.drawsBackground = false
        diagnosticsScroll.borderType = .bezelBorder
        diagnosticsScroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        NSLayoutConstraint.activate([
            diagnosticsTables.leadingAnchor.constraint(equalTo: diagnosticsScroll.contentView.leadingAnchor),
            diagnosticsTables.topAnchor.constraint(equalTo: diagnosticsScroll.contentView.topAnchor),
            diagnosticsTables.widthAnchor.constraint(equalTo: diagnosticsScroll.contentView.widthAnchor),
        ])

        let refreshButton = NSButton(title: "刷新内存诊断", target: self, action: #selector(refreshDiagnostics))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small

        let grid = NSGridView(views: [
            [makeGridLabel("全局代理"), proxyPopup],
            [makeGridLabel(""), proxyHostRow],
            [makeGridLabel("启动策略"), startupRow],
            [makeGridLabel("启动"), launchAtLoginCheckbox],
            [makeGridLabel("资源"), numericRow],
            [makeGridLabel("媒体"), microphoneCheckbox],
            [makeGridLabel("已保存密码"), credentialRow],
            [makeGridLabel(""), faultInjectionCheckbox],
            [makeGridLabel("日志"), openLogsButton],
            [makeGridLabel("内存模式"), modeLabel],
            [makeGridLabel("诊断"), diagnosticsScroll],
            [makeGridLabel(""), refreshButton],
            [makeGridLabel(""), hintLabel],
            [makeGridLabel(""), errorLabel],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(grid)
        contentView.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    private func makeGridLabel(_ text: String) -> NSTextField {
        makeLabel(text, font: NSFont.systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    }

    // MARK: - Data

    private func populate() {
        let settings = environment.store.settings

        switch settings.globalProxy.mode {
        case .direct: proxyPopup.selectItem(at: 0)
        case .system: proxyPopup.selectItem(at: 1)
        case .custom: proxyPopup.selectItem(at: 2)
        }
        proxyHostField.stringValue = settings.globalProxy.host
        proxyPortField.stringValue = settings.globalProxy.port > 0 ? String(settings.globalProxy.port) : ""

        if let index = StartupPolicy.allCases.firstIndex(of: settings.startupPolicy) {
            startupPopup.selectItem(at: index)
        }

        startupBookmarkPopup.removeAllItems()
        bookmarkIDs = [nil]
        startupBookmarkPopup.addItem(withTitle: "—")
        for bookmark in environment.store.library.orderedBookmarks {
            bookmarkIDs.append(bookmark.id)
            startupBookmarkPopup.addItem(withTitle: bookmark.trimmedName)
        }
        if let startupID = settings.startupBookmarkID,
           let index = bookmarkIDs.firstIndex(where: { $0 == startupID }) {
            startupBookmarkPopup.selectItem(at: index)
        } else {
            startupBookmarkPopup.selectItem(at: 0)
        }

        memoryBudgetField.stringValue = String(settings.memoryBudgetMB)
        degradedLimitField.stringValue = String(settings.maxInstancesWhenDegraded)
        staticTimeoutField.stringValue = String(Int(settings.staticCaptureTimeout))
        staticConcurrencyField.stringValue = String(settings.staticConcurrency)
        globalTTLField.stringValue = String(settings.globalTTLMinutes)
        faultInjectionCheckbox.state = settings.forceMemoryAPIFailure ? .on : .off
        microphoneCheckbox.state = settings.microphoneEnabled ? .on : .off
        // 登录项以系统实际状态为准：用户在“系统设置”里手动关掉后，这里也跟着变。
        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        modeLabel.stringValue = environment.memoryMonitor.modeDisplayName
        reloadCredentials()
    }

    private func reloadCredentials() {
        credentialItems = environment.credentials.all()
        credentialPopup.removeAllItems()
        if credentialItems.isEmpty {
            credentialPopup.addItem(withTitle: "（尚无已保存密码）")
        } else {
            for item in credentialItems {
                credentialPopup.addItem(withTitle: "\(item.host) — \(item.username)")
            }
        }
        deleteCredentialButton.isEnabled = !credentialItems.isEmpty
        clearCredentialsButton.isEnabled = !credentialItems.isEmpty
    }

    @objc private func deleteCredential() {
        let index = credentialPopup.indexOfSelectedItem
        guard index >= 0, index < credentialItems.count else { return }
        let item = credentialItems[index]
        environment.credentials.delete(host: item.host, username: item.username)
        reloadCredentials()
    }

    @objc private func clearCredentials() {
        guard !credentialItems.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清除全部已保存密码"
        alert.informativeText = "将删除 \(credentialItems.count) 条钥匙串密码，且无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "全部清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        environment.credentials.deleteAll()
        reloadCredentials()
    }

    private func updateEnabledState() {
        let isCustom = proxyPopup.indexOfSelectedItem == 2
        proxyHostField.isEnabled = isCustom
        proxyPortField.isEnabled = isCustom

        let policy = StartupPolicy.allCases[max(0, startupPopup.indexOfSelectedItem)]
        startupBookmarkPopup.isEnabled = policy == .openBookmark
    }

    @objc private func refreshDiagnostics() {
        modeLabel.stringValue = environment.memoryMonitor.modeDisplayName
        let tables = environment.memoryMonitor.diagnosticTables()
        let settings = environment.store.settings
        let configRows: [[String]] = [
            ["启动策略", settings.startupPolicy.displayName],
            ["内存上限", "\(settings.memoryBudgetMB) MB"],
            ["静态并发", "\(settings.staticConcurrency)（硬上限 \(AppSettings.staticConcurrencyHardLimit)）"],
            ["静态超时", "\(Int(settings.staticCaptureTimeout)) 秒"],
            ["全局 TTL", "\(settings.globalTTLMinutes) 分钟"],
            ["麦克风", settings.microphoneEnabled ? "允许（系统授权为准）" : "禁止"],
            ["诊断日志", "info.jsonl / problems.jsonl（各上限 20MB）"],
            ["开机自启", LaunchAtLogin.statusDescription],
        ]
        diagnosticsTables.update(status: tables.status, instances: tables.instances, config: configRows)
    }

    // MARK: - Actions

    @objc private func proxyModeChanged() {
        updateEnabledState()
    }

    @objc private func startupPolicyChanged() {
        updateEnabledState()
    }

    @objc private func save() {
        errorLabel.stringValue = ""
        var settings = environment.store.settings

        switch proxyPopup.indexOfSelectedItem {
        case 1:
            settings.globalProxy = ProxySettings(mode: .system)
        case 2:
            guard let port = Int(proxyPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                errorLabel.stringValue = "代理端口必须是数字"
                return
            }
            settings.globalProxy = ProxySettings(mode: .custom,
                                                 host: proxyHostField.stringValue,
                                                 port: port)
        default:
            settings.globalProxy = ProxySettings(mode: .direct)
        }

        let policy = StartupPolicy.allCases[max(0, min(startupPopup.indexOfSelectedItem,
                                                       StartupPolicy.allCases.count - 1))]
        settings.startupPolicy = policy
        let bookmarkIndex = startupBookmarkPopup.indexOfSelectedItem
        settings.startupBookmarkID = policy == .openBookmark && bookmarkIndex >= 0 && bookmarkIndex < bookmarkIDs.count
            ? bookmarkIDs[bookmarkIndex]
            : nil

        guard let memoryBudget = Int(memoryBudgetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLabel.stringValue = "内存上限必须是整数（MB）"
            return
        }
        guard let degradedLimit = Int(degradedLimitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLabel.stringValue = "降级实例上限必须是整数"
            return
        }
        guard let timeout = Double(staticTimeoutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLabel.stringValue = "抓取超时必须是数字"
            return
        }
        guard let concurrency = Int(staticConcurrencyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLabel.stringValue = "静态并发必须是整数"
            return
        }
        guard let ttl = Int(globalTTLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLabel.stringValue = "全局 TTL 必须是整数分钟"
            return
        }
        settings.memoryBudgetMB = memoryBudget
        settings.maxInstancesWhenDegraded = degradedLimit
        settings.staticCaptureTimeout = timeout
        settings.staticConcurrency = concurrency
        settings.globalTTLMinutes = ttl
        settings.forceMemoryAPIFailure = faultInjectionCheckbox.state == .on
        settings.microphoneEnabled = microphoneCheckbox.state == .on

        // 全部校验通过后再动系统登录项，避免输入有误时已经改掉开机自启。
        let desiredLaunchAtLogin = launchAtLoginCheckbox.state == .on
        let loginItemError = desiredLaunchAtLogin == LaunchAtLogin.isEnabled
            ? nil
            : LaunchAtLogin.setEnabled(desiredLaunchAtLogin)
        settings.launchAtLogin = LaunchAtLogin.isEnabled

        do {
            try environment.store.updateSettings(settings)
            environment.staticManager.onChange?()
            // store 会把越界值静默钳制（如内存 100 → 128），回填一次让界面与实际配置一致。
            populate()
            refreshDiagnostics()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            return
        }
        // 系统拒绝（未安装到 /Applications、签名不稳定、需要人工批准）时保留提示，不静默失败。
        if let loginItemError {
            errorLabel.stringValue = loginItemError
        }
    }

    /// 日志目录在 Finder 里打开；目录不存在时先建好，避免点了没反应。
    @objc private func openLogs() {
        let directory = environment.dataDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func closePanel() {
        window?.close()
    }
}
