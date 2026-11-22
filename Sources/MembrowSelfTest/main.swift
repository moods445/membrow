import Foundation
import MembrowCore

/// 可重复运行的核心验收自测。工具链缺少 XCTest / Testing 运行器，
/// 因此用独立可执行目标承载断言：`swift run MembrowSelfTest`。
@MainActor
final class Harness {
    private(set) var failures = 0
    private(set) var checks = 0

    func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL [\(line)] \(message)")
        }
    }

    func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL [\(line)] \(message): 期望 \(expected)，实际 \(actual)")
        }
    }

    func expectThrows<E: Error & Equatable>(_ expected: E, _ message: String, line: Int = #line, _ block: () throws -> Void) {
        checks += 1
        do {
            try block()
            failures += 1
            print("FAIL [\(line)] \(message): 未抛出错误")
        } catch let error as E {
            if error != expected {
                failures += 1
                print("FAIL [\(line)] \(message): 期望 \(expected)，实际 \(error)")
            }
        } catch {
            failures += 1
            print("FAIL [\(line)] \(message): 错误类型不符 \(error)")
        }
    }

    func expectThrowsAny(_ message: String, line: Int = #line, _ block: () throws -> Void) {
        checks += 1
        do {
            try block()
            failures += 1
            print("FAIL [\(line)] \(message): 未抛出错误")
        } catch {
            // 预期行为
        }
    }

    func makeStore(now: @escaping () -> Date = Date.init) throws -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MembrowSelfTest-\(UUID().uuidString)")
        let store = try AppStore(directory: url, now: now)
        return (store, url)
    }

    func cleanup(_ url: URL) {
        // 允许失败：临时目录不阻塞结果。
        try? FileManager.default.removeItem(at: url)
    }

    func require<T>(_ value: T?, _ message: String, line: Int = #line) -> T? {
        checks += 1
        if value == nil {
            failures += 1
            print("FAIL [\(line)] \(message)")
        }
        return value
    }

    func run() async {
        await testBookmarks()
        await testPersistenceAndSessions()
        testCacheAndTTL()
        testSnapshotAndDisplayMode()
        testTextTable()
        testExtraction()
        testMemory()
        testSiteMatcher()
        await testConcurrencyLimiter()
        await testConcurrencyLimiterDynamicLimit()
        await testSettingsEdges()
        await testDataRecovery()
        testSettingsCompatibility()
        testDataDirectory()
        testSiteMetadata()
        testCredentialScripts()
        testDiagnosticLog()

        if failures == 0 {
            print("PASS \(checks) checks")
        } else {
            print("FAILED \(failures)/\(checks) checks")
        }
    }

    // MARK: Bookmarks and library

    private func testBookmarks() async {
        do {
            let (store, directory) = try makeStore()
            defer { cleanup(directory) }

            let first = try store.createBookmark(name: "A", entryURL: "https://example.com", kind: .dynamic)
            let second = try store.createBookmark(name: "B", entryURL: "https://example.com", kind: .dynamic)
            check(first.id != second.id, "同 URL 收藏必须具有不同 ID")

            var updatedFirst = first
            updatedFirst.lastURL = "https://example.com/page-a"
            updatedFirst.dynamicConfig.isPinned = true
            try store.updateBookmark(updatedFirst)
            checkEqual(store.bookmark(id: first.id)?.lastURL, "https://example.com/page-a", "收藏最后地址独立")
            check(store.bookmark(id: second.id)?.lastURL == nil, "同 URL 另一个收藏不受影响")
            checkEqual(store.bookmark(id: first.id)?.isPinned, true, "固定状态独立")
            checkEqual(store.bookmark(id: second.id)?.isPinned, false, "同 URL 另一个收藏未固定")

            store.deleteBookmark(id: first.id)
            check(store.bookmark(id: first.id) == nil, "按 ID 删除收藏")
            check(store.bookmark(id: second.id) != nil, "删除同 URL 收藏不影响其他收藏")

            let group = try store.createGroup(name: "工作")
            let bookmark = try store.createBookmark(name: "站点", entryURL: "https://group.example.com", kind: .dynamic)
            store.moveBookmark(id: bookmark.id, toGroup: group.id, at: 0)
            checkEqual(store.library.bookmarks(inGroup: group.id).count, 1, "收藏归入单层分组")
            store.deleteGroup(id: group.id)
            checkEqual(store.bookmark(id: bookmark.id)?.groupID, nil, "删除分组后收藏回到根层")
            check(store.library.rootOrder.contains(bookmark.id), "根层顺序补全收藏")

            var invalid = try store.createBookmark(name: "X", entryURL: "https://x.example.com", kind: .dynamic)
            invalid.entryURL = "not-a-url"
            expectThrowsAny("无效 URL 编辑被拒绝") { try store.updateBookmark(invalid) }

            var settings = store.settings
            settings.globalProxy = ProxySettings(mode: .custom, host: "10.0.0.1", port: 8080)
            try store.updateSettings(settings)
            let override = try store.createBookmark(name: "C", entryURL: "https://c.example.com",
                                                    kind: .dynamic,
                                                    proxy: ProxySettings(mode: .custom, host: "10.0.0.2", port: 9090))
            let inherited = try store.createBookmark(name: "D", entryURL: "https://d.example.com", kind: .dynamic)
            if let overrideBookmark = store.bookmark(id: override.id),
               let inheritedBookmark = store.bookmark(id: inherited.id) {
                checkEqual(store.resolvedProxy(for: overrideBookmark).proxy.host,
                           "10.0.0.2", "收藏代理覆盖全局")
                checkEqual(store.resolvedProxy(for: inheritedBookmark).proxy.host,
                           "10.0.0.1", "未覆盖时继承全局")
            } else {
                failures += 1
                print("FAIL 代理测试收藏缺失")
            }
        } catch {
            failures += 1
            print("FAIL bookmark tests threw: \(error)")
        }
    }

    // MARK: Persistence, sessions, settings

    private func testPersistenceAndSessions() async {
        do {
            let (store, directory) = try makeStore()
            defer { cleanup(directory) }

            let group = try store.createGroup(name: "阅读")
            let first = try store.createBookmark(name: "一", entryURL: "https://one.example.com", kind: .dynamic)
            let second = try store.createBookmark(name: "二", entryURL: "https://two.example.com", kind: .staticPage)
            store.moveBookmark(id: first.id, toGroup: group.id, at: 0)
            store.moveBookmark(id: second.id, toGroup: group.id, at: 1)
            store.setGroupExpanded(id: group.id, expanded: false)

            var bookmark = require(store.bookmark(id: second.id), "second bookmark")!
            bookmark.staticConfig.ttl = .minutes(30)
            bookmark.staticConfig.extraction = ExtractionRule(kind: .css, cssSelector: "article")
            bookmark.proxy = ProxySettings(mode: .custom, host: "127.0.0.1", port: 7890)
            try store.updateBookmark(bookmark)

            let session = store.createSession(name: "布局")
            let firstPane = require(session.root?.firstPane, "first pane")!
            store.assignBookmark(first.id, sessionID: session.id, paneID: firstPane.id)
            store.splitPane(sessionID: session.id, paneID: firstPane.id, axis: .vertical)
            var current = require(store.session(id: session.id), "session")!
            checkEqual(current.allPanes.count, 2, "竖直分割产生两个 pane")
            let secondPane = require(current.allPanes.last, "second pane")!
            checkEqual(current.allPanes.first?.bookmarkID, first.id, "分割保留原 pane 的收藏")
            checkEqual(secondPane.bookmarkID, nil, "新分割出的 pane 为空")
            store.assignBookmark(second.id, sessionID: session.id, paneID: secondPane.id)
            store.zoomPane(sessionID: session.id, paneID: firstPane.id, zoomed: true)

            current = require(store.session(id: session.id), "session zoom")!
            checkEqual(current.zoomedPaneID, firstPane.id, "放大 pane 状态持久化")
            store.closePane(sessionID: session.id, paneID: secondPane.id)
            current = require(store.session(id: session.id), "session close")!
            checkEqual(current.allPanes.map(\.id), [firstPane.id], "关闭 pane 后相邻 pane 填满")
            checkEqual(current.zoomedPaneID, firstPane.id, "关闭其他 pane 不影响放大状态")

            store.closePane(sessionID: session.id, paneID: firstPane.id)
            current = require(store.session(id: session.id), "empty session")!
            checkEqual(current.zoomedPaneID, nil, "关闭被放大的 pane 后清除放大")
            check(current.root == nil, "允许关闭全部 pane")
            check(current.focusedPaneID == nil, "空聚合无聚焦 pane")
            store.splitPane(sessionID: session.id, paneID: nil, axis: .horizontal)
            current = require(store.session(id: session.id), "split empty")!
            checkEqual(current.allPanes.count, 1, "空聚合仍可分割出 pane")

            var settings = store.settings
            settings.staticConcurrency = 99
            settings.maxInstancesWhenDegraded = 0
            settings.staticCaptureTimeout = 0
            try store.updateSettings(settings)
            checkEqual(store.settings.staticConcurrency, 4, "静态并发硬上限 4")
            checkEqual(store.settings.maxInstancesWhenDegraded, 1, "降级实例上限至少 1")
            checkEqual(store.settings.staticCaptureTimeout, 1, "抓取超时下限 1 秒")

            var invalidSettings = store.settings
            invalidSettings.globalProxy = ProxySettings(mode: .custom, host: "", port: 0)
            expectThrowsAny("非法代理不能保存") { try store.updateSettings(invalidSettings) }
            checkEqual(store.settings.globalProxy.mode, .direct, "非法代理保存后仍为直连")

            let reloaded = try AppStore(directory: directory)
            checkEqual(reloaded.library.groups.first?.isExpanded, false, "分组展开状态持久化")
            checkEqual(reloaded.library.bookmarks(inGroup: group.id).map(\.id), [first.id, second.id], "分组内顺序持久化")
            checkEqual(reloaded.bookmark(id: second.id)?.staticConfig.ttl, .minutes(30), "TTL 配置持久化")
            checkEqual(reloaded.bookmark(id: second.id)?.staticConfig.extraction.cssSelector, "article", "提取规则持久化")
            checkEqual(reloaded.bookmark(id: second.id)?.proxy?.port, 7890, "收藏代理持久化")
            checkEqual(reloaded.session(id: session.id)?.allPanes.count, 1, "聚合布局持久化")
        } catch {
            failures += 1
            print("FAIL persistence tests threw: \(error)")
        }
    }

    private func testCacheAndTTL() {
        do {
            let (store, directory) = try makeStore()
            defer { cleanup(directory) }

            let first = try store.createBookmark(name: "A", entryURL: "https://same.example.com", kind: .staticPage)
            let second = try store.createBookmark(name: "B", entryURL: "https://same.example.com", kind: .staticPage)
            let metadata = StaticMetadata(title: "A", sourceURL: first.entryURL,
                                          extractionKind: .css, captureMode: .webView)
            store.store(CachedDocument(markdown: "A body", metadata: metadata, fetchedAt: Date(),
                                       snapshotHTML: "<html><body>snapshot</body></html>"),
                        for: first.id)
            checkEqual(store.cachedDocument(for: first.id)?.markdown, "A body", "按收藏 ID 读取缓存")
            checkEqual(store.cachedDocument(for: first.id)?.snapshotHTML, "<html><body>snapshot</body></html>",
                       "快照与正文一起持久化")
            check(store.cachedDocument(for: second.id) == nil, "同 URL 缓存隔离")

            let evaluator = TTLEvaluator(globalMinutes: 60)
            let now = Date(timeIntervalSince1970: 20_000)
            checkEqual(evaluator.freshness(ttl: .inherit, fetchedAt: nil, now: now), .missing, "无缓存状态")
            checkEqual(evaluator.freshness(ttl: .inherit, fetchedAt: now.addingTimeInterval(-30 * 60), now: now),
                       .fresh, "继承全局未过期")
            checkEqual(evaluator.freshness(ttl: .inherit, fetchedAt: now.addingTimeInterval(-61 * 60), now: now),
                       .stale, "继承全局已过期")
            checkEqual(evaluator.freshness(ttl: .noCache, fetchedAt: now, now: now), .stale, "TTL 0 不使用缓存")
            checkEqual(evaluator.freshness(ttl: .neverExpires, fetchedAt: now.addingTimeInterval(-10_000_000), now: now),
                       .fresh, "永不过期")
            checkEqual(evaluator.freshness(ttl: .minutes(10), fetchedAt: now.addingTimeInterval(-5 * 60), now: now),
                       .fresh, "收藏 TTL 覆盖全局")
            checkEqual(evaluator.freshness(ttl: .minutes(10), fetchedAt: now.addingTimeInterval(-11 * 60), now: now),
                       .stale, "收藏 TTL 过期")

            let reloaded = try AppStore(directory: directory)
            checkEqual(reloaded.cachedDocument(for: first.id)?.markdown, "A body", "缓存重启后可读")

            var bookmark = require(store.bookmark(id: first.id), "cache bookmark")!
            bookmark.entryURL = "https://changed.example.com"
            bookmark.staticConfig.ttl = .minutes(120)
            try store.updateBookmark(bookmark)
            checkEqual(store.bookmark(id: first.id)?.id, first.id, "修改 URL 不改变 ID")
            checkEqual(store.cachedDocument(for: first.id)?.markdown, "A body", "修改 URL 不丢缓存关联")
        } catch {
            failures += 1
            print("FAIL cache tests threw: \(error)")
        }
    }

    // MARK: Snapshot

    private func testSnapshotAndDisplayMode() {
        do {
            let legacyJSON = """
            {"captureMode":"webView","ttl":{"kind":"inherit"},
             "extraction":{"kind":"css","cssSelector":"article","waitSelector":""}}
            """
            let legacy = try JSONDecoder().decode(StaticConfig.self, from: Data(legacyJSON.utf8))
            checkEqual(legacy.displayMode, .snapshot, "旧配置缺字段时默认精简快照")
            checkEqual(legacy.extraction.kind, .css, "旧配置提取规则保留")

            var muted = StaticConfig()
            muted.displayMode = .markdown
            let roundTrip = try JSONDecoder().decode(StaticConfig.self,
                                                     from: JSONEncoder().encode(muted))
            checkEqual(roundTrip.displayMode, .markdown, "显示方式可持久化")

            let html = """
            <html><head><title>T</title><style>.a{color:red}</style>
            <link rel="stylesheet" href="https://example.com/a.css">
            <link rel="preload" href="https://example.com/x.js">
            <script>alert(1)</script></head>
            <body onload="steal()"><h1>标题</h1><div onclick="x()">正文 &amp; 更多</div>
            <iframe src="https://ad.example"></iframe><div hidden>隐藏</div>
            <form><input value="a"><button>按钮</button></form>
            <img src="/logo.png" alt="logo"></body></html>
            """
            let snapshot = HTMLSnapshotSanitizer.sanitize(html: html)
            check(snapshot.hasPrefix("<!doctype html>"), "快照带 doctype")
            check(!snapshot.contains("alert(1)"), "快照去脚本")
            check(!snapshot.contains("onclick") && !snapshot.contains("onload"), "快照去内联事件")
            check(!snapshot.contains("<iframe") && !snapshot.contains("隐藏"), "快照去 iframe 与隐藏节点")
            check(!snapshot.contains("<form") && !snapshot.contains("<button"), "快照去表单控件")
            check(!snapshot.contains("preload"), "快照去预加载资源")
            check(snapshot.contains("<style>.a{color:red}</style>"), "快照保留样式")
            check(snapshot.contains("rel=\"stylesheet\""), "快照保留外链样式")
            check(snapshot.contains("<h1>标题</h1>"), "快照保留布局结构")
            check(snapshot.contains("正文 &amp; 更多"), "快照转义文本")
            check(snapshot.contains("src=\"/logo.png\"") && snapshot.contains("alt=\"logo\""),
                  "快照保留图片属性")
            check(!snapshot.contains("</img>"), "快照图片自闭合")

            // pre 里的 code 子节点必须按正常元素序列化：既不能整段丢失，也不能把实体还原成标签。
            let codeHTML = """
            <html><body><pre><code class="lang">let x = 1 &lt; 2</code></pre>
            <pre>&lt;script&gt;alert(1)&lt;/script&gt;</pre></body></html>
            """
            let codeSnapshot = HTMLSnapshotSanitizer.sanitize(html: codeHTML)
            check(codeSnapshot.contains("<code"), "快照保留 pre 内的 code 元素")
            check(codeSnapshot.contains("let x = 1 &lt; 2"), "快照保留代码文本并转义")
            check(!codeSnapshot.contains("<script>"), "pre 内实体不会被还原成标签")
        } catch {
            failures += 1
            print("FAIL snapshot tests threw: \(error)")
        }
    }

    // MARK: Text table

    private func testTextTable() {
        let table = TextTable.render(headers: ["项目", "值"],
                                     rows: [["内存模式", "1 MB"], ["快照", "2 MB"]])
        let lines = table.components(separatedBy: "\n")
        checkEqual(lines.count, 4, "表格含表头、分隔行与两行数据")
        check(lines[2].hasPrefix("内存模式  1 MB"), "中文按双宽对齐")
        check(lines[3].hasPrefix("快照      2 MB"), "短内容按列宽补空格")
        check(!lines[2].hasSuffix(" "), "行尾不留空格")
        checkEqual(TextTable.render(headers: [], rows: []), "", "空表返回空串")
    }

    // MARK: Extraction

    private let articleHTML = """
    <!doctype html>
    <html><head><title>示例文章</title><style>.x{color:red}</style></head>
    <body>
    <nav><a href="/">首页</a><a href="/about">关于</a></nav>
    <article id="content" class="post main">
      <h1>示例标题</h1>
      <p>第一段正文，包含 <strong>重点</strong> 与 <a href="https://example.com/link">链接</a>。</p>
      <p>第二段正文，延续内容。</p>
      <ul><li>条目一</li><li>条目二</li></ul>
      <pre><code>let value = 1</code></pre>
      <script>console.log('noise')</script>
    </article>
    <footer>版权信息</footer>
    </body></html>
    """

    private func testExtraction() {
        let pageURL = URL(string: "https://example.com/post")!

        do {
            // 默认规则即整页转换：不配置选择器也能产出 Markdown，且保留原布局顺序。
            let wholePage = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL, rule: ExtractionRule())
            checkEqual(ExtractionRule().kind, .fullPage, "静态默认提取规则为整页转换")
            checkEqual(wholePage.extractionKind, .fullPage, "默认走整页提取")
            check(wholePage.markdown.contains("首页"), "整页保留导航")
            check(wholePage.markdown.contains("版权信息"), "整页保留页脚")
            check(wholePage.markdown.contains("# 示例标题"), "整页保留标题层级")
            check(!wholePage.markdown.contains("console.log"), "整页排除脚本")
            if let nav = wholePage.markdown.range(of: "首页"),
               let body = wholePage.markdown.range(of: "第一段正文") {
                check(nav.lowerBound < body.lowerBound, "整页按原布局顺序输出")
            } else {
                failures += 1
                print("FAIL 整页缺少导航或正文")
            }
            // 原布局：块内相邻元素/标签与数值各自成段；句中的行内链接不拆句。
            do {
                let layout = try ExtractorFactory.extract(
                    html: """
                    <html><body>
                    <div><span>套餐基础积分</span><strong>500</strong></div>
                    <div>欢迎体验 <a href="https://example.com/w">WorkBuddy</a>，首月赠送积分</div>
                    <div>已用 41.63 / 100 积分<strong>剩余 58.37</strong></div>
                    <div><img src="/a.svg" alt=""><strong>按需购买积分</strong></div>
                    </body></html>
                    """,
                    pageURL: pageURL,
                    rule: ExtractionRule())
                check(layout.markdown.contains("套餐基础积分 **500**"), "行内标签与数值不再粘连")
                check(layout.markdown.contains("欢迎体验 [WorkBuddy](https://example.com/w)，首月赠送积分"),
                      "行内文本与链接不拆句")
                check(layout.markdown.contains("积分 **剩余 58.37**"), "紧贴元素的数值用空格隔开")
                check(layout.markdown.contains("![](/a.svg) **按需购买积分**"), "图片与相邻行内元素不粘连")

                let blocks = try ExtractorFactory.extract(
                    html: "<html><body><div><div>套餐基础积分</div><strong>500</strong></div></body></html>",
                    pageURL: pageURL,
                    rule: ExtractionRule())
                check(blocks.markdown.contains("套餐基础积分\n\n**500**"), "块级元素相邻各自成段")

                let spans = try ExtractorFactory.extract(
                    html: """
                    <html><body><div><span>欢迎体验</span><a href="https://example.com/w">WorkBuddy</a><span>，首月赠送</span></div></body></html>
                    """,
                    pageURL: pageURL,
                    rule: ExtractionRule())
                check(spans.markdown.contains("欢迎体验 [WorkBuddy](https://example.com/w)，首月赠送"),
                      "span 包裹的句子不被拆散")

                let paragraph = try ExtractorFactory.extract(
                    html: "<html><body><p>套餐基础积分<strong>500</strong> 点</p></body></html>",
                    pageURL: pageURL,
                    rule: ExtractionRule())
                check(paragraph.markdown.contains("套餐基础积分 **500** 点"), "段落内不再粘连")
            }

            expectThrows(ExtractionError.emptyBody, "整页空正文失败") {
                _ = try ExtractorFactory.extract(html: "<html><body>  <script>x</script></body></html>",
                                                 pageURL: pageURL, rule: ExtractionRule(kind: .fullPage))
            }

            let result = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL,
                                                      rule: ExtractionRule(kind: .css, cssSelector: "article#content"))
            checkEqual(result.title, "示例文章", "提取标题")
            check(result.markdown.contains("# 示例标题"), "标题转 Markdown")
            check(result.markdown.contains("**重点**"), "粗体转 Markdown")
            check(result.markdown.contains("[链接](https://example.com/link)"), "链接转 Markdown")
            check(result.markdown.contains("- 条目一"), "列表转 Markdown")
            check(result.markdown.contains("```"), "代码块转 Markdown")
            check(!result.markdown.contains("console.log"), "脚本被排除")
            check(!result.markdown.contains("版权信息"), "选择器范围外的页脚被排除")

            let paragraphs = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL,
                                                          rule: ExtractionRule(kind: .css, cssSelector: "article.post p"))
            check(paragraphs.markdown.contains("第一段正文"), "类与后代选择器匹配")
            check(!paragraphs.markdown.contains("示例标题"), "后代选择器只取 p")

            expectThrows(ExtractionError.selectorNotConfigured, "未配置选择器失败") {
                _ = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL,
                                                 rule: ExtractionRule(kind: .css, cssSelector: "  "))
            }
            expectThrows(ExtractionError.selectorNotMatched(".nope"), "未匹配失败") {
                _ = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL,
                                                 rule: ExtractionRule(kind: .css, cssSelector: ".nope"))
            }
            expectThrows(ExtractionError.emptyBody, "通用提取空正文") {
                _ = try ExtractorFactory.extract(html: "<html><body><nav>菜单</nav></body></html>",
                                                 pageURL: pageURL, rule: ExtractionRule(kind: .generic))
            }
            expectThrowsAny("不支持的选择器失败") {
                try CSSSelector.validate("div:nth-child(2)")
            }

            let generic = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL,
                                                       rule: ExtractionRule(kind: .generic))
            check(generic.markdown.contains("第一段正文"), "通用提取正文")
            check(!generic.markdown.contains("首页"), "通用提取排除导航")

            // 带空格的子组合器 `div > p` 不能退化成后代选择器。
            let nestedHTML = """
            <html><body><div><p>直接子</p><section><p>深层后代</p></section></div></body></html>
            """
            let nested = HTMLParser.parse(nestedHTML)
            let directChildren = try CSSSelector.matches(selector: "div > p", in: nested)
            checkEqual(directChildren.count, 1, "子组合器只匹配直接子节点")
            checkEqual(directChildren.first?.textContent, "直接子", "子组合器命中正确节点")
            let descendants = try CSSSelector.matches(selector: "div p", in: nested)
            checkEqual(descendants.count, 2, "后代选择器仍匹配所有后代")

            // 实体解码必须有界：大量裸 & 不能退化成 O(n²) 或吞掉字符。
            checkEqual(HTMLParser.decodeEntities("a &amp; b"), "a & b", "实体解码")
            let bareAmpersands = String(repeating: "&", count: 20_000)
            checkEqual(HTMLParser.decodeEntities(bareAmpersands), bareAmpersands, "裸 & 原样保留")

            // 不可信页面可以有上千层嵌套：解析深度必须有上限，否则递归遍历会爆栈。
            let deepHTML = String(repeating: "<div>", count: 2000)
                + "x"
                + String(repeating: "</div>", count: 2000)
            var maxDepth = 0
            var pending: [(HTMLNode, Int)] = [(HTMLParser.parse(deepHTML), 0)]
            while let (node, depth) = pending.popLast() {
                maxDepth = max(maxDepth, depth)
                for child in node.children {
                    pending.append((child, depth + 1))
                }
            }
            check(maxDepth <= HTMLParser.maxDepth, "解析嵌套深度有上限")

            let table = try ExtractorFactory.extract(
                html: "<html><body><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table></body></html>",
                pageURL: pageURL,
                rule: ExtractionRule(kind: .css, cssSelector: "table"))
            check(table.markdown.contains("| A | B |"), "表格表头")
            check(table.markdown.contains("| --- | --- |"), "表格分隔行")
        } catch {
            failures += 1
            print("FAIL extraction tests threw: \(error)")
        }
    }

    // MARK: Memory

    private func testMemory() {
        let now = Date()
        let samples = [
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false,
                                 isPinned: false, lastVisibleAt: now.addingTimeInterval(-100)),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false,
                                 isPinned: false, lastVisibleAt: now.addingTimeInterval(-200)),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: true,
                                 isPinned: false, lastVisibleAt: now.addingTimeInterval(-300)),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false,
                                 isPinned: true, lastVisibleAt: now.addingTimeInterval(-400)),
        ]
        let plan = MemoryGovernor.plan(samples: samples,
                                        mode: .precise(budgetBytes: MemoryGovernor.dynamicBudgetBytes))
        checkEqual(plan.evict, [samples[1].bookmarkID, samples[0].bookmarkID], "精确模式按 LRU 淘汰")
        check(plan.overage.isEmpty, "淘汰后不超预算")
        checkEqual(plan.totalFootprint, 800_000_000, "可见与固定实例不被回收")

        let overageSamples = [
            InstanceMemorySample(bookmarkID: UUID(), footprint: 700_000_000, isVisible: true,
                                 isPinned: false, lastVisibleAt: now),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 600_000_000, isVisible: false,
                                 isPinned: true, lastVisibleAt: now),
        ]
        let overage = MemoryGovernor.plan(samples: overageSamples,
                                          mode: .precise(budgetBytes: MemoryGovernor.dynamicBudgetBytes))
        check(overage.evict.isEmpty, "无淘汰对象时不强制回收")
        checkEqual(overage.overage, [overageSamples[0].bookmarkID, overageSamples[1].bookmarkID],
                   "超限提示按占用排序")
        checkEqual(overage.reason, .overBudget, "超限原因")

        var visibleSamples: [InstanceMemorySample] = []
        for _ in 0..<5 {
            visibleSamples.append(InstanceMemorySample(bookmarkID: UUID(), footprint: 100,
                                                       isVisible: true, isPinned: false, lastVisibleAt: now))
        }
        let under = MemoryGovernor.plan(samples: visibleSamples,
                                        mode: .degraded(instanceLimit: 6, pressure: .normal))
        check(under.evict.isEmpty, "实例数未超上限时不回收")

        let degradedOver = MemoryGovernor.plan(samples: visibleSamples,
                                               mode: .degraded(instanceLimit: 4, pressure: .normal))
        check(degradedOver.evict.isEmpty, "降级模式可见实例豁免")
        checkEqual(degradedOver.reason, .instanceLimit, "降级模式实例上限触发")
        checkEqual(degradedOver.overage.count, 5, "全部可见时列出超限对象")

        let pinned = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: false, isPinned: true,
                                          lastVisibleAt: now.addingTimeInterval(-500))
        let visible = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: true, isPinned: false,
                                           lastVisibleAt: now.addingTimeInterval(-400))
        let old = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: false, isPinned: false,
                                       lastVisibleAt: now.addingTimeInterval(-300))
        let recent = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: false, isPinned: false,
                                          lastVisibleAt: now.addingTimeInterval(-100))
        let degradedLRU = MemoryGovernor.plan(samples: [pinned, visible, old, recent],
                                              mode: .degraded(instanceLimit: 2, pressure: .normal))
        checkEqual(degradedLRU.evict, [old.bookmarkID, recent.bookmarkID], "降级模式 LRU 跳过固定与可见")

        let critical = MemoryGovernor.plan(samples: [pinned, visible, old, recent],
                                            mode: .degraded(instanceLimit: 4, pressure: .critical))
        checkEqual(critical.evict, [old.bookmarkID, recent.bookmarkID], "内存压力触发淘汰")
        checkEqual(critical.reason, .memoryPressure, "压力淘汰原因")

        // 常驻巡检间隔：没实例低频空转，超限/压力回到 2 秒，正常 5 秒。
        let idlePlan = MemoryGovernor.plan(samples: [], mode: .precise(budgetBytes: 1024))
        checkEqual(MemoryGovernor.sampleInterval(sampleCount: 0,
                                                  mode: .precise(budgetBytes: 1024),
                                                  plan: idlePlan), 30, "无实例时低频巡检")
        checkEqual(MemoryGovernor.sampleInterval(sampleCount: 1,
                                                  mode: .precise(budgetBytes: MemoryGovernor.dynamicBudgetBytes),
                                                  plan: under), 5, "正常状态 5 秒巡检")
        checkEqual(MemoryGovernor.sampleInterval(sampleCount: visibleSamples.count,
                                                  mode: .degraded(instanceLimit: 4, pressure: .normal),
                                                  plan: degradedOver), 2, "有超限动作时回到 2 秒")
        checkEqual(MemoryGovernor.sampleInterval(sampleCount: 2,
                                                  mode: .degraded(instanceLimit: 4, pressure: .warning),
                                                  plan: under), 2, "内存压力时回到 2 秒")

        // 默认进程池共享 WebContent：同一 pid 的进程级 footprint 只能计一次。
        let shared = [
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false,
                                 isPinned: false, lastVisibleAt: now, processIdentifier: 100),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false,
                                 isPinned: false, lastVisibleAt: now.addingTimeInterval(-10),
                                 processIdentifier: 100),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 100_000_000, isVisible: false,
                                 isPinned: false, lastVisibleAt: now, processIdentifier: 200),
        ]
        let sharedPlan = MemoryGovernor.plan(samples: shared,
                                             mode: .precise(budgetBytes: MemoryGovernor.dynamicBudgetBytes))
        checkEqual(sharedPlan.totalFootprint, 500_000_000, "共享进程内存只计一次")
        check(sharedPlan.evict.isEmpty, "不因重复计数误杀实例")
    }

    // MARK: Site matcher

    private func testSiteMatcher() {
        checkEqual(SiteMatcher.registrableDomain("www.example.com"), "example.com", "常规二级域归一")
        checkEqual(SiteMatcher.registrableDomain("news.example.co.uk"), "example.co.uk", "多段后缀归一")
        checkEqual(SiteMatcher.registrableDomain("127.0.0.1"), "127.0.0.1", "IPv4 原样返回")
        checkEqual(SiteMatcher.registrableDomain("Example.COM:8080"), "example.com", "去端口并小写")
        checkEqual(SiteMatcher.normalizedHost("2001:0db8:0000:0000:0000:0000:0000:0001"),
                   "2001:0db8:0000:0000:0000:0000:0000:0001",
                   "无压缩写法的 IPv6 不应被当作端口剥离")
        checkEqual(SiteMatcher.normalizedHost("[::1]:8080"), "[::1]", "带括号 IPv6 去端口")
        checkEqual(SiteMatcher.normalizedHost("localhost:8080"), "localhost", "主机名去端口")
        checkEqual(SiteMatcher.registrableDomain("2001:db8::1"), "2001:db8::1", "IPv6 原样返回")

        check(SiteMatcher.isSameSite(URL(string: "https://a.example.com/x")!,
                                     URL(string: "http://b.example.com/y")!), "子域与协议差异视为同站")
        check(!SiteMatcher.isSameSite(URL(string: "https://example.com")!,
                                      URL(string: "https://example.org")!), "不同站点不同站")
        check(!SiteMatcher.isSameSite(URL(string: "http://127.0.0.1:8000")!,
                                      URL(string: "http://127.0.0.2:8000")!), "不同 IP 不同站")
        check(SiteMatcher.isSameSite(nil, nil), "空地址视为同站（内部打开）")
    }

    // MARK: Concurrency limiter

    private actor Counter {
        private(set) var current = 0
        private(set) var peak = 0
        func begin() {
            current += 1
            peak = max(peak, current)
        }
        func end() { current -= 1 }
    }

    private func testConcurrencyLimiter() async {
        let limiter = ConcurrencyLimiter(limit: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await limiter.withSlot {
                        await counter.begin()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        await counter.end()
                    }
                }
            }
        }
        let peak = await counter.peak
        check(peak <= 2, "并发限制不超过上限，实际 \(peak)")
        checkEqual(peak, 2, "并发限制应达到上限")
    }

    // MARK: Dynamic concurrency limit

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    private func testConcurrencyLimiterDynamicLimit() async {
        let limiter = ConcurrencyLimiter(limit: 2)
        await limiter.acquire()
        await limiter.acquire()
        await limiter.setLimit(1)

        let flag = Flag()
        let waiter = Task {
            await limiter.acquire()
            await flag.set()
            await limiter.release()
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        var started = await flag.isSet
        check(!started, "上限下调后不应放行新任务")

        await limiter.release()
        try? await Task.sleep(nanoseconds: 60_000_000)
        started = await flag.isSet
        check(!started, "释放一个槽后仍需满足新上限")

        await limiter.release()
        try? await Task.sleep(nanoseconds: 60_000_000)
        started = await flag.isSet
        check(started, "出现空闲槽后放行等待者")
        _ = await waiter.value
    }

    // MARK: Site metadata

    private func testSiteMetadata() {
        let html = """
        <html><head><title> 示例站点 </title>
        <link rel="icon" href="/favicon-32.png">
        <link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">
        <link rel="stylesheet" href="/style.css">
        </head><body><h1>正文标题</h1></body></html>
        """
        checkEqual(SiteMetadata.title(inHTML: html), "示例站点", "提取 title 并去空白")
        let base = URL(string: "https://example.com/a/b")!
        let urls = SiteMetadata.iconURLs(inHTML: html, baseURL: base)
        checkEqual(urls.count, 2, "只收录 rel 含 icon 的 link")
        checkEqual(urls.first?.absoluteString, "https://example.com/favicon-32.png", "相对图标地址按根路径解析")
        checkEqual(urls.last?.absoluteString, "https://cdn.example.com/touch.png", "绝对图标地址保留")
        checkEqual(SiteMetadata.title(inHTML: "<html><body><h1>只有 H1</h1></body></html>"), "只有 H1", "无 title 时回退 h1")
        check(SiteMetadata.title(inHTML: "<html><body></body></html>") == nil, "无标题返回 nil")

        var bookmark = Bookmark(name: "占位名", entryURL: "https://example.com")
        checkEqual(bookmark.displayTitle, "占位名", "无站点标题时用名称")
        bookmark.siteTitle = "站点标题"
        checkEqual(bookmark.displayTitle, "站点标题", "有站点标题时优先显示")
        bookmark.siteTitle = "   "
        checkEqual(bookmark.displayTitle, "占位名", "空站点标题回退名称")

        let url = URL(string: "https://example.com/a/b")!
        checkEqual(BookmarkValidation.resolvedName("  ", url: url), "example.com", "名称为空回退主机名")
        checkEqual(BookmarkValidation.resolvedName(" 自定义 ", url: url), "自定义", "名称为空以外的输入原样使用")
        check(BookmarkValidation.errorMessage(name: "", entryURL: "https://example.com") == nil,
              "仅填 URL 即可保存（名称不再是必填）")
    }

    // MARK: Data directory

    private func testDataDirectory() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MembrowDataDirTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let legacy = base.appendingPathComponent(DataDirectory.legacyFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: legacy.appendingPathComponent("library.json"))

            let resolved = try DataDirectory.resolve(base: base, folderName: "com.example.app")
            checkEqual(resolved.lastPathComponent, "com.example.app", "默认目录以 bundle id 命名")
            check(FileManager.default.fileExists(atPath: resolved.appendingPathComponent("library.json").path),
                  "旧目录内容被迁移到新目录")
            check(!FileManager.default.fileExists(atPath: legacy.path), "迁移后旧目录不再保留")

            try Data("new".utf8).write(to: resolved.appendingPathComponent("settings.json"))
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("legacy".utf8).write(to: legacy.appendingPathComponent("old.json"))

            let again = try DataDirectory.resolve(base: base, folderName: "com.example.app")
            checkEqual(again.path, resolved.path, "重复解析返回同一目录")
            let settings = try String(contentsOf: again.appendingPathComponent("settings.json"), encoding: .utf8)
            checkEqual(settings, "new", "已有数据不被覆盖")
            check(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("old.json").path),
                  "新目录已存在时保留旧目录")
        } catch {
            failures += 1
            print("FAIL 数据目录测试失败：\(error)")
        }
    }

    // MARK: Settings compatibility

    private func testSettingsCompatibility() {
        checkEqual(AppSettings().memoryBudgetMB, 1024, "默认内存预算 1024MB")
        checkEqual(AppSettings().memoryBudgetBytes, 1024 * 1024 * 1024, "默认预算换算为 1GB")
        checkEqual(AppSettings().launchAtLogin, false, "默认不随登录启动")

        var settings = AppSettings()
        settings.memoryBudgetMB = 0
        settings.normalize()
        checkEqual(settings.memoryBudgetMB, 128, "内存预算下限 128MB")
        settings.memoryBudgetMB = 100_000
        settings.normalize()
        checkEqual(settings.memoryBudgetMB, 8192, "内存预算上限 8192MB")

        // 旧版本 settings.json 缺少新字段时必须仍能读取，否则整份设置会退回默认值。
        let legacy = """
        {"globalProxy":{"mode":"direct","host":"","port":0},"startupPolicy":"resumeLast","staticConcurrency":3,"globalTTLMinutes":60}
        """
        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
            checkEqual(decoded.memoryBudgetMB, 1024, "旧配置缺字段时回退默认预算")
            checkEqual(decoded.startupPolicy, .resumeLast, "旧配置已有字段保留")
            checkEqual(decoded.staticConcurrency, 3, "旧配置数值保留")
            checkEqual(decoded.maxInstancesWhenDegraded, 4, "缺失字段回退默认值")
            checkEqual(decoded.microphoneEnabled, true, "旧配置缺字段时默认允许麦克风")
            checkEqual(decoded.launchAtLogin, false, "旧配置缺字段时默认不开机自启")
        } catch {
            failures += 1
            print("FAIL 旧版 settings.json 解码失败：\(error)")
        }

        let muted = """
        {"microphoneEnabled":false}
        """
        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(muted.utf8))
            checkEqual(decoded.microphoneEnabled, false, "显式禁止麦克风的设置被保留")
        } catch {
            failures += 1
            print("FAIL 麦克风设置解码失败：\(error)")
        }

        // 上一版保存过 developerMode 的 settings.json 仍能读取（新版本忽略该键）。
        let obsolete = """
        {"developerMode":true,"launchAtLogin":true}
        """
        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(obsolete.utf8))
            checkEqual(decoded.launchAtLogin, true, "旧版 developerMode 键不影响设置读取")
        } catch {
            failures += 1
            print("FAIL 含旧 developerMode 键的设置解码失败：\(error)")
        }

        let autoStart = """
        {"launchAtLogin":true}
        """
        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(autoStart.utf8))
            checkEqual(decoded.launchAtLogin, true, "显式开启的开机自启被保留")
        } catch {
            failures += 1
            print("FAIL 开机自启设置解码失败：\(error)")
        }

        checkEqual(PageAppearance.dark.displayName, "深色模式", "深色模式显示名")
        let legacyBookmark = """
        {"id":"6C7C3908-57C9-4A37-9B9C-25B9F8E4D7A1","name":"Example","entryURL":"https://example.com","kind":"dynamic","blockingEnabled":true,"dynamicConfig":{"isPinned":false},"staticConfig":{}}
        """
        do {
            let decoded = try JSONDecoder().decode(Bookmark.self, from: Data(legacyBookmark.utf8))
            checkEqual(decoded.effectivePageAppearance, .dark, "旧收藏缺字段时默认深色")
            checkEqual(decoded.pageAppearance, nil, "旧收藏不写入页面外观")
        } catch {
            failures += 1
            print("FAIL 旧版收藏解码失败：\(error)")
        }

        let lightBookmark = """
        {"id":"6C7C3908-57C9-4A37-9B9C-25B9F8E4D7A1","name":"Example","entryURL":"https://example.com","kind":"dynamic","blockingEnabled":true,"dynamicConfig":{"isPinned":false,"pageAppearance":"system"},"staticConfig":{}}
        """
        do {
            let decoded = try JSONDecoder().decode(Bookmark.self, from: Data(lightBookmark.utf8))
            checkEqual(decoded.effectivePageAppearance, .system, "显式页面默认被保留")
        } catch {
            failures += 1
            print("FAIL 页面默认外观解码失败：\(error)")
        }

        let darkBookmark = """
        {"id":"6C7C3908-57C9-4A37-9B9C-25B9F8E4D7A1","name":"Example","entryURL":"https://example.com","kind":"dynamic","blockingEnabled":true,"dynamicConfig":{"isPinned":false,"pageAppearance":"dark"},"staticConfig":{}}
        """
        do {
            let decoded = try JSONDecoder().decode(Bookmark.self, from: Data(darkBookmark.utf8))
            checkEqual(decoded.effectivePageAppearance, .dark, "收藏级深色外观被保留")
        } catch {
            failures += 1
            print("FAIL 收藏页面外观解码失败：\(error)")
        }

        check(ForcedDarkStyle.css.contains("invert(1) hue-rotate(180deg)"), "强制深色样式包含反色")
        check(ForcedDarkStyle.css.contains("img, video, picture, canvas"), "强制深色样式保护位图与视频")
    }

    // MARK: Credential scripts

    private func testCredentialScripts() {
        checkEqual(CredentialScript.jsonLiteral("a\"b\nc"), "\"a\\\"b\\nc\"", "凭据按 JSON 规则转义")

        let trickyUser = "user\"name\\x"
        let trickyPassword = "p|w\"d\\1"
        let fill = CredentialScript.fill(username: trickyUser, password: trickyPassword)
        check(fill.contains(CredentialScript.jsonLiteral(trickyUser)), "用户名以 JSON 字面量嵌入填充脚本")
        check(fill.contains(CredentialScript.jsonLiteral(trickyPassword)), "密码以 JSON 字面量嵌入填充脚本")
        check(CredentialScript.capture.contains(CredentialScript.handlerName), "捕获脚本使用正确的消息处理器名")
        check(!CredentialScript.capture.contains("document.cookie"), "捕获脚本不读取 Cookie")
        check(CredentialScript.fill(username: "u", password: "p").contains("password.value"),
              "填充前检查密码框是否已有内容")
    }

    // MARK: Data recovery and decoding

    private func testDataRecovery() async {
        // 损坏的 library.json：必须备份原文件，不能在下一次持久化时被空库覆盖。
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MembrowSelfTest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { cleanup(directory) }

            let broken = "{\"bookmarks\":[{\"id\":\"not-a-uuid\"}"
            try Data(broken.utf8).write(to: directory.appendingPathComponent("library.json"))

            let store = try AppStore(directory: directory)
            check(!store.loadWarnings.isEmpty, "损坏的 library.json 产生读取告警")
            check(store.library.bookmarks.isEmpty, "损坏时以空库继续运行")

            let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("library.json.corrupt-") }
            checkEqual(backups.count, 1, "损坏文件被改名备份")

            _ = try? store.createBookmark(name: "新收藏", entryURL: "https://example.com", kind: .dynamic)
            let backupText = try String(contentsOf: directory.appendingPathComponent(backups[0]),
                                        encoding: .utf8)
            checkEqual(backupText, broken, "备份保留原始内容，不被空库覆盖")
        } catch {
            failures += 1
            print("FAIL data recovery tests threw: \(error)")
        }

        // 旧数据缺 minutes 键时不能拖垮整份 library.json。
        do {
            let ttl = try JSONDecoder().decode(TTLPolicy.self, from: Data("{\"kind\":\"minutes\"}".utf8))
            checkEqual(ttl.normalized, .noCache, "TTL 缺 minutes 时回落为不使用缓存")
        } catch {
            failures += 1
            print("FAIL TTL 缺字段解码失败：\(error)")
        }

        // sessions.json 里的越界分割比例在解码时被夹紧。
        do {
            let split = PaneSplit(axis: .vertical,
                                  ratio: 0.5,
                                  first: .pane(Pane()),
                                  second: .pane(Pane()))
            let encoded = try JSONEncoder().encode(split)
            if let text = String(data: encoded, encoding: .utf8),
               let tampered = text.replacingOccurrences(of: "\"ratio\":0.5", with: "\"ratio\":5")
                   .data(using: .utf8) {
                let decoded = try JSONDecoder().decode(PaneSplit.self, from: tampered)
                checkEqual(decoded.ratio, 0.9, "解码时夹紧分割比例")
            } else {
                failures += 1
                print("FAIL 无法构造越界 ratio 的 sessions.json")
            }
        } catch {
            failures += 1
            print("FAIL PaneSplit 解码失败：\(error)")
        }

        // meta charset 必须优先于 GB18030 兜底，否则 Big5/Latin1 页面会静默变乱码。
        var latin = Data("<html><head><meta charset=\"iso-8859-1\"></head><body>caf".utf8)
        latin.append(0xE9)
        latin.append(contentsOf: Data("</body></html>".utf8))
        let decoded = HTTPTextDecoder.decode(data: latin, charset: nil)
        check(decoded?.contains("café") == true, "按 meta charset 解码非 UTF-8 页面")
    }

    // MARK: Diagnostics

    private func testDiagnosticLog() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MembrowLogTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLog(directory: directory, maxFileBytes: 512)
        log.info("页面加载完成", category: "web", fields: ["url": "https://example.com/a"])
        log.warn("HTTP 404", category: "http", fields: ["status": "404"])
        log.error("导航失败", category: "web", fields: ["code": "-1009"])
        log.flush()

        let infoURL = directory.appendingPathComponent(DiagnosticLog.infoFileName)
        let problemURL = directory.appendingPathComponent(DiagnosticLog.problemFileName)
        let infoLines = readLines(infoURL)
        let problemLines = readLines(problemURL)
        checkEqual(infoLines.count, 1, "info 单独写入 info.jsonl")
        checkEqual(problemLines.count, 2, "warn 与 error 合并进 problems.jsonl")
        checkEqual(jsonField(problemLines.first, "level"), "warn", "warn 行级别")
        checkEqual(jsonField(problemLines.last, "level"), "error", "error 行级别")
        checkEqual(jsonField(infoLines.first, "message"), "页面加载完成", "日志保留消息文本")
        if let line = problemLines.first.flatMap({ $0.data(using: .utf8) }),
           let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let fields = object["fields"] as? [String: String] {
            checkEqual(fields["status"], "404", "结构化字段写入 fields")
        } else {
            failures += 1
            print("FAIL 日志行不是合法 JSON 对象")
        }

        // 超过单文件上限后轮转：旧内容进 .1，当前文件重新从 0 开始。
        for index in 0..<20 {
            log.info("填充第 \(index) 条日志用于触发轮转", category: "test")
        }
        log.flush()
        check(FileManager.default.fileExists(atPath: infoURL.appendingPathExtension("1").path),
              "超过上限后生成 info.jsonl.1")
        let size = fileSize(infoURL)
        check(size <= 512, "当前 info.jsonl 不超过上限，实际 \(size) 字节")
        check(readLines(infoURL).allSatisfy { $0.contains("\"level\":\"info\"") },
              "轮转后当前文件只含 info 记录")
    }

    private func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else { return -1 }
        return size
    }

    private func jsonField(_ line: String?, _ key: String) -> String? {
        guard let line, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    // MARK: Validation edges

    private func testSettingsEdges() async {
        check(ProxySettings(mode: .custom, host: "127.0.0.1:8080", port: 8080).validationError != nil,
              "代理地址自带端口应被拒绝")
        check(ProxySettings(mode: .custom, host: "::1", port: 8080).isValid, "IPv6 代理地址可用")
        check(ProxySettings(mode: .custom, host: "[::1]", port: 8080).isValid, "带括号 IPv6 代理地址可用")

        do {
            let (store, directory) = try makeStore()
            defer { cleanup(directory) }

            let bookmark = try store.createBookmark(name: "启动",
                                                    entryURL: "https://start.example.com",
                                                    kind: .dynamic)
            try store.setStartupPolicy(.openBookmark, bookmarkID: bookmark.id)
            checkEqual(store.settings.startupBookmarkID, bookmark.id, "启动收藏已保存")

            store.deleteBookmark(id: bookmark.id)
            checkEqual(store.settings.startupBookmarkID, nil, "删除启动收藏后清除绑定")
            checkEqual(store.settings.startupPolicy, .doNotRestore, "回退到不恢复，避免设置无法保存")
            try store.updateSettings(store.settings)
        } catch {
            failures += 1
            print("FAIL settings edge tests threw: \(error)")
        }
    }
}

@MainActor
func runSelfTest() async -> Int {
    let harness = Harness()
    await harness.run()
    return harness.failures == 0 ? 0 : 1
}

exit(Int32(await runSelfTest()))
