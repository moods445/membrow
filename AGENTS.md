# AGENTS.md

给在本仓库工作的 AI/人类协作者的通用规则。与 `docs/` 冲突时以需求文档为准，并把冲突写进 `todos/v0.1-todo.md`。

## 项目事实

- macOS 14+ / SwiftPM / Swift 5 语言模式；**没有 Xcode 工程**。
- 目标：`Membrow`（AppKit + WKWebView 专用浏览器，内存优先）；核心逻辑在 `MembrowCore`，UI 在 `Membrow`。
- 数据目录（遵循 macOS 规范）：`~/Library/Application Support/<CFBundleIdentifier>`，即 `com.membrow.app`。
  - v0.1 早期版本写作 `.../Application Support/Membrow`，首次启动会自动整体迁移；迁移失败则继续使用旧目录。
  - `MEMBROW_DATA_DIR` 只用于测试隔离，不是常规配置项。
- 命令：
  ```bash
  swift build                                   # 0 Swift 告警是提交门槛
  .build/debug/MembrowSelfTest                  # 核心断言（当前 177 checks）
  ./scripts/build-app.sh [debug|release]        # 生成 dist/Membrow.app（ad-hoc 签名）
  dist/Membrow.app/Contents/MacOS/Membrow --diagnose-memory
  ```

## 必须遵守

1. **不碰用户数据**：任何测试、冒烟、截图都用 `MEMBROW_DATA_DIR=/tmp/...` 的隔离目录；**禁止删除、改名或覆盖** `~/Library/Application Support/com.membrow.app` 与旧目录 `.../Membrow`。测试结束清理 `/tmp` 下的临时目录。
2. **密钥只进钥匙串**：密码、令牌、Cookie 明文不得写入 JSON / SQLite / 日志 / 错误信息；凭据只能走 `CredentialStore`（`kSecClassInternetPassword`）。
3. **注入边界**：只允许两类页面脚本——`WKContentRuleList`（资源拦截，不注入 JS）与 `CredentialScript`（仅读写登录表单字段）。禁止冻结 / 快照 / 内容比对脚本、用户自定义脚本、资源劫持。
4. **设置向后兼容**：`AppSettings` 新增字段必须用 `decodeIfPresent` + 默认值，保证旧 `settings.json` 可读；同时更新设置界面、`--diagnose` 摘要与自测。
5. **即时同步文档**：功能/缺陷改动当轮同步 `todos/v0.1-todo.md`；已完成能力同步 `docs/v0.1-实现汇总.md`。UI 文案必须与实际行为一致（删除聚合的提示、拦截开关的“刷新后生效”等）。
6. **可运行验证**：非平凡逻辑（分支、循环、解析、金额/安全路径）至少留一条可运行断言，放在 `MembrowSelfTest`；UI 层无法自动化的部分在 todo 里写清“待人工复验”。
7. **内存口径**：预算来自 `AppSettings.memoryBudgetMB`（默认 1024，范围 128–8192），统计只含 `proc_pid_rusage` 的 `phys_footprint`（不含 GPU/显存）；动态实例与静态“精简快照”WebView 同池计算并按 LRU 淘汰（快照被回收时视图回退 Markdown），抓取任务本身仍不进入该池。
8. **告警门槛**：`swift build` 不允许出现 Swift 编译告警。`ld: search path ... not found` 属本机工具链缺失路径，可忽略，不要为它改 `Package.swift` 加 `unsafeFlags`（`scripts/build-app.sh` 已单独过滤这一类，其余链接告警照常显示）。

## 端到端验证手法

- 启动隔离实例（**不抢焦点，应用开在后台**）：`open -g -n --env MEMBROW_DATA_DIR=/tmp/membrow-test dist/Membrow.app`
  - 不要用 `open -a`/激活方式测试；`osascript` 也别 `set frontmost to true`，除非用户明确要求。
  - 后台状态下 `occlusionState` 可能不含 `.visible`，`ContentSlotView` 会判定不可见而不自动创建 WebView；
    要触发加载就点内容区的“打开”按钮（`click button "打开" of splitter group 1 of window 1`），不要靠激活窗口。
  - 菜单命令用 AXPress 点击菜单项（后台可用）：`click menu item "刷新" of menu 1 of menu bar item "显示" of menu bar 1`；避免依赖 ⌘ 快捷键（前台焦点才能收到）。
  - 多个同 bundle id 实例并存时，用 `first process whose unix id is <pid>` 精确指定，不要用 `process "Membrow"`。
  - 应用在后台时，**编辑面板（NSPanel sheet）里的按钮收不到 AXPress**（取消/保存都无反应）；这类路径改用“预置数据 + 启动时自动流程”验证，或请人工点测。
  - 手写 `library.json` 造数据时注意：`groupOrders` 是 `[UUID: [UUID]]`，非 String 键的字典按**数组**编码（空值写成 `[]`），写成 `{}` 会解码失败。
- UI 自动化可用辅助功能（本机已验证可用）：
  ```bash
  osascript -e 'tell application "System Events" to tell process "Membrow" to get name of every window'
  osascript -e 'tell application "System Events" to tell process "Membrow" to tell window 1 to click button "保存"'
  ```
  `NSPopUpButton` 用 `indexOfSelectedItem` 判断选项（`addItems` 不设 tag，`selectedTag()` 恒为 0）。
- **本机无屏幕录制权限**：`screencapture` 只会得到壁纸，不能用作 UI 证据；改用辅助功能读值 + 数据文件断言。
- 弹出菜单/输入法会干扰脚本输入：文本优先用 `set value of text field N` 或剪贴板 + ⌘V，不要逐字符 keystroke 中文。
- 排查约束/布局问题：`lldb --batch -o "breakpoint set -n _NSLayoutConstraintNumberExceedsLimit" -o run ...`，但断点不命中会一直等待，务必用后台启动 + 日志抓取兜底（`(bin > log 2>&1 &)`）。

## 代码约定

- 注释用中文；刻意简化处标 `// ponytail: 说明上限与升级路径`。
- 资源释放：WKWebView 销毁要 `stopLoading` + 置空 delegate + `removeScriptMessageHandler` + `removeFromSuperview`。
- 并发：跨任务共享的限流只用一个 `ConcurrencyLimiter`，运行期调上限用 `setLimit`，禁止重建实例（会突破硬上限）。
- 临时文件/脚本放 `/tmp` 并在结束前清理。
