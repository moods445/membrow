import AppKit
import Foundation

/// 容纳网页内容或占位状态的容器。
@MainActor
protocol ContentHosting: AnyObject {
    var hostBookmarkID: UUID? { get }
    /// 容器当前是否真的显示在屏幕上（用于判断 WebView 是否还被用户看见）。
    var isEffectivelyVisible: Bool { get }
    /// 是否是当前聚合面板里的 pane：面板内所有收藏都算前台激活内容，
    /// 放大时被盖住的 pane 也不参与内存回收。
    var isAggregationPane: Bool { get }
    func attachWebView(_ webView: NSView)
}

extension ContentHosting {
    var isAggregationPane: Bool { false }
}
