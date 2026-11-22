import AppKit
import Foundation
import MembrowCore
import WebKit

/// `--diagnose-memory`：验证私有内存接口、进程归属与共享情况，并输出可重复的报告。
@MainActor
enum MemoryDiagnostics {
    static func run(environment: AppEnvironment, completion: @escaping (Int32) -> Void) {
        Task { @MainActor in
            let report = await collect(environment: environment)
            // 每段是独立表格或说明，空行分隔才好读。
            let text = report.joined(separator: "\n\n")
            print(text)
            fflush(stdout)
            let fileURL = environment.dataDirectory.appendingPathComponent("memory-diagnostics.txt")
            do {
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
                completion(0)
            } catch {
                // 诊断文件写不出来必须让脚本/CI 看到，不能用 0 退出码伪装成功。
                FileHandle.standardError.write(Data("诊断报告写入失败：\(error.localizedDescription)\n".utf8))
                completion(1)
            }
        }
    }

    private static func collect(environment: AppEnvironment) async -> [String] {
        var sections: [String] = ["Membrow 内存与进程诊断"]

        let environmentRows: [[String]] = [
            ["时间", ISO8601DateFormatter().string(from: Date())],
            ["系统", ProcessInfo.processInfo.operatingSystemVersionString],
            ["架构", architectureName],
            ["私有接口", MemoryProbe.privateAPIAvailable ? "可用" : "不可用"],
            ["proc_pid_rusage", MemoryProbe.rusageAvailable ? "可用" : "不可用"],
            ["故障注入", environment.store.settings.forceMemoryAPIFailure ? "开启" : "关闭"],
            ["麦克风", environment.store.settings.microphoneEnabled ? "允许" : "禁止"],
            ["诊断日志", environment.dataDirectory.appendingPathComponent("logs/info.jsonl").path],
            ["开机自启", LaunchAtLogin.statusDescription],
            ["强制深色样式表", ForcedDarkStyleSheet.isAvailable ? "可用" : "不可用（降级为不反色）"],
            ["内存模式", environment.memoryMonitor.modeDisplayName],
        ]
        sections.append(TextTable.render(headers: ["项目", "值"], rows: environmentRows))

        guard MemoryProbe.privateAPIAvailable, MemoryProbe.rusageAvailable else {
            sections.append("结论：私有接口不可用，应用应进入降级模式（实例上限 + 系统内存压力）。")
            return sections
        }

        // 进程共享探测：同样的页面开三个 WebView，看 pid 是否被复用。
        let first = makeWebView()
        _ = await load(first)
        let firstPID1 = MemoryProbe.webProcessIdentifier(of: first)
        let firstFootprint1 = MemoryProbe.footprint(of: first)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let firstPID2 = MemoryProbe.webProcessIdentifier(of: first)
        let firstFootprint2 = MemoryProbe.footprint(of: first)

        let second = makeWebView()
        _ = await load(second)
        let secondPID = MemoryProbe.webProcessIdentifier(of: second)
        let secondFootprint = MemoryProbe.footprint(of: second)

        let isolated = makeWebView(useIsolatedProcessPool: true)
        _ = await load(isolated)
        let isolatedPID = MemoryProbe.webProcessIdentifier(of: isolated)
        let isolatedFootprint = MemoryProbe.footprint(of: isolated)

        var processRows: [[String]] = [
            ["单实例 A", describe(firstPID1), MemoryProbe.formatted(firstFootprint1), ""],
            ["A 重复采样", describe(firstPID2), MemoryProbe.formatted(firstFootprint2),
             firstPID1 == firstPID2 ? "读数可重复" : "读数不一致"],
            ["默认进程池 B", describe(secondPID), MemoryProbe.formatted(secondFootprint), ""],
            ["独立进程池 C", describe(isolatedPID), MemoryProbe.formatted(isolatedFootprint), ""],
        ]
        var notes: [String] = []
        if let firstPID1, let secondPID {
            let shared = firstPID1 == secondPID
            processRows[2][3] = shared ? "与 A 同进程" : "与 A 独立进程"
            if shared {
                notes.append("说明：默认进程池共享 WebContent，收藏级内存只能按进程总量近似归因。")
            }
        }
        if let firstPID1, let isolatedPID {
            processRows[3][3] = firstPID1 != isolatedPID ? "进程池隔离生效" : "系统已忽略独立进程池"
        }
        sections.append("[进程共享与读数]")
        sections.append(TextTable.render(headers: ["实例", "pid", "内存", "备注"], rows: processRows))
        sections.append(contentsOf: notes)

        var instanceRows: [[String]] = []
        for sample in environment.runtime.memorySamples() {
            let name = environment.store.bookmark(id: sample.bookmarkID)?.trimmedName
                ?? sample.bookmarkID.uuidString
            instanceRows.append([name, "动态", sample.isVisible ? "激活" : "未激活",
                                 MemoryProbe.formatted(sample.footprint)])
        }
        let snapshotSamples = environment.snapshots.memorySamples()
        for sample in snapshotSamples {
            let name = environment.store.bookmark(id: sample.bookmarkID)?.trimmedName
                ?? sample.bookmarkID.uuidString
            instanceRows.append([name, "快照", sample.isVisible ? "可见" : "隐藏",
                                 MemoryProbe.formatted(sample.footprint)])
        }
        if instanceRows.isEmpty {
            instanceRows = [["（无运行中的实例）", "", "", ""]]
        }
        sections.append("[应用内实例]")
        sections.append(TextTable.render(headers: ["名称", "类型", "状态", "内存"], rows: instanceRows))

        sections.append("""
        [限制]
        - proc_pid_rusage 统计 phys_footprint，不含 GPU / 显存。
        - WebContent 进程共享时，收藏级读数只能按进程粒度近似归因。
        - Networking 进程内存不在 _webProcessIdentifier 返回的 pid 范围内。
        """)
        return sections
    }

    private static func makeWebView(useIsolatedProcessPool: Bool = false) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if useIsolatedProcessPool {
            configuration.processPool = WKProcessPool()
        }
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }

    private static func load(_ webView: WKWebView) async -> Bool {
        webView.loadHTMLString(
            "<html><head><meta charset=\"utf-8\"></head><body><h1>Membrow diagnostics</h1></body></html>",
            baseURL: URL(string: "https://example.com")
        )
        for _ in 0..<100 {
            if webView.url != nil, !webView.isLoading {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !webView.isLoading
    }

    private static func describe(_ pid: pid_t?) -> String {
        guard let pid else { return "无法读取" }
        return String(pid)
    }

    private static var architectureName: String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }
}
