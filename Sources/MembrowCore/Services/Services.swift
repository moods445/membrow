import Foundation

// MARK: - TTL

public enum CacheFreshness: Equatable, Sendable {
    case fresh
    case stale
    case missing
}

public struct TTLEvaluator: Sendable {
    public var globalMinutes: Int

    public init(globalMinutes: Int) {
        self.globalMinutes = max(globalMinutes, 0)
    }

    /// 收藏的 TTL 换算为分钟；noCache 与 neverExpires 返回 nil。
    public func effectiveMinutes(for ttl: TTLPolicy) -> Int? {
        switch ttl.normalized {
        case .inherit:
            return globalMinutes
        case .minutes(let value):
            return value
        case .noCache, .neverExpires:
            return nil
        }
    }

    public func freshness(ttl: TTLPolicy, fetchedAt: Date?, now: Date = Date()) -> CacheFreshness {
        guard let fetchedAt else { return .missing }
        switch ttl.normalized {
        case .noCache:
            return .stale
        case .neverExpires:
            return .fresh
        case .inherit:
            return isFresh(fetchedAt: fetchedAt, minutes: globalMinutes, now: now) ? .fresh : .stale
        case .minutes(let minutes):
            return isFresh(fetchedAt: fetchedAt, minutes: minutes, now: now) ? .fresh : .stale
        }
    }

    private func isFresh(fetchedAt: Date, minutes: Int, now: Date) -> Bool {
        if minutes <= 0 {
            // 全局 TTL 为 0 时等同于不缓存
            return false
        }
        return now.timeIntervalSince(fetchedAt) < TimeInterval(minutes) * 60
    }
}

// MARK: - Proxy resolution

public struct ProxyResolution: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case bookmark
        case global
    }

    public var proxy: ProxySettings
    public var source: Source

    public init(proxy: ProxySettings, source: Source) {
        self.proxy = proxy
        self.source = source
    }

    public var isDirect: Bool { proxy.mode == .direct }
    public var isSystem: Bool { proxy.mode == .system }
    public var isCustom: Bool { proxy.mode == .custom }

    public var displayDescription: String {
        let origin = source == .bookmark ? "收藏覆盖" : "全局"
        return "\(proxy.displayName)（\(origin)）"
    }
}

public enum ProxyResolver {
    public static func resolve(bookmark: Bookmark, settings: AppSettings) -> ProxyResolution {
        if let override = bookmark.proxy, override.isValid {
            return ProxyResolution(proxy: override.normalized, source: .bookmark)
        }
        return ProxyResolution(proxy: settings.globalProxy.normalized, source: .global)
    }

    public static func urlSessionProxyDictionary(for proxy: ProxySettings) -> [AnyHashable: Any]? {
        switch proxy.mode {
        case .direct:
            // 显式关闭各类代理，避免继承系统代理。
            return [
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                kCFNetworkProxiesSOCKSEnable as String: 0,
            ]
        case .system:
            return nil
        case .custom:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: proxy.port,
            ]
        }
    }
}

// MARK: - Memory governance

public enum MemoryPressureLevel: String, Sendable {
    case normal
    case warning
    case critical
}

public struct InstanceMemorySample: Equatable, Sendable {
    public let bookmarkID: UUID
    public let footprint: Int64?
    /// 是否可见；可见实例豁免淘汰。
    public let isVisible: Bool
    public let isPinned: Bool
    /// 最后一次可见时间，LRU 依据。
    public let lastVisibleAt: Date

    public init(bookmarkID: UUID,
                footprint: Int64?,
                isVisible: Bool,
                isPinned: Bool,
                lastVisibleAt: Date) {
        self.bookmarkID = bookmarkID
        self.footprint = footprint
        self.isVisible = isVisible
        self.isPinned = isPinned
        self.lastVisibleAt = lastVisibleAt
    }

    public var isEvictable: Bool { !isVisible && !isPinned }
}

public enum MemoryMode: Equatable, Sendable {
    case precise(budgetBytes: Int64)
    case degraded(instanceLimit: Int, pressure: MemoryPressureLevel)

    public var displayName: String {
        switch self {
        case .precise: return "精确模式"
        case .degraded: return "降级模式"
        }
    }
}

public struct MemoryPlan: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case none
        case overBudget
        case instanceLimit
        case memoryPressure
    }

    public var evict: [UUID]
    public var overage: [UUID]
    public var reason: Reason
    public var totalFootprint: Int64?
    public var mode: MemoryMode

    public init(evict: [UUID], overage: [UUID], reason: Reason, totalFootprint: Int64?, mode: MemoryMode) {
        self.evict = evict
        self.overage = overage
        self.reason = reason
        self.totalFootprint = totalFootprint
        self.mode = mode
    }

    public var hasActions: Bool { !evict.isEmpty || !overage.isEmpty }
}

