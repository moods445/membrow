import Foundation

// MARK: - Bookmark kind

public enum BookmarkKind: String, Codable, CaseIterable, Sendable {
    case dynamic
    case staticPage = "static"

    public var displayName: String {
        switch self {
        case .dynamic: return "动态"
        case .staticPage: return "静态"
        }
    }
}

// MARK: - Proxy

public struct ProxySettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case direct
        case system
        case custom
    }

    public var mode: Mode
    public var host: String
    public var port: Int

    public init(mode: Mode = .direct, host: String = "", port: Int = 0) {
        self.mode = mode
        self.host = host
        self.port = port
    }

    public var validationError: String? {
        switch mode {
        case .direct, .system:
            return nil
        case .custom:
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedHost.isEmpty {
                return "代理地址不能为空"
            }
            if trimmedHost.contains("/") || trimmedHost.contains(" ") {
                return "代理地址只能是主机名或 IP"
            }
            // IPv6 字面量至少两个冒号；单冒号必然是“主机:端口”，端口应单独填写。
            if trimmedHost.filter({ $0 == ":" }).count == 1 {
                return "代理地址不要包含端口，请在端口栏填写"
            }
            if port < 1 || port > 65535 {
                return "端口必须在 1–65535 之间"
            }
            return nil
        }
    }

    public var isValid: Bool { validationError == nil }

    public var normalized: ProxySettings {
        var copy = self
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    public var displayName: String {
        switch mode {
        case .direct:
            return "直连"
        case .system:
            return "系统代理"
        case .custom:
            return "自定义 HTTP (\(host):\(port))"
        }
    }
}

// MARK: - Static capture

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case webView
    case http

    public var displayName: String {
        switch self {
        case .webView: return "WebView（默认）"
        case .http: return "HTTP（不执行 JS）"
        }
    }

    public var limitationNote: String? {
        switch self {
        case .webView: return nil
        case .http: return "不执行 JavaScript，不适用于依赖 JS 渲染正文的站点。"
        }
    }
}

/// 静态收藏的展示方式：Markdown 正文（默认）或精简快照（保留原站布局，禁用 JS）。
public enum StaticDisplayMode: String, Codable, CaseIterable, Sendable {
    case markdown
    case snapshot

    /// 默认展示方式：精简快照（保留原布局，禁用 JS）。
    public static let preferred: StaticDisplayMode = .snapshot

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown 正文"
        case .snapshot: return "精简快照（默认）"
        }
    }

    public var note: String? {
        switch self {
        case .markdown: return nil
        case .snapshot: return "快照去掉脚本、事件与表单，保留样式布局，渲染时禁用 JS。"
        }
    }
}

public enum TTLPolicy: Equatable, Codable, Sendable {
    case inherit
    case noCache
    case neverExpires
    case minutes(Int)

    public var kind: String {
        switch self {
        case .inherit: return "inherit"
        case .noCache: return "noCache"
        case .neverExpires: return "neverExpires"
        case .minutes: return "minutes"
        }
    }

    public var displayName: String {
        switch self {
        case .inherit: return "继承全局"
        case .noCache: return "不使用缓存"
        case .neverExpires: return "永不过期"
        case .minutes(let value): return "\(value) 分钟"
        }
    }

    public var normalized: TTLPolicy {
        if case .minutes(let value) = self, value <= 0 {
            return .noCache
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case minutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "noCache":
            self = .noCache
        case "neverExpires":
            self = .neverExpires
        case "minutes":
            // 缺 minutes 键时回落 0（normalized 后为 noCache），避免整份 library.json 解码失败。
            self = .minutes(try container.decodeIfPresent(Int.self, forKey: .minutes) ?? 0)
        default:
            self = .inherit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit:
            try container.encode("inherit", forKey: .kind)
        case .noCache:
            try container.encode("noCache", forKey: .kind)
        case .neverExpires:
            try container.encode("neverExpires", forKey: .kind)
        case .minutes(let value):
            try container.encode("minutes", forKey: .kind)
            try container.encode(value, forKey: .minutes)
        }
    }
}

