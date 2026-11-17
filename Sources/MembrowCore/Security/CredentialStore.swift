import Foundation
import Security

/// 已保存的登录凭据（密码本体不进入模型，按需从钥匙串读取）。
public struct StoredCredential: Identifiable, Equatable, Sendable {
    public var host: String
    public var username: String
    public var updatedAt: Date

    public var id: String { "\(host)|\(username)" }

    public init(host: String, username: String, updatedAt: Date = Date()) {
        self.host = host
        self.username = username
        self.updatedAt = updatedAt
    }
}

public enum CredentialStoreError: Error, LocalizedError {
    case invalidInput
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "站点或用户名不能为空"
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败：\(message)（\(status)）"
        }
    }
}

/// 登录凭据存储：只写入 macOS 钥匙串（`kSecClassInternetPassword`），绝不落到 JSON / SQLite。
public final class CredentialStore {
    private let label: String
    private let lock = NSLock()

    public init(label: String = "Membrow") {
        self.label = label
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
        ]
    }

    public func save(host: String, username: String, password: String) throws {
        let host = SiteMatcher.normalizedHost(host)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            throw CredentialStoreError.invalidInput
        }

        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery
        query[kSecAttrServer as String] = host
        query[kSecAttrAccount as String] = username

        let secret = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, secret as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }

        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }

    public func all() -> [StoredCredential] {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String,
                  let username = item[kSecAttrAccount as String] as? String else { return nil }
            let updatedAt = item[kSecAttrModificationDate as String] as? Date ?? .distantPast
            return StoredCredential(host: host, username: username, updatedAt: updatedAt)
        }.sorted { lhs, rhs in
            lhs.host == rhs.host ? lhs.username < rhs.username : lhs.host < rhs.host
        }
    }

    public func credentials(forHost host: String) -> [StoredCredential] {
        let host = SiteMatcher.normalizedHost(host)
        guard !host.isEmpty else { return [] }
        return all().filter { $0.host == host }
    }

    public func password(forHost host: String, username: String) -> String? {
        let host = SiteMatcher.normalizedHost(host)
        guard !host.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecAttrServer as String] = host
        query[kSecAttrAccount as String] = username
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(host: String, username: String) {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecAttrServer as String] = SiteMatcher.normalizedHost(host)
        query[kSecAttrAccount as String] = username
        SecItemDelete(query as CFDictionary)
    }

    public func deleteAll() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
    }
}