public enum MemoryGovernor {
    public static let dynamicBudgetBytes: Int64 = 1024 * 1024 * 1024

    /// 计算淘汰计划。precise 模式按 1GB 预算；degraded 模式按实例上限与内存压力。
    public static func plan(samples: [InstanceMemorySample], mode: MemoryMode) -> MemoryPlan {
        switch mode {
        case .precise(let budget):
            return precisePlan(samples: samples, budget: budget, mode: mode)
        case .degraded(let limit, let pressure):
            return degradedPlan(samples: samples, instanceLimit: limit, pressure: pressure, mode: mode)
        }
    }

    private static func precisePlan(samples: [InstanceMemorySample], budget: Int64, mode: MemoryMode) -> MemoryPlan {
        var total = samples.reduce(Int64(0)) { $0 + ($1.footprint ?? 0) }
        var evict: [UUID] = []
        var remaining = samples

        if total > budget {
            let candidates = samples.filter(\.isEvictable).sorted { $0.lastVisibleAt < $1.lastVisibleAt }
            for candidate in candidates {
                if total <= budget { break }
                evict.append(candidate.bookmarkID)
                total -= candidate.footprint ?? 0
                remaining.removeAll { $0.bookmarkID == candidate.bookmarkID }
            }
        }

        let stillOver = total > budget
        let overage = stillOver ? remaining
            .filter { $0.isVisible || $0.isPinned }
            .sorted { ($0.footprint ?? 0) > ($1.footprint ?? 0) }
            .map(\.bookmarkID) : []

        return MemoryPlan(evict: evict,
                          overage: overage,
                          reason: total > budget ? .overBudget : .none,
                          totalFootprint: total,
                          mode: mode)
    }

    private static func degradedPlan(samples: [InstanceMemorySample],
                                     instanceLimit: Int,
                                     pressure: MemoryPressureLevel,
                                     mode: MemoryMode) -> MemoryPlan {
        let limit = max(instanceLimit, 1)
        var evict: [UUID] = []
        var reason: MemoryPlan.Reason = .none
        var remaining = samples

        let evictable = samples.filter(\.isEvictable).sorted { $0.lastVisibleAt < $1.lastVisibleAt }

        if pressure == .critical {
            evict = evictable.map(\.bookmarkID)
            remaining.removeAll { sample in evict.contains(sample.bookmarkID) }
            reason = .memoryPressure
            return MemoryPlan(evict: evict,
                              overage: [],
                              reason: reason,
                              totalFootprint: nil,
                              mode: mode)
        }

        if pressure == .warning {
            // 压力警告时收缩到上限的一半（至少保留 1 个实例）。
            let targetCount = max(limit / 2, 1)
            for candidate in evictable where remaining.count > targetCount {
                evict.append(candidate.bookmarkID)
                remaining.removeAll { $0.bookmarkID == candidate.bookmarkID }
            }
            if !evict.isEmpty { reason = .memoryPressure }
        }

        if remaining.count > limit {
            for candidate in evictable where remaining.count > limit {
                if evict.contains(candidate.bookmarkID) { continue }
                evict.append(candidate.bookmarkID)
                remaining.removeAll { $0.bookmarkID == candidate.bookmarkID }
            }
            reason = .instanceLimit
        }

        let overage = remaining.count > limit
            ? remaining.sorted { lhs, rhs in
                if let l = lhs.footprint, let r = rhs.footprint { return l > r }
                return lhs.lastVisibleAt > rhs.lastVisibleAt
            }.map(\.bookmarkID)
            : []

        return MemoryPlan(evict: evict,
                          overage: overage,
                          reason: reason,
                          totalFootprint: nil,
                          mode: mode)
    }

    /// 常驻巡检的下次采样间隔：没实例就低频空转，有超限/压力才回到 2 秒。
    /// 常驻监听要“一直在”，但空闲时不该有 2 秒一次的固定唤醒。
    public static func sampleInterval(sampleCount: Int,
                                      mode: MemoryMode,
                                      plan: MemoryPlan) -> TimeInterval {
        if sampleCount == 0 { return 30 }
        if case .degraded(_, let pressure) = mode, pressure != .normal { return 2 }
        if plan.hasActions { return 2 }
        return 5
    }
}

// MARK: - Concurrency limiter

public actor ConcurrencyLimiter {
    public private(set) var limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(limit, 1)
    }

    /// 运行期调整上限：已开始的持槽任务不会被中断，只在归还后按新上限放行。
    public func setLimit(_ newLimit: Int) {
        limit = max(newLimit, 1)
        promoteWaiters()
    }

    public func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func release() {
        guard inUse > 0 else { return }
        inUse -= 1
        promoteWaiters()
    }

    private func promoteWaiters() {
        while inUse < limit, !waiters.isEmpty {
            waiters.removeFirst().resume()
            inUse += 1
        }
    }

    public func withSlot<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}
