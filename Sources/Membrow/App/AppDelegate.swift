import AppKit
import MembrowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var windowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        do {
            let environment = try AppEnvironment()
            self.environment = environment
            let windowController = MainWindowController(environment: environment)
            self.windowController = windowController
            windowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            environment.launch()
            windowController.applyStartupPolicy()

            if !environment.store.loadWarnings.isEmpty {
                let alert = NSAlert()
                alert.messageText = "部分数据读取失败"
                alert.informativeText = environment.store.loadWarnings.joined(separator: "\n")
                alert.alertStyle = .warning
                alert.runModal()
            }

            if CommandLine.arguments.contains("--diagnose-memory") {
                MemoryDiagnostics.run(environment: environment) { code in
                    exit(code)
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Membrow 启动失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc private func showSettings(_ sender: Any?) {
        guard let environment else { return }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(environment: environment)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func newBookmark(_ sender: Any?) {
        windowController?.createBookmark()
    }

    @objc private func newSession(_ sender: Any?) {
        windowController?.createSession()
    }

    @objc private func newGroup(_ sender: Any?) {
        windowController?.createGroup()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        windowController?.toggleSidebar()
    }

    @objc private func reloadCurrent(_ sender: Any?) {
        windowController?.reloadCurrent()
    }

    @objc private func goBack(_ sender: Any?) {
        windowController?.goBack()
    }

    @objc private func goForward(_ sender: Any?) {
        windowController?.goForward()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Membrow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Membrow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Membrow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let bookmarkItem = NSMenuItem(title: "新建收藏…", action: #selector(newBookmark(_:)), keyEquivalent: "n")
        bookmarkItem.target = self
        fileMenu.addItem(bookmarkItem)
        let sessionItem = NSMenuItem(title: "新建聚合", action: #selector(newSession(_:)), keyEquivalent: "N")
        sessionItem.target = self
        fileMenu.addItem(sessionItem)
        let groupItem = NSMenuItem(title: "新建分组…", action: #selector(newGroup(_:)), keyEquivalent: "G")
        groupItem.target = self
        fileMenu.addItem(groupItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 没有“编辑”菜单时，⌘C/⌘V/⌘X/⌘A 没有对应菜单项，粘贴/拷贝在文本框里完全失效。
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        // 侧栏折叠后必须有入口恢复，否则只能靠拖拽分隔条重新拉开。
        let sidebarItem = NSMenuItem(title: "显示/隐藏侧栏",
                                     action: #selector(toggleSidebar(_:)),
                                     keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)
        viewMenu.addItem(.separator())
        let reloadItem = NSMenuItem(title: "刷新", action: #selector(reloadCurrent(_:)), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        let backItem = NSMenuItem(title: "后退", action: #selector(goBack(_:)), keyEquivalent: "[")
        backItem.target = self
        viewMenu.addItem(backItem)
        let forwardItem = NSMenuItem(title: "前进", action: #selector(goForward(_:)), keyEquivalent: "]")
        forwardItem.target = self
        viewMenu.addItem(forwardItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
