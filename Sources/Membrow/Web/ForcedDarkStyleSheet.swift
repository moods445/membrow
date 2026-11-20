import Foundation
import MembrowCore
import WebKit

/// WebKit 私有 user stylesheet 的薄封装：只注入 CSS，不执行 JS、不改写 DOM。
///
/// ponytail: 依赖私有类 `_WKUserStyleSheet` 与 `_addUserStyleSheet:`/`_removeUserStyleSheet:`。
/// 接口在未来系统消失时 `isAvailable == false`，强制深色降级为不反色（AGENTS.md 的注入边界）。
enum ForcedDarkStyleSheet {
    private static let className = "_WKUserStyleSheet"
    private static let allocSelector = NSSelectorFromString("alloc")
    private static let initSelector = NSSelectorFromString("initWithSource:forMainFrameOnly:")
    private static let addSelector = NSSelectorFromString("_addUserStyleSheet:")
    private static let removeSelector = NSSelectorFromString("_removeUserStyleSheet:")

    static var isAvailable: Bool {
        guard WKUserContentController.instancesRespond(to: addSelector),
              let cls = NSClassFromString(className) else { return false }
        return class_getInstanceMethod(cls, initSelector) != nil
    }

    /// 注入到 WebView 的全部 frame；接口不可用时返回 nil。
    static func add(to controller: WKUserContentController) -> NSObject? {
        guard isAvailable,
              let cls = NSClassFromString(className) as? NSObject.Type,
              let allocated = (cls as AnyObject).perform(allocSelector)?
                  .takeRetainedValue() as? NSObject
        else { return nil }

        typealias InitSheet = @convention(c) (NSObject, Selector, NSString, Bool) -> Unmanaged<AnyObject>?
        let initSheet = unsafeBitCast(allocated.method(for: initSelector), to: InitSheet.self)
        // ponytail: init 返回接收者本身（+1 已由 alloc 取得），忽略返回值避免重复持有。
        guard initSheet(allocated, initSelector, ForcedDarkStyle.css as NSString, false) != nil else {
            return nil
        }

        _ = controller.perform(addSelector, with: allocated)
        return allocated
    }

    static func remove(_ sheet: NSObject, from controller: WKUserContentController) {
        _ = controller.perform(removeSelector, with: sheet)
    }
}
