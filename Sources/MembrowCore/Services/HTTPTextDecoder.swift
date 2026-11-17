import Foundation

/// HTTP 响应体解码：优先声明字符集，其次 UTF-8，最后按中文站点常见的 GB18030 兜底。
public enum HTTPTextDecoder {
    public static func decode(data: Data, charset: String?) -> String? {
        if let charset, let encoding = encoding(named: charset),
           let text = String(data: data, encoding: encoding) {
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
}