public enum ExtractionKind: String, Codable, CaseIterable, Sendable {
    /// 整页按原布局转换：无需配置选择器，静态收藏默认方式。
    case fullPage
    case generic
    case css

    public var displayName: String {
        switch self {
        case .fullPage: return "整页转换（默认）"
        case .generic: return "通用正文提取"
        case .css: return "CSS 选择器"
        }
    }
}

public struct ExtractionRule: Codable, Equatable, Sendable {
    public var kind: ExtractionKind
    public var cssSelector: String
    /// 可选：抓取时等待该选择器出现，未配置则页面加载完成后直接提取。
    public var waitSelector: String

    public init(kind: ExtractionKind = .fullPage, cssSelector: String = "", waitSelector: String = "") {
        self.kind = kind
        self.cssSelector = cssSelector
        self.waitSelector = waitSelector
    }

    public var trimmedCSSSelector: String {
        cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedWaitSelector: String {
        waitSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Bookmark

/// 网页强制外观：默认跟随页面，或强制深色。
public enum PageAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case dark

    public var displayName: String {
        switch self {
        case .system: return "页面默认"
        case .dark: return "深色模式"
        }
    }
}

/// 强制深色的注入样式：只含 CSS，不改 DOM、不执行 JS。
public enum ForcedDarkStyle {
    // ponytail: html 上的 filter 会改变 fixed 元素的包含块，少数依赖 fixed 布局的页面可能偏移；
    // 这是“对没有深色样式的站点强制变暗”的固有代价。内联 SVG 不反回，避免黑色图标在黑底上消失。
    public static let css = """
    html {
      background: #fff !important;
      filter: invert(1) hue-rotate(180deg) !important;
    }
    img, video, picture, canvas {
      filter: invert(1) hue-rotate(180deg) !important;
    }
    """
}

/// 动态收藏的专属配置（切换到静态时保留但不生效）。
public struct DynamicConfig: Codable, Equatable, Sendable {
    public var isPinned: Bool
    /// 页面外观；nil 表示旧数据未配置，按默认“深色模式”处理。
    public var pageAppearance: PageAppearance?

    public init(isPinned: Bool = false, pageAppearance: PageAppearance? = nil) {
        self.isPinned = isPinned
        self.pageAppearance = pageAppearance
    }
}

/// 静态收藏的专属配置（切换到动态时保留但不生效）。
public struct StaticConfig: Codable, Equatable, Sendable {
    public var captureMode: CaptureMode
    public var ttl: TTLPolicy
    public var extraction: ExtractionRule
    public var displayMode: StaticDisplayMode

    public init(captureMode: CaptureMode = .webView,
                ttl: TTLPolicy = .inherit,
                extraction: ExtractionRule = ExtractionRule(),
                displayMode: StaticDisplayMode = StaticDisplayMode.preferred) {
        self.captureMode = captureMode
        self.ttl = ttl
        self.extraction = extraction
        self.displayMode = displayMode
    }

    private enum CodingKeys: String, CodingKey {
        case captureMode, ttl, extraction, displayMode
    }

    /// 逐字段 `decodeIfPresent`：旧 `library.json` 没有 displayMode 时回落到默认展示方式。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .webView
        ttl = try container.decodeIfPresent(TTLPolicy.self, forKey: .ttl) ?? .inherit
        extraction = try container.decodeIfPresent(ExtractionRule.self, forKey: .extraction) ?? ExtractionRule()
        displayMode = try container.decodeIfPresent(StaticDisplayMode.self, forKey: .displayMode)
            ?? StaticDisplayMode.preferred
    }
}

public struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var entryURL: String
    public var kind: BookmarkKind
    public var lastURL: String?
    /// 自动抓取的站点标题（用户重命名后清空，避免覆盖自定义名称）。
    public var siteTitle: String?
    public var groupID: UUID?
    /// nil 表示继承全局代理。
    public var proxy: ProxySettings?
    public var blockingEnabled: Bool
    public var dynamicConfig: DynamicConfig
    public var staticConfig: StaticConfig

