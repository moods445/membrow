import CryptoKit
import Foundation
import Network
import WebKit
import MembrowCore

/// 统一提供网站数据仓库与代理配置。
///
/// 全局代理生效的实例使用 `WKWebsiteDataStore.default()`，从而共享登录态；
/// 收藏级代理覆盖会使用按代理配置隔离的持久化仓库（创建时从默认仓库播种 Cookie）。
@MainActor
final class SharedWebData {
    let defaultStore = WKWebsiteDataStore.default()

    private var isolatedStores: [String: WKWebsiteDataStore] = [:]
    private var appliedProxyKeys: [String: String] = [:]
    private var seededStores: Set<String> = []

    func dataStore(for bookmark: Bookmark, settings: AppSettings) -> WKWebsiteDataStore {
        let resolution = ProxyResolver.resolve(bookmark: bookmark, settings: settings)
        return dataStore(for: resolution.proxy, settings: settings)
    }

    func dataStore(for proxy: ProxySettings, settings: AppSettings) -> WKWebsiteDataStore {
        let proxy = proxy.normalized
        if proxy == settings.globalProxy.normalized {
            applyProxy(proxy, to: defaultStore, key: "default")
            return defaultStore
        }

        let key = "\(proxy.mode.rawValue)|\(proxy.host)|\(proxy.port)"
        if let existing = isolatedStores[key] {
            return existing
        }
        let identifier = Self.identifier(for: key)
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        isolatedStores[key] = store
        applyProxy(proxy, to: store, key: key)
        seedCookies(from: defaultStore, to: store)
        return store
    }

    private func applyProxy(_ proxy: ProxySettings, to store: WKWebsiteDataStore, key: String) {
        let proxyKey = "\(proxy.mode.rawValue)|\(proxy.host)|\(proxy.port)"
        guard appliedProxyKeys[key] != proxyKey else { return }

        switch proxy.mode {
        case .direct:
            store.proxyConfigurations = []
        case .system:
            // 恢复系统代理：Objective-C 属性可空，Swift 接口因 NS_REFINED_FOR_SWIFT 变为非可选数组。
            store.setValue(nil, forKey: "proxyConfigurations")
        case .custom:
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) else {
                return
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
            store.proxyConfigurations = [Network.ProxyConfiguration(httpCONNECTProxy: endpoint)]
        }
        appliedProxyKeys[key] = proxyKey
    }

    /// 隔离仓库创建时复制默认仓库的 Cookie，尽量复用已有登录态。
    private func seedCookies(from source: WKWebsiteDataStore, to destination: WKWebsiteDataStore) {
        let key = destination.identifier?.uuidString ?? UUID().uuidString
        guard !seededStores.contains(key) else { return }
        seededStores.insert(key)
        Task { @MainActor in
            let cookies = await source.httpCookieStore.allCookies()
            for cookie in cookies {
                await destination.httpCookieStore.setCookie(cookie)
            }
        }
    }

    private static func identifier(for key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
