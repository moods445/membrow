import Foundation
import MembrowCore
import WebKit

/// 静态“精简快照”WebView 的注册表：把快照实例纳入内存采样与 LRU 淘汰。
///
/// 快照由 `StaticContentView` 创建，切页/刷新时自行销毁；这里只在存活期间登记，
/// 预算超限时由 `MemoryMonitor` 调用 `evict`，视图侧收到回调后回退为 Markdown。
@MainActor
final class SnapshotRegistry {
    private struct Entry {
        weak var webView: WKWebView?
        let isVisible: () -> Bool
        let onEvict: () -> Void
        var lastVisibleAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    var count: Int { entries.count }

    func register(bookmarkID: UUID,
                  webView: WKWebView,
                  isVisible: @escaping () -> Bool,
                  onEvict: @escaping () -> Void) {
        entries[bookmarkID] = Entry(webView: webView,
                                    isVisible: isVisible,
                                    onEvict: onEvict,
                                    lastVisibleAt: Date())
    }

    func unregister(bookmarkID: UUID) {
        entries[bookmarkID] = nil
    }

    func memorySamples() -> [InstanceMemorySample] {
        let now = Date()
        var samples: [InstanceMemorySample] = []
        var stale: [UUID] = []
        for (bookmarkID, entry) in entries {
            guard let webView = entry.webView else {
                stale.append(bookmarkID)
                continue
            }
            let visible = entry.isVisible()
            if visible { entries[bookmarkID]?.lastVisibleAt = now }
            samples.append(InstanceMemorySample(bookmarkID: bookmarkID,
                                                footprint: MemoryProbe.footprint(of: webView),
                                                isVisible: visible,
                                                isPinned: false,
                                                lastVisibleAt: entry.lastVisibleAt))
        }
        // 视图被销毁但没来得及注销时顺手清理，避免诊断里出现幽灵条目。
        for bookmarkID in stale {
            entries[bookmarkID] = nil
        }
        return samples
    }

    func evict(bookmarkID: UUID) {
        guard let entry = entries.removeValue(forKey: bookmarkID) else { return }
        entry.onEvict()
    }
}
