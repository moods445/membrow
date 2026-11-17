import AppKit
import Foundation

/// 容纳网页内容或占位状态的容器。
@MainActor
protocol ContentHosting: AnyObject {
    var hostBookmarkID: UUID? { get }
    /// 容器当前是否真的显示在屏幕上（用于判断 WebView 是否还被用户看见）。
    var isEffectivelyVisible: Bool { get }
    func attachWebView(_ webView: NSView)
}