    public init(id: UUID = UUID(),
                name: String,
                entryURL: String,
                kind: BookmarkKind = .dynamic,
                lastURL: String? = nil,
                siteTitle: String? = nil,
                groupID: UUID? = nil,
                proxy: ProxySettings? = nil,
                blockingEnabled: Bool = true,
                dynamicConfig: DynamicConfig = DynamicConfig(),
                staticConfig: StaticConfig = StaticConfig()) {
        self.id = id
        self.name = name
        self.entryURL = entryURL
        self.kind = kind
        self.lastURL = lastURL
        self.siteTitle = siteTitle
        self.groupID = groupID
        self.proxy = proxy
        self.blockingEnabled = blockingEnabled
        self.dynamicConfig = dynamicConfig
        self.staticConfig = staticConfig
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 左栏与详情标题：优先自动抓取的站点标题，缺失时回退用户名称。
    public var displayTitle: String {
        if let siteTitle, !siteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return siteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmedName
    }

    public var entryURLValue: URL? {
        BookmarkValidation.url(from: entryURL)
    }

    public var lastURLValue: URL? {
        lastURL.flatMap(BookmarkValidation.url(from:))
    }

    public var isPinned: Bool {
        get { dynamicConfig.isPinned }
        set { dynamicConfig.isPinned = newValue }
    }

    /// 页面外观：存放在动态配置里，静态收藏保留但不用。
    public var pageAppearance: PageAppearance? {
        get { dynamicConfig.pageAppearance }
        set { dynamicConfig.pageAppearance = newValue }
    }

    /// 页面外观取值：默认强制深色；旧数据未配置时也按深色处理。
    public var effectivePageAppearance: PageAppearance {
        pageAppearance ?? .dark
    }
}

public enum BookmarkValidation {
    public static func url(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /// 名称为空时用主机名占位（站点标题抓取回来后由左栏自动显示真实标题）。
    public static func resolvedName(_ typed: String, url: URL) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? url.absoluteString
    }

    public static func errorMessage(name: String, entryURL: String) -> String? {
        if url(from: entryURL) == nil {
            return "请输入有效的 http 或 https 地址"
        }
        return nil
    }
}

// MARK: - Group

public struct BookmarkGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Library

public struct Library: Codable, Equatable, Sendable {
    public var bookmarks: [Bookmark]
    public var groups: [BookmarkGroup]
    /// 根层顺序：分组 ID 或未分组收藏 ID。
    public var rootOrder: [UUID]
    /// 每个分组内的收藏顺序。
    public var groupOrders: [UUID: [UUID]]

    public init(bookmarks: [Bookmark] = [],
                groups: [BookmarkGroup] = [],
                rootOrder: [UUID] = [],
                groupOrders: [UUID: [UUID]] = [:]) {
        self.bookmarks = bookmarks
        self.groups = groups
        self.rootOrder = rootOrder
        self.groupOrders = groupOrders
        normalize()
    }

    public func bookmark(id: UUID) -> Bookmark? {
        bookmarks.first { $0.id == id }
    }

    public func bookmarkIndex(id: UUID) -> Int? {
        bookmarks.firstIndex { $0.id == id }
    }

    public func group(id: UUID) -> BookmarkGroup? {
        groups.first { $0.id == id }
    }

