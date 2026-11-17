import Foundation

/// 从 HTML 头部提取站点元信息（标题、图标地址）。纯函数，便于自测。
public enum SiteMetadata {
    /// 优先 `<title>`，回退第一个 `h1`；为空返回 nil。
    public static func title(inHTML html: String) -> String? {
        let document = HTMLParser.parse(html)
        let title = HTMLParser.title(in: document).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// 按文档顺序返回 `rel` 含 `icon` 的 `<link href>`（已相对 baseURL 解析）。
    public static func iconURLs(inHTML html: String, baseURL: URL) -> [URL] {
        let document = HTMLParser.parse(html)
        var result: [URL] = []
        for element in document.allElements() where element.name == "link" {
            guard let rel = element.attribute("rel")?.lowercased(), rel.contains("icon"),
                  let href = element.attribute("href")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty,
                  let url = URL(string: href, relativeTo: baseURL) else { continue }
            result.append(url)
        }
        return result
    }
}
