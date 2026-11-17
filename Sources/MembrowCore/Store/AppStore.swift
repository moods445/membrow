import Combine
import Foundation

public struct JSONFileStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let fileURL = url(for: name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url(for: name), options: .atomic)
    }
}

public enum AppStoreError: Error, LocalizedError {
    case bookmarkNotFound
    case groupNotFound
    case sessionNotFound
    case paneNotFound
    case invalidName
    case invalidURL
    case invalidProxy(String)
    case invalidSettings(String)

    public var errorDescription: String? {
        switch self {
        case .bookmarkNotFound: return "收藏不存在"
        case .groupNotFound: return "分组不存在"
        case .sessionNotFound: return "聚合不存在"
        case .paneNotFound: return "Pane 不存在"
        case .invalidName: return "名称不能为空"
        case .invalidURL: return "请输入有效的 http 或 https 地址"
        case .invalidProxy(let message): return message
        case .invalidSettings(let message): return message
        }
    }
}

@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var library: Library
    @Published public private(set) var sessions: [Session]
    @Published public private(set) var settings: AppSettings

    public let directory: URL
    public let cache: StaticCacheStore
    public private(set) var loadWarnings: [String] = []
    public private(set) var lastPersistenceError: String?

    private let fileStore: JSONFileStore
    public var now: () -> Date

    private enum FileName {
        static let library = "library.json"
        static let sessions = "sessions.json"
        static let settings = "settings.json"
        static let cache = "static-cache.sqlite"
    }

    public init(directory: URL, now: @escaping () -> Date = Date.init) throws {
        self.directory = directory
        self.now = now
        self.fileStore = JSONFileStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.cache = try StaticCacheStore(path: directory.appendingPathComponent(FileName.cache))

        var warnings: [String] = []

        do {
            if let library = try fileStore.load(Library.self, from: FileName.library) {
                self.library = library
            } else {
                self.library = Library()
            }
        } catch {
            warnings.append("library.json 读取失败：\(error.localizedDescription)")
            self.library = Library()
        }

        do {
            if let sessions = try fileStore.load([Session].self, from: FileName.sessions) {
                self.sessions = sessions
            } else {
                self.sessions = []
            }
        } catch {
            warnings.append("sessions.json 读取失败：\(error.localizedDescription)")
            self.sessions = []
        }

        do {
            if let settings = try fileStore.load(AppSettings.self, from: FileName.settings) {
                self.settings = settings.normalizedSettings()
            } else {
                self.settings = AppSettings()
            }
        } catch {
            warnings.append("settings.json 读取失败：\(error.localizedDescription)")
            self.settings = AppSettings()
        }

        self.loadWarnings = warnings
        self.library.normalize()
        for index in self.sessions.indices {
            self.sessions[index].normalize()
        }
    }

    // MARK: Persistence

    private func persistLibrary() {
        do {
            try fileStore.save(library, to: FileName.library)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "收藏保存失败：\(error.localizedDescription)"
        }
    }

    private func persistSessions() {
        do {
            try fileStore.save(sessions, to: FileName.sessions)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "聚合保存失败：\(error.localizedDescription)"
        }
    }

    private func persistSettings() {
        do {
            try fileStore.save(settings, to: FileName.settings)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "设置保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: Queries

    public func bookmark(id: UUID) -> Bookmark? {
        library.bookmark(id: id)
    }

    public func session(id: UUID?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    public var selectedSession: Session? {
        session(id: settings.lastSessionID)
    }

    public func resolvedProxy(for bookmark: Bookmark) -> ProxyResolution {
        ProxyResolver.resolve(bookmark: bookmark, settings: settings)
    }

    public func ttlEvaluator() -> TTLEvaluator {
        TTLEvaluator(globalMinutes: settings.globalTTLMinutes)
    }

    public func freshness(for bookmark: Bookmark) -> CacheFreshness {
        let document = try? cache.load(bookmarkID: bookmark.id)
        return ttlEvaluator().freshness(ttl: bookmark.staticConfig.ttl,
                                        fetchedAt: document?.fetchedAt,
                                        now: now())
    }

    public func cachedDocument(for bookmarkID: UUID) -> CachedDocument? {
        try? cache.load(bookmarkID: bookmarkID)
    }

    // MARK: Bookmarks

    @discardableResult
    public func createBookmark(name: String,
                               entryURL: String,
                               kind: BookmarkKind,
                               groupID: UUID? = nil,
                               proxy: ProxySettings? = nil,
                               blockingEnabled: Bool = true) throws -> Bookmark {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AppStoreError.invalidName }
        guard BookmarkValidation.url(from: entryURL) != nil else { throw AppStoreError.invalidURL }
        if let proxy, !proxy.isValid {
            throw AppStoreError.invalidProxy(proxy.validationError ?? "代理配置无效")
        }
        if let groupID, library.group(id: groupID) == nil {
            throw AppStoreError.groupNotFound
        }
        let bookmark = Bookmark(name: trimmedName,
                                entryURL: entryURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                kind: kind,
                                groupID: groupID,
                                proxy: proxy,
                                blockingEnabled: blockingEnabled)
        let insertIndex: Int
        if let groupID {
            insertIndex = library.groupOrders[groupID]?.count ?? 0
        } else {
            insertIndex = library.rootOrder.count
        }
        library.insertBookmark(bookmark, groupID: groupID, at: insertIndex)
        persistLibrary()
        return bookmark
    }

    public func updateBookmark(_ bookmark: Bookmark) throws {
        guard library.bookmarkIndex(id: bookmark.id) != nil else { throw AppStoreError.bookmarkNotFound }
        let trimmedName = bookmark.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AppStoreError.invalidName }
        guard BookmarkValidation.url(from: bookmark.entryURL) != nil else { throw AppStoreError.invalidURL }
        if let proxy = bookmark.proxy, !proxy.isValid {
            throw AppStoreError.invalidProxy(proxy.validationError ?? "代理配置无效")
        }
        if let groupID = bookmark.groupID, library.group(id: groupID) == nil {
            throw AppStoreError.groupNotFound
        }
        var updated = bookmark
        if library.bookmark(id: bookmark.id)?.trimmedName != trimmedName {
            // 用户显式改名后不再用自动抓取的站点标题覆盖
            updated.siteTitle = nil
        }
        updated.name = trimmedName
        updated.entryURL = bookmark.entryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.proxy = bookmark.proxy?.normalized
        updated.staticConfig.ttl = bookmark.staticConfig.ttl.normalized
        library.updateBookmark(updated)
        persistLibrary()
    }

    public func renameBookmark(id: UUID, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppStoreError.invalidName }
        guard var bookmark = library.bookmark(id: id) else { throw AppStoreError.bookmarkNotFound }
        bookmark.name = trimmed
        bookmark.siteTitle = nil
        library.updateBookmark(bookmark)
        persistLibrary()
    }

    /// 写入自动抓取的站点标题（用户已改名时不会被这里的写入影响，因为改名会清空该字段）。
    public func setSiteTitle(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var bookmark = library.bookmark(id: id), bookmark.siteTitle != trimmed else { return }
        bookmark.siteTitle = trimmed
        library.updateBookmark(bookmark)
        persistLibrary()
    }

    public func deleteBookmark(id: UUID) {
        guard library.bookmark(id: id) != nil else { return }
        library.removeBookmark(id: id)
        try? cache.delete(bookmarkID: id)
        for index in sessions.indices {
            sessions[index].clearBookmark(id)
        }
        // 启动收藏被删除后，若仍指向它，后续任何设置保存都会因“启动收藏不存在”而失败；
        // 回退到“不恢复”，避免留下无法保存的非法设置。
        if settings.startupBookmarkID == id {
            settings.startupBookmarkID = nil
            settings.startupPolicy = .doNotRestore
            persistSettings()
        }
        persistLibrary()
        persistSessions()
    }

    public func setBookmarkPinned(id: UUID, pinned: Bool) {
        guard var bookmark = library.bookmark(id: id) else { return }
        bookmark.dynamicConfig.isPinned = pinned
        library.updateBookmark(bookmark)
        persistLibrary()
    }

    public func setBlockingEnabled(id: UUID, enabled: Bool) {
        guard var bookmark = library.bookmark(id: id) else { return }
        bookmark.blockingEnabled = enabled
        library.updateBookmark(bookmark)
        persistLibrary()
    }

    public func updateLastURL(bookmarkID: UUID, url: String) {
        guard var bookmark = library.bookmark(id: bookmarkID) else { return }
        guard bookmark.lastURL != url else { return }
        bookmark.lastURL = url
        library.updateBookmark(bookmark)
        persistLibrary()
    }

    public func moveBookmark(id: UUID, toGroup groupID: UUID?, at index: Int) {
        if let groupID, library.group(id: groupID) == nil { return }
        library.moveBookmark(id: id, toGroup: groupID, at: index)
        persistLibrary()
    }

    public func moveRootItem(id: UUID, to index: Int) {
        library.moveRootItem(id: id, to: index)
        persistLibrary()
    }

    // MARK: Groups

    @discardableResult
    public func createGroup(name: String) throws -> BookmarkGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppStoreError.invalidName }
        let group = BookmarkGroup(name: trimmed)
        library.insertGroup(group, at: library.rootOrder.count)
        persistLibrary()
        return group
    }

    public func renameGroup(id: UUID, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppStoreError.invalidName }
        guard let index = library.groupIndex(id: id) else { throw AppStoreError.groupNotFound }
        library.groups[index].name = trimmed
        persistLibrary()
    }

    public func deleteGroup(id: UUID) {
        library.removeGroup(id: id)
        persistLibrary()
    }

    public func setGroupExpanded(id: UUID, expanded: Bool) {
        guard let index = library.groupIndex(id: id) else { return }
        library.groups[index].isExpanded = expanded
        persistLibrary()
    }

    // MARK: Sessions

    @discardableResult
    public func createSession(name: String? = nil) -> Session {
        let index = sessions.count + 1
        let session = Session(name: name ?? "聚合 \(index)")
        sessions.append(session)
        settings.lastSessionID = session.id
        persistSessions()
        persistSettings()
        return session
    }

    public func renameSession(id: UUID, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppStoreError.invalidName }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw AppStoreError.sessionNotFound }
        sessions[index].name = trimmed
        persistSessions()
    }

    public func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        if settings.lastSessionID == id {
            settings.lastSessionID = sessions.first?.id
            persistSettings()
        }
        persistSessions()
    }

    public func selectSession(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        guard settings.lastSessionID != id else { return }
        settings.lastSessionID = id
        persistSettings()
    }

    public func splitPane(sessionID: UUID, paneID: UUID?, axis: SplitAxis) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].splitPane(id: paneID, axis: axis)
        persistSessions()
    }

    public func closePane(sessionID: UUID, paneID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].closePane(id: paneID)
        persistSessions()
    }

    public func assignBookmark(_ bookmarkID: UUID, sessionID: UUID, paneID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].assignBookmark(bookmarkID, to: paneID)
        persistSessions()
    }

    public func clearPane(sessionID: UUID, paneID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].assignBookmark(nil, to: paneID)
        persistSessions()
    }

    public func focusPane(sessionID: UUID, paneID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard sessions[index].focusedPaneID != paneID else { return }
        sessions[index].focusedPaneID = paneID
        persistSessions()
    }

    public func zoomPane(sessionID: UUID, paneID: UUID, zoomed: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].zoomedPaneID = zoomed ? paneID : nil
        persistSessions()
    }

    public func updateSplitRatio(sessionID: UUID, splitID: UUID, ratio: Double) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].updateSplitRatio(splitID: splitID, ratio: ratio)
        persistSessions()
    }

    // MARK: Settings

    public func updateSettings(_ settings: AppSettings) throws {
        var normalized = settings
        normalized.normalize()
        if let error = normalized.validationError {
            throw AppStoreError.invalidSettings(error)
        }
        if normalized.startupPolicy != .openBookmark {
            normalized.startupBookmarkID = nil
        } else if let bookmarkID = normalized.startupBookmarkID, library.bookmark(id: bookmarkID) == nil {
            normalized.startupBookmarkID = nil
            throw AppStoreError.invalidSettings("指定的启动收藏不存在")
        }
        self.settings = normalized
        persistSettings()
    }

    public func updateGlobalProxy(_ proxy: ProxySettings) throws {
        guard proxy.isValid else {
            throw AppStoreError.invalidProxy(proxy.validationError ?? "代理配置无效")
        }
        var settings = self.settings
        settings.globalProxy = proxy.normalized
        try updateSettings(settings)
    }

    public func setStartupPolicy(_ policy: StartupPolicy, bookmarkID: UUID? = nil) throws {
        var settings = self.settings
        settings.startupPolicy = policy
        settings.startupBookmarkID = policy == .openBookmark ? bookmarkID : nil
        try updateSettings(settings)
    }

    // MARK: Static cache

    public func store(_ document: CachedDocument, for bookmarkID: UUID) {
        try? cache.save(document, for: bookmarkID)
    }

    public func removeCachedDocument(for bookmarkID: UUID) {
        try? cache.delete(bookmarkID: bookmarkID)
    }
}