    public func groupIndex(id: UUID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    /// 收藏在左栏的展示顺序。
    public var orderedBookmarks: [Bookmark] {
        var result: [Bookmark] = []
        for itemID in rootOrder {
            if let groupIndex = groupIndex(id: itemID) {
                let group = groups[groupIndex]
                for bookmarkID in groupOrders[group.id] ?? [] {
                    if let bookmark = bookmark(id: bookmarkID) {
                        result.append(bookmark)
                    }
                }
            } else if let bookmark = bookmark(id: itemID) {
                result.append(bookmark)
            }
        }
        return result
    }

    /// 未分组的收藏按根顺序排列。
    public var ungroupedBookmarks: [Bookmark] {
        rootOrder.compactMap { bookmark(id: $0) }.filter { $0.groupID == nil }
    }

    public func bookmarks(inGroup groupID: UUID) -> [Bookmark] {
        (groupOrders[groupID] ?? []).compactMap { bookmark(id: $0) }
    }

    /// 去除重复、孤立与非法归属，补全顺序。
    public mutating func normalize() {
        // 1. 去重
        var seenBookmarkIDs = Set<UUID>()
        bookmarks = bookmarks.filter { seenBookmarkIDs.insert($0.id).inserted }
        var seenGroupIDs = Set<UUID>()
        groups = groups.filter { seenGroupIDs.insert($0.id).inserted }

        // 2. 非法的分组归属降级为未分组
        let validGroupIDs = Set(groups.map(\.id))
        for index in bookmarks.indices {
            if let groupID = bookmarks[index].groupID, !validGroupIDs.contains(groupID) {
                bookmarks[index].groupID = nil
            }
        }

        // 3. 分组顺序清洗
        var newGroupOrders: [UUID: [UUID]] = [:]
        for group in groups {
            var seen = Set<UUID>()
            var order: [UUID] = []
            for id in groupOrders[group.id] ?? [] {
                if let bookmark = bookmark(id: id), bookmark.groupID == group.id, seen.insert(id).inserted {
                    order.append(id)
                }
            }
            for bookmark in bookmarks where bookmark.groupID == group.id && !seen.contains(bookmark.id) {
                order.append(bookmark.id)
            }
            newGroupOrders[group.id] = order
        }
        groupOrders = newGroupOrders

        // 4. 根顺序清洗
        var seenRootIDs = Set<UUID>()
        var root: [UUID] = []
        for id in rootOrder {
            if seenRootIDs.contains(id) { continue }
            if groupIndex(id: id) != nil {
                root.append(id)
                seenRootIDs.insert(id)
            } else if let bookmark = bookmark(id: id), bookmark.groupID == nil {
                root.append(id)
                seenRootIDs.insert(id)
            }
        }
        for group in groups where !seenRootIDs.contains(group.id) {
            root.append(group.id)
            seenRootIDs.insert(group.id)
        }
        for bookmark in bookmarks where bookmark.groupID == nil && !seenRootIDs.contains(bookmark.id) {
            root.append(bookmark.id)
            seenRootIDs.insert(bookmark.id)
        }
        rootOrder = root
    }

    // MARK: Mutations

    public mutating func insertBookmark(_ bookmark: Bookmark, groupID: UUID?, at index: Int) {
        var bookmark = bookmark
        bookmark.groupID = groupID
        bookmarks.append(bookmark)
        if let groupID, var order = groupOrders[groupID] {
            order.insert(bookmark.id, at: min(max(index, 0), order.count))
            groupOrders[groupID] = order
        } else if let groupID {
            groupOrders[groupID] = [bookmark.id]
        } else {
            rootOrder.insert(bookmark.id, at: min(max(index, 0), rootOrder.count))
        }
        normalize()
    }

    public mutating func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        rootOrder.removeAll { $0 == id }
        for key in groupOrders.keys {
            groupOrders[key]?.removeAll { $0 == id }
        }
        normalize()
    }

    public mutating func moveBookmark(id: UUID, toGroup groupID: UUID?, at index: Int) {
        guard let bookmarkIndex = bookmarkIndex(id: id) else { return }
        let oldGroupID = bookmarks[bookmarkIndex].groupID
        if oldGroupID == groupID {
            // 同一列表内排序
            if let groupID {
                var order = groupOrders[groupID] ?? []
                guard let current = order.firstIndex(of: id) else { return }
                order.remove(at: current)
                let target = min(max(index, 0), order.count)
                order.insert(id, at: target)
                groupOrders[groupID] = order
            } else {
                guard let current = rootOrder.firstIndex(of: id) else { return }
                rootOrder.remove(at: current)
                let target = min(max(index, 0), rootOrder.count)
                rootOrder.insert(id, at: target)
            }
        } else {
            // 跨列表移动：先移除，再插入
            if let oldGroupID {
                groupOrders[oldGroupID]?.removeAll { $0 == id }
            } else {
                rootOrder.removeAll { $0 == id }
            }
            bookmarks[bookmarkIndex].groupID = groupID
            if let groupID {
                var order = groupOrders[groupID] ?? []
                let target = min(max(index, 0), order.count)
                order.insert(id, at: target)
                groupOrders[groupID] = order
            } else {
                let target = min(max(index, 0), rootOrder.count)
                rootOrder.insert(id, at: target)
            }
        }
        normalize()
    }

