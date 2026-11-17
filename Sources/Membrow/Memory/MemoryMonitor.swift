import AppKit
import Foundation
import MembrowCore

@MainActor
final class MemoryMonitor {
    struct OverageItem {
        let bookmarkID: UUID
        let name: String
        let footprint: Int64?
        let isPinned: Bool
        /// 是否正显示在屏幕上。可见页面不参与回收，也不该弹“超限”提示。
        let isVisible: Bool
    }

    private let store: AppStore
    private weak var runtime: BrowserRuntime?
    private let snapshots: SnapshotRegistry
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pressure: MemoryPressureLevel = .normal
    private var lastNotifyAt = Date.distantPast

    private(set) var lastPlan: MemoryPlan?
    private(set) var overageItems: [OverageItem] = []
    private(set) var preciseAvailable = true
    private(set) var unreadableCount = 0

    var onChange: (() -> Void)?
    /// 设置窗口打开时挂上，让诊断表格跟着巡检自动刷新（不用手动点“刷新内存诊断”）。
    var onDiagnosticsChange: (() -> Void)?

    init(store: AppStore, runtime: BrowserRuntime, snapshots: SnapshotRegistry) {
        self.store = store
        self.runtime = runtime
        self.snapshots = snapshots
    }

    func start() {
        guard timer == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            let event = source.data
            if event.contains(.critical) {
                self.pressure = .critical
            } else if event.contains(.warning) {
                self.pressure = .warning
            } else {
                self.pressure = .normal
            }
            self.tick()
        }
        source.resume()
        pressureSource = source

        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// 单次定时器按需重排：间隔随状态伸缩，空闲时不再每 2 秒唤醒一次 RunLoop。
    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(interval, 0.01), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // 允许系统合并唤醒，常驻监听才真正省电。
        timer.tolerance = min(max(interval * 0.2, 0.1), 5)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var mode: MemoryMode {
        let apiAvailable = MemoryProbe.privateAPIAvailable && MemoryProbe.rusageAvailable
        if store.settings.forceMemoryAPIFailure || !apiAvailable {
            return .degraded(instanceLimit: store.settings.maxInstancesWhenDegraded,
                             pressure: pressure)
        }
        return .precise(budgetBytes: store.settings.memoryBudgetBytes)
    }

    private func tick() {
        guard let runtime else {
            // 运行时已释放（退出中）：保住巡检链，避免常驻监听悄悄停掉。
            schedule(after: 30)
            return
        }
        // 静态精简快照也是一个常驻 WebView，一并计入预算与 LRU。
        let samples = runtime.memorySamples() + snapshots.memorySamples()
        let mode = self.mode
        if case .precise = mode {
            preciseAvailable = MemoryProbe.privateAPIAvailable && MemoryProbe.rusageAvailable
        } else {
            preciseAvailable = false
        }
        unreadableCount = samples.filter { $0.footprint == nil }.count

        let previousMode = lastPlan?.mode
        let previousOverage = overageItems.map { "\($0.bookmarkID)|\($0.isPinned)|\($0.isVisible)" }

        let plan = MemoryGovernor.plan(samples: samples, mode: mode)
        lastPlan = plan

        for bookmarkID in plan.evict {
            // 两类实例用同一份计划：动态实例销毁 WebView，静态快照回退 Markdown。
            runtime.evict(bookmarkID: bookmarkID)
            snapshots.evict(bookmarkID: bookmarkID)
        }

        overageItems = plan.overage.compactMap { bookmarkID in
            guard let bookmark = store.bookmark(id: bookmarkID) else { return nil }
            let sample = samples.first { $0.bookmarkID == bookmarkID }
            return OverageItem(bookmarkID: bookmarkID,
                               name: bookmark.trimmedName,
                               footprint: sample?.footprint,
                               isPinned: sample?.isPinned ?? bookmark.isPinned,
                               isVisible: sample?.isVisible ?? false)
        }

        // 每轮无条件重建一次全量 UI 与侧栏状态代价过高；仅在状态变化时通知，
        // 同时每 30 秒兜底刷新一次，保证缓存过期等时间相关状态仍会更新。
        let now = Date()
        let periodicRefresh = now.timeIntervalSince(lastNotifyAt) >= 30
        let overageChanged = overageItems.map { "\($0.bookmarkID)|\($0.isPinned)|\($0.isVisible)" } != previousOverage
        schedule(after: MemoryGovernor.sampleInterval(sampleCount: samples.count, mode: mode, plan: plan))
        guard periodicRefresh || overageChanged || previousMode != mode || !plan.evict.isEmpty else { return }
        lastNotifyAt = now
        onChange?()
        onDiagnosticsChange?()
    }

    var modeDisplayName: String {
        switch mode {
        case .precise(let budget):
            return "精确模式 · 预算 \(MemoryProbe.formatted(budget))"
        case .degraded(let limit, let pressure):
            let pressureText: String
            switch pressure {
            case .normal: pressureText = "正常"
            case .warning: pressureText = "警告"
            case .critical: pressureText = "严重"
            }
            return "降级模式 · 实例上限 \(limit) · 内存压力\(pressureText)"
        }
    }

    /// 供设置窗口的表格控件直接渲染的结构化数据。
    func diagnosticTables() -> (status: [[String]], instances: [[String]]) {
        var statusRows: [[String]] = [
            ["内存模式", modeDisplayName],
            ["私有接口", MemoryProbe.privateAPIAvailable ? "可用" : "不可用"],
            ["proc_pid_rusage", MemoryProbe.rusageAvailable ? "可用" : "不可用"],
            ["故障注入", store.settings.forceMemoryAPIFailure ? "开启" : "关闭"],
        ]
        guard let runtime else { return (statusRows, []) }

        let dynamicSamples = runtime.memorySamples()
        let snapshotSamples = snapshots.memorySamples()
        statusRows.append(["动态实例", "\(runtime.instanceCount) 个"])
        statusRows.append(["静态快照", "\(snapshotSamples.count) 个"])
        if let plan = lastPlan, let total = plan.totalFootprint {
            statusRows.append(["内存池合计", MemoryProbe.formatted(total)])
        }
        if unreadableCount > 0 {
            statusRows.append(["读数缺失", "\(unreadableCount) 个（未计入预算）"])
        }

        var instanceRows: [[String]] = []
        for sample in dynamicSamples.sorted(by: { $0.lastVisibleAt > $1.lastVisibleAt }) {
            let name = store.bookmark(id: sample.bookmarkID)?.trimmedName ?? sample.bookmarkID.uuidString
            let state = (sample.isVisible ? "可见" : "隐藏") + (sample.isPinned ? " · 固定" : "")
            instanceRows.append([name, "动态", state, MemoryProbe.formatted(sample.footprint)])
        }
        for sample in snapshotSamples {
            let name = store.bookmark(id: sample.bookmarkID)?.trimmedName ?? sample.bookmarkID.uuidString
            instanceRows.append([name, "快照",
                                 sample.isVisible ? "可见" : "隐藏",
                                 MemoryProbe.formatted(sample.footprint)])
        }
        if instanceRows.isEmpty {
            instanceRows = [["（无运行中的实例）", "", "", ""]]
        }
        return (statusRows, instanceRows)
    }
}
