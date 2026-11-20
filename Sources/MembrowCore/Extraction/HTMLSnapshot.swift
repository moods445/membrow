import Foundation

/// 精简快照：把抓到的 HTML 清洗成“只留布局”的静态页面。
///
/// 去掉脚本、内联事件、表单与跟踪类资源；保留 `<style>` / `<link rel=stylesheet>`、
/// 结构与语义标签，渲染时再用禁用 JS 的 WebView 显示，内存开销远低于原网页。
public enum HTMLSnapshotSanitizer {
    /// 连同内容一起整个删除的标签。
    private static let removedTags: Set<String> = [
        "script", "noscript", "iframe", "frame", "frameset", "object", "embed", "applet",
        "canvas", "template", "form", "input", "button", "select", "option", "optgroup",
        "textarea", "video", "audio", "source", "track", "base",
    ]

    private static let voidTags: Set<String> = [
        "area", "br", "col", "hr", "img", "link", "meta", "param", "wbr",
    ]

    /// 内容按原样输出的标签（只有 CSS 需要）；`pre` 的子节点是正常解析的，
    /// 按原文输出会丢掉 `<pre><code>` 里的文本，还会把已解码的实体重新变成标签。
    private static let rawTextTags: Set<String> = ["style"]

    private static let keptLinkRels: Set<String> = ["stylesheet", "icon", "shortcut icon", "apple-touch-icon"]

    public static func sanitize(html: String) -> String {
        let document = HTMLParser.parse(html)
        prune(document)
        let body: String
        if let htmlElement = document.firstElement(named: "html") {
            body = serialize(htmlElement)
        } else {
            body = document.children.map(serialize).joined()
        }
        guard !body.isEmpty else { return "" }
        return "<!doctype html>\n" + body
    }

    // MARK: - Pruning

    private static func prune(_ node: HTMLNode) {
        for child in node.children where child.kind == .element {
            guard let name = child.name else { continue }
            if removedTags.contains(name) || child.attributes["hidden"] != nil {
                child.removeFromParent()
                continue
            }
            if name == "link", !isKeptLink(child) {
                child.removeFromParent()
                continue
            }
            // http-equiv 会触发跳转/安全策略，快照里不需要。
            if name == "meta", child.attributes["http-equiv"] != nil {
                child.removeFromParent()
                continue
            }
            // 内联事件处理器是最大的“脚本残留”，直接丢弃。
            child.attributes = child.attributes.filter { !$0.key.hasPrefix("on") }
            prune(child)
        }
    }

    private static func isKeptLink(_ node: HTMLNode) -> Bool {
        let rel = (node.attributes["rel"] ?? "").lowercased()
        return keptLinkRels.contains { rel.contains($0) }
    }

    // MARK: - Serialization

    private static func serialize(_ node: HTMLNode) -> String {
        switch node.kind {
        case .text:
            return escapeText(node.text ?? "")
        case .document:
            return node.children.map(serialize).joined()
        case .element:
            guard let name = node.name else { return "" }
            var output = "<" + name
            for (key, value) in node.attributes.sorted(by: { $0.key < $1.key }) {
                output += " \(key)=\"\(escapeAttribute(value))\""
            }
            output += ">"
            if voidTags.contains(name) { return output }
            if rawTextTags.contains(name) {
                output += node.children.map { $0.text ?? "" }.joined()
            } else {
                output += node.children.map(serialize).joined()
            }
            output += "</\(name)>"
            return output
        }
    }

    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