    public mutating func moveRootItem(id: UUID, to index: Int) {
        if let bookmark = bookmark(id: id), bookmark.groupID != nil {
            moveBookmark(id: id, toGroup: nil, at: index)
            return
        }
        guard let current = rootOrder.firstIndex(of: id) else { return }
        rootOrder.remove(at: current)
        let target = min(max(index, 0), rootOrder.count)
        rootOrder.insert(id, at: target)
        normalize()
    }

    public mutating func insertGroup(_ group: BookmarkGroup, at index: Int) {
        groups.append(group)
        groupOrders[group.id] = []
        let target = min(max(index, 0), rootOrder.count)
        rootOrder.insert(group.id, at: target)
        normalize()
    }

    public mutating func removeGroup(id: UUID) {
        guard let groupIndex = groupIndex(id: id) else { return }
        let childIDs = groupOrders[id] ?? []
        let rootIndex = rootOrder.firstIndex(of: id) ?? rootOrder.count
        groups.remove(at: groupIndex)
        groupOrders[id] = nil
        rootOrder.removeAll { $0 == id }
        for (offset, childID) in childIDs.enumerated() {
            if let bookmarkIndex = bookmarkIndex(id: childID) {
                bookmarks[bookmarkIndex].groupID = nil
                rootOrder.insert(childID, at: min(rootIndex + offset, rootOrder.count))
            }
        }
        normalize()
    }

    public mutating func updateBookmark(_ bookmark: Bookmark) {
        guard let index = bookmarkIndex(id: bookmark.id) else { return }
        let oldGroupID = bookmarks[index].groupID
        bookmarks[index] = bookmark
        if oldGroupID != bookmark.groupID {
            // 归属变更时按规则补全顺序
            if let oldGroupID {
                groupOrders[oldGroupID]?.removeAll { $0 == bookmark.id }
            } else {
                rootOrder.removeAll { $0 == bookmark.id }
            }
            if let newGroupID = bookmark.groupID, groupOrders[newGroupID] != nil {
                groupOrders[newGroupID]?.append(bookmark.id)
            } else if bookmark.groupID == nil {
                rootOrder.append(bookmark.id)
            }
        }
        normalize()
    }
}

// MARK: - Session and panes

public enum SplitAxis: String, Codable, CaseIterable, Sendable {
    /// 上下堆叠。
    case horizontal
    /// 左右并排。
    case vertical

    public var displayName: String {
        switch self {
        case .horizontal: return "水平分割"
        case .vertical: return "竖直分割"
        }
    }
}

public struct Pane: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bookmarkID: UUID?

    public init(id: UUID = UUID(), bookmarkID: UUID? = nil) {
        self.id = id
        self.bookmarkID = bookmarkID
    }
}

public struct PaneSplit: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var axis: SplitAxis
    /// 第一个子节点占比，0.1...0.9。
    public var ratio: Double
    public var first: PaneNode
    public var second: PaneNode

    public init(id: UUID = UUID(),
                axis: SplitAxis,
                ratio: Double = 0.5,
                first: PaneNode,
                second: PaneNode) {
        self.id = id
        self.axis = axis
        self.ratio = Self.clampedRatio(ratio)
        self.first = first
        self.second = second
    }

    private enum CodingKeys: String, CodingKey {
        case id, axis, ratio, first, second
    }

    /// 合成的解码器会绕过 init 的夹紧逻辑，手工编辑/旧版的 sessions.json 可能写入越界比例。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        axis = try container.decode(SplitAxis.self, forKey: .axis)
        ratio = Self.clampedRatio(try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5)
        first = try container.decode(PaneNode.self, forKey: .first)
        second = try container.decode(PaneNode.self, forKey: .second)
    }

    private static func clampedRatio(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.1), 0.9)
    }
}

