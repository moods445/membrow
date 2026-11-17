import AppKit
import Foundation
import MembrowCore

@MainActor
final class AppEnvironment {

    let dataDirectory: URL
    let store: AppStore
    let sharedWebData: SharedWebData
    let blocker: ContentBlocker
    let credentials: CredentialStore
    let runtime: BrowserRuntime
    let staticManager: StaticBookmarkManager
    let siteInfo: SiteInfoService
    let snapshots: SnapshotRegistry
    let memoryMonitor: MemoryMonitor

    /// 启动策略控制：为 false 时（不恢复）内容区域只展示“未启动”。
    var autoLoadEnabled = true

    init() throws {
        let directory = try Self.makeDataDirectory()
        dataDirectory = directory
        store = try AppStore(directory: directory)
        sharedWebData = SharedWebData()
        blocker = ContentBlocker(storeURL: directory.appendingPathComponent("content-rules", isDirectory: true))
        credentials = CredentialStore()
        runtime = BrowserRuntime(store: store,
                                 sharedWebData: sharedWebData,
                                 blocker: blocker,
                                 credentials: credentials)
        staticManager = StaticBookmarkManager(store: store, sharedWebData: sharedWebData)
        siteInfo = SiteInfoService(store: store, dataDirectory: directory)
        let snapshots = SnapshotRegistry()
        self.snapshots = snapshots
        memoryMonitor = MemoryMonitor(store: store, runtime: runtime, snapshots: snapshots)
    }

    /// 默认数据目录遵循 macOS 规范：`~/Library/Application Support/<Bundle Identifier>`。
    /// `MEMBROW_DATA_DIR` 仅供测试隔离使用。
    private static func makeDataDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MEMBROW_DATA_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                                isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        let base = try DataDirectory.applicationSupportBase()
        let folderName = Bundle.main.bundleIdentifier ?? DataDirectory.legacyFolderName
        return try DataDirectory.resolve(base: base, folderName: folderName)
    }

    func launch() {
        if store.sessions.isEmpty {
            store.createSession(name: "聚合 1")
        }
        memoryMonitor.start()
        siteInfo.refreshAllMetadata()
        Task { [weak self] in
            guard let self else { return }
            await self.blocker.load()
            self.runtime.reapplyBlockingRules()
        }
    }
}
