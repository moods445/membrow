import Foundation

/// HTTP 响应体解码：优先 HTTP 头声明的字符集，其次 HTML 里的 `<meta charset>`，
/// 再次 UTF-8，最后按中文站点常见的 GB18030 兜底。
public enum HTTPTextDecoder {
    public static func decode(data: Data, charset: String?) -> String? {
        let declared = charset.flatMap { encoding(named: $0) } ?? metaCharset(in: data)
        if let declared, let text = String(data: data, encoding: declared) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gb18030)
    }

    public static func encoding(named charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// 从 HTML 前 4KB 读取 `<meta charset=...>` / `content="...; charset=..."`。
    /// GB18030 对其余字节流几乎从不失败，不先看 meta 会把 Big5/Shift_JIS 页面静默解成乱码。
    static func metaCharset(in data: Data) -> String.Encoding? {
        let head = data.prefix(4096)
        guard let text = String(data: head, encoding: .isoLatin1)?.lowercased(),
              let marker = text.range(of: "charset=") else {
            return nil
        }
        let rest = text[marker.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " || $0 == "=" }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !name.isEmpty else { return nil }
        return encoding(named: String(name))
    }
}