public indirect enum PaneNode: Codable, Equatable, Sendable {
    case pane(Pane)
    case split(PaneSplit)

    public var allPanes: [Pane] {
        switch self {
        case .pane(let pane):
            return [pane]
        case .split(let split):
            return split.first.allPanes + split.second.allPanes
        }
    }

    public var firstPane: Pane? {
        allPanes.first
    }

    public func pane(id: UUID) -> Pane? {
        allPanes.first { $0.id == id }
    }

    public var isSinglePane: Bool {
        if case .pane = self { return true }
        return false
    }

    public func replacingPane(id: UUID, with replacement: PaneNode) -> PaneNode {
        switch self {
        case .pane(let pane):
            return pane.id == id ? replacement : self
        case .split(var split):
            split.first = split.first.replacingPane(id: id, with: replacement)
            split.second = split.second.replacingPane(id: id, with: replacement)
            return .split(split)
        }
    }

    /// 移除指定 pane，返回替换后的树；若全部移除则为 nil。
    public func removingPane(id: UUID) -> PaneNode? {
        switch self {
        case .pane(let pane):
            return pane.id == id ? nil : self
        case .split(var split):
            let newFirst = split.first.removingPane(id: id)
            let newSecond = split.second.removingPane(id: id)
            if newFirst == nil && newSecond == nil {
                return nil
            }
            if let newFirst, let newSecond {
                split.first = newFirst
                split.second = newSecond
                return .split(split)
            }
            return newFirst ?? newSecond
        }
    }

    public func updatingPane(id: UUID, _ transform: (inout Pane) -> Void) -> PaneNode {
        switch self {
        case .pane(var pane):
            guard pane.id == id else { return self }
            transform(&pane)
            return .pane(pane)
        case .split(var split):
            split.first = split.first.updatingPane(id: id, transform)
            split.second = split.second.updatingPane(id: id, transform)
            return .split(split)
        }
    }

    public func updatingSplit(id: UUID, _ transform: (inout PaneSplit) -> Void) -> PaneNode {
        switch self {
        case .pane:
            return self
        case .split(var split):
            if split.id == id {
                transform(&split)
                split.ratio = min(max(split.ratio, 0.1), 0.9)
                return .split(split)
            }
            split.first = split.first.updatingSplit(id: id, transform)
            split.second = split.second.updatingSplit(id: id, transform)
            return .split(split)
        }
    }

    public func splittingPane(id: UUID, axis: SplitAxis, newPane: Pane = Pane()) -> PaneNode {
        let existingBookmarkID = pane(id: id)?.bookmarkID
        return replacingPane(id: id, with: .split(PaneSplit(axis: axis,
                                                           first: .pane(Pane(id: id, bookmarkID: existingBookmarkID)),
                                                           second: .pane(newPane))))
    }

    /// 删除指定收藏的所有 pane 绑定。
    public func clearingBookmark(id: UUID) -> PaneNode {
        switch self {
        case .pane(var pane):
            if pane.bookmarkID == id { pane.bookmarkID = nil }
            return .pane(pane)
        case .split(var split):
            split.first = split.first.clearingBookmark(id: id)
            split.second = split.second.clearingBookmark(id: id)
            return .split(split)
        }
    }
}

