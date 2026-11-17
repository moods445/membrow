import AppKit
import Darwin
import Foundation
import WebKit

enum MemoryProbe {
    private static let privateSelector = NSSelectorFromString("_webProcessIdentifier")

    static var privateAPIAvailable: Bool {
        WKWebView.instancesRespond(to: privateSelector)
    }

    static var rusageAvailable: Bool {
        footprint(of: getpid()) != nil
    }

    static func webProcessIdentifier(of webView: WKWebView) -> pid_t? {
        guard privateAPIAvailable else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector) -> Int32
        let implementation = webView.method(for: privateSelector)
        let function = unsafeBitCast(implementation, to: Function.self)
        let pid = function(webView, privateSelector)
        return pid > 0 ? pid : nil
    }

    static func footprint(of webView: WKWebView) -> Int64? {
        guard let pid = webProcessIdentifier(of: webView) else { return nil }
        return footprint(of: pid)
    }

    static func footprint(of pid: pid_t) -> Int64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }
        let value = info.ri_phys_footprint
        return value > 0 ? Int64(value) : nil
    }

    static func formatted(_ bytes: Int64?) -> String {
        guard let bytes else { return "无法读取" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
