import Foundation

/// 同站判定：以可注册域（近似 eTLD+1）比较主机名。
public enum SiteMatcher {
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "net.nz", "org.nz", "govt.nz",
        "com.br", "com.mx", "com.ar", "com.tr", "com.sg", "com.my",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "ne.kr", "go.kr",
        "co.in", "net.in", "org.in", "gov.in",
        "co.za", "org.za", "net.za",
    ]

    public static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("[") , let end = value.firstIndex(of: "]") {
            return String(value[value.startIndex..<value.index(after: end)])
        }
        // ponytail: 含多个冒号只可能是无括号 IPv6 字面量（带端口必须以 [] 包裹），原样返回。
        if value.filter({ $0 == ":" }).count > 1 {
            return value
        }
        if let colon = value.lastIndex(of: ":") {
            value = String(value[value.startIndex..<colon])
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    public static func registrableDomain(_ host: String) -> String? {
        let value = normalizedHost(host)
        guard !value.isEmpty else { return nil }
        if value.contains(":") || isIPv4(value) {
            return value
        }
        let parts = value.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.count <= 2 { return value }
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if multiPartSuffixes.contains(lastTwo), parts.count >= 3 {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    public static func isSameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftHost = lhs.host, let rightHost = rhs.host else {
            return lhs.absoluteString == rhs.absoluteString
        }
        guard let left = registrableDomain(leftHost), let right = registrableDomain(rightHost) else {
            return normalizedHost(leftHost) == normalizedHost(rightHost)
        }
        return left == right
    }

    public static func isSameSite(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return isSameSite(left, right)
        case (nil, nil): return true
        default: return false
        }
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part), 0...255 ~= number else { return false }
            return true
        }
    }
}