public struct Session: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var root: PaneNode?
    public var focusedPaneID: UUID?
    public var zoomedPaneID: UUID?

    public init(id: UUID = UUID(),
                name: String,
                root: PaneNode? = .pane(Pane()),
                focusedPaneID: UUID? = nil,
                zoomedPaneID: UUID? = nil) {
        self.id = id
        self.name = name
        self.root = root
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
        normalize()
    }

    public var allPanes: [Pane] {
        root?.allPanes ?? []
    }

    public mutating func normalize() {
        guard let root else {
            focusedPaneID = nil
            zoomedPaneID = nil
            return
        }
        if let focused = focusedPaneID, root.pane(id: focused) == nil {
            focusedPaneID = root.firstPane?.id
        }
        if focusedPaneID == nil {
            focusedPaneID = root.firstPane?.id
        }
        if let zoomed = zoomedPaneID, root.pane(id: zoomed) == nil {
            zoomedPaneID = nil
        }
    }

    public mutating func splitPane(id: UUID?, axis: SplitAxis) {
        guard let root else {
            let pane = Pane()
            self.root = .pane(pane)
            focusedPaneID = pane.id
            zoomedPaneID = nil
            return
        }
        let targetID = id ?? focusedPaneID ?? root.firstPane?.id
        guard let targetID, root.pane(id: targetID) != nil else { return }
        let newPane = Pane()
        self.root = root.splittingPane(id: targetID, axis: axis, newPane: newPane)
        focusedPaneID = newPane.id
        if zoomedPaneID == targetID {
            zoomedPaneID = nil
        }
    }

    public mutating func closePane(id: UUID) {
        guard let root else { return }
        self.root = root.removingPane(id: id)
        if focusedPaneID == id {
            focusedPaneID = self.root?.firstPane?.id
        }
        if zoomedPaneID == id {
            zoomedPaneID = nil
        }
        normalize()
    }

    public mutating func assignBookmark(_ bookmarkID: UUID?, to paneID: UUID) {
        guard let root else { return }
        self.root = root.updatingPane(id: paneID) { $0.bookmarkID = bookmarkID }
        normalize()
    }

    public mutating func clearBookmark(_ bookmarkID: UUID) {
        guard let root else { return }
        self.root = root.clearingBookmark(id: bookmarkID)
    }

    public mutating func updateSplitRatio(splitID: UUID, ratio: Double) {
        guard let root else { return }
        self.root = root.updatingSplit(id: splitID) { $0.ratio = ratio }
    }
}

// MARK: - Settings

public enum StartupPolicy: String, Codable, CaseIterable, Sendable {
    case doNotRestore
    case resumeLast
    case openBookmark

    public var displayName: String {
        switch self {
        case .doNotRestore: return "不恢复"
        case .resumeLast: return "继续上次"
        case .openBookmark: return "打开指定收藏"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var globalProxy: ProxySettings
    public var startupPolicy: StartupPolicy
    public var startupBookmarkID: UUID?
    public var lastSessionID: UUID?
    public var maxInstancesWhenDegraded: Int
    public var staticCaptureTimeout: TimeInterval
    public var staticConcurrency: Int
    public var globalTTLMinutes: Int
    /// 动态实例内存预算（MB），默认 1GB。
    public var memoryBudgetMB: Int
    /// 故障注入：模拟私有内存接口不可用。
    public var forceMemoryAPIFailure: Bool
    /// 允许网页使用麦克风。关闭后媒体权限一律拒绝；开启后不再逐站点询问。
    public var microphoneEnabled: Bool
    /// 随登录启动（系统登录项）的意向值；实际是否生效以 `SMAppService.mainApp.status` 为准。
    public var launchAtLogin: Bool

    public init(globalProxy: ProxySettings = ProxySettings(),
                startupPolicy: StartupPolicy = .doNotRestore,
                startupBookmarkID: UUID? = nil,
                lastSessionID: UUID? = nil,
                maxInstancesWhenDegraded: Int = 4,
                staticCaptureTimeout: TimeInterval = 15,
                staticConcurrency: Int = 2,
                globalTTLMinutes: Int = 24 * 60,
                memoryBudgetMB: Int = AppSettings.defaultMemoryBudgetMB,
                forceMemoryAPIFailure: Bool = false,
                microphoneEnabled: Bool = true,
                launchAtLogin: Bool = false) {
        self.globalProxy = globalProxy
        self.startupPolicy = startupPolicy
        self.startupBookmarkID = startupBookmarkID
        self.lastSessionID = lastSessionID
        self.maxInstancesWhenDegraded = maxInstancesWhenDegraded
        self.staticCaptureTimeout = staticCaptureTimeout
        self.staticConcurrency = staticConcurrency
        self.globalTTLMinutes = globalTTLMinutes
        self.memoryBudgetMB = memoryBudgetMB
        self.forceMemoryAPIFailure = forceMemoryAPIFailure
        self.microphoneEnabled = microphoneEnabled
        self.launchAtLogin = launchAtLogin
    }

    public static let staticConcurrencyHardLimit = 4
    public static let defaultMemoryBudgetMB = 1024
    public static let memoryBudgetRange = 128...8192

    private enum CodingKeys: String, CodingKey {
        case globalProxy
        case startupPolicy
        case startupBookmarkID
        case lastSessionID
        case maxInstancesWhenDegraded
        case staticCaptureTimeout
        case staticConcurrency
        case globalTTLMinutes
        case memoryBudgetMB
        case forceMemoryAPIFailure
        case microphoneEnabled
        case launchAtLogin
    }

    /// 逐字段 `decodeIfPresent`：新增字段后旧 settings.json 仍可读取，不会因缺键整份失效。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        globalProxy = try container.decodeIfPresent(ProxySettings.self, forKey: .globalProxy) ?? defaults.globalProxy
        startupPolicy = try container.decodeIfPresent(StartupPolicy.self, forKey: .startupPolicy) ?? defaults.startupPolicy
        startupBookmarkID = try container.decodeIfPresent(UUID.self, forKey: .startupBookmarkID)
        lastSessionID = try container.decodeIfPresent(UUID.self, forKey: .lastSessionID)
        maxInstancesWhenDegraded = try container.decodeIfPresent(Int.self, forKey: .maxInstancesWhenDegraded)
            ?? defaults.maxInstancesWhenDegraded
        staticCaptureTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .staticCaptureTimeout)
            ?? defaults.staticCaptureTimeout
        staticConcurrency = try container.decodeIfPresent(Int.self, forKey: .staticConcurrency)
            ?? defaults.staticConcurrency
        globalTTLMinutes = try container.decodeIfPresent(Int.self, forKey: .globalTTLMinutes)
            ?? defaults.globalTTLMinutes
        memoryBudgetMB = try container.decodeIfPresent(Int.self, forKey: .memoryBudgetMB)
            ?? defaults.memoryBudgetMB
        forceMemoryAPIFailure = try container.decodeIfPresent(Bool.self, forKey: .forceMemoryAPIFailure)
            ?? defaults.forceMemoryAPIFailure
        microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled)
            ?? defaults.microphoneEnabled
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? defaults.launchAtLogin
        normalize()
    }

    /// 清洗与约束（并发硬上限 4、超时范围、实例上限、内存预算范围）。
    public mutating func normalize() {
        globalProxy = globalProxy.normalized
        maxInstancesWhenDegraded = min(max(maxInstancesWhenDegraded, 1), 64)
        staticCaptureTimeout = min(max(staticCaptureTimeout, 1), 120)
        staticConcurrency = min(max(staticConcurrency, 1), Self.staticConcurrencyHardLimit)
        globalTTLMinutes = max(globalTTLMinutes, 0)
        memoryBudgetMB = min(max(memoryBudgetMB, Self.memoryBudgetRange.lowerBound),
                             Self.memoryBudgetRange.upperBound)
    }

    public var memoryBudgetBytes: Int64 {
        Int64(memoryBudgetMB) * 1024 * 1024
    }

    public var validationError: String? {
        if let error = globalProxy.validationError {
            return error
        }
        if startupPolicy == .openBookmark && startupBookmarkID == nil {
            return "请选择启动时要打开的收藏"
        }
        return nil
    }

    public func normalizedSettings() -> AppSettings {
        var copy = self
        copy.normalize()
        return copy
    }
}
