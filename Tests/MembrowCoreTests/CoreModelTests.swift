import Foundation
import Testing
@testable import MembrowCore

@Suite(.serialized)
@MainActor
struct CoreModelTests {
    private func makeStore(now: @escaping () -> Date = Date.init) throws -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MembrowTests-\(UUID().uuidString)")
        let store = try AppStore(directory: url, now: now)
        return (store, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func duplicateURLsHaveIndependentIDsAndSettings() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let first = try store.createBookmark(name: "A", entryURL: "https://example.com", kind: .dynamic)
        let second = try store.createBookmark(name: "B", entryURL: "https://example.com", kind: .dynamic)
        #expect(first.id != second.id)

        var updatedFirst = first
        updatedFirst.lastURL = "https://example.com/page-a"
        updatedFirst.dynamicConfig.isPinned = true
        try store.updateBookmark(updatedFirst)

        #expect(store.bookmark(id: first.id)?.lastURL == "https://example.com/page-a")
        #expect(store.bookmark(id: second.id)?.lastURL == nil)
        #expect(store.bookmark(id: first.id)?.isPinned == true)
        #expect(store.bookmark(id: second.id)?.isPinned == false)
    }

    @Test func persistenceReloadKeepsOrderAndConfiguration() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let group = try store.createGroup(name: "工作")
        let first = try store.createBookmark(name: "一", entryURL: "https://one.example.com", kind: .dynamic)
        let second = try store.createBookmark(name: "二", entryURL: "https://two.example.com", kind: .staticPage)
        store.moveBookmark(id: first.id, toGroup: group.id, at: 0)
        store.moveBookmark(id: second.id, toGroup: group.id, at: 1)
        store.setGroupExpanded(id: group.id, expanded: false)

        var bookmark = try #require(store.bookmark(id: second.id))
        bookmark.staticConfig.ttl = .minutes(30)
        bookmark.staticConfig.extraction = ExtractionRule(kind: .css, cssSelector: "article")
        bookmark.proxy = ProxySettings(mode: .custom, host: "127.0.0.1", port: 7890)
        try store.updateBookmark(bookmark)

        let reloaded = try AppStore(directory: directory)
        #expect(reloaded.library.groups.first?.isExpanded == false)
        #expect(reloaded.library.bookmarks(inGroup: group.id).map(\.id) == [first.id, second.id])
        #expect(reloaded.bookmark(id: second.id)?.staticConfig.ttl == .minutes(30))
        #expect(reloaded.bookmark(id: second.id)?.staticConfig.extraction.cssSelector == "article")
        #expect(reloaded.bookmark(id: second.id)?.proxy?.port == 7890)
    }

    @Test func editURLKeepsIDAndCacheConfiguration() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        var bookmark = try store.createBookmark(name: "站点", entryURL: "https://old.example.com", kind: .staticPage)
        bookmark.staticConfig.ttl = .minutes(90)
        try store.updateBookmark(bookmark)
        let document = CachedDocument(
            markdown: "# Cached",
            metadata: StaticMetadata(title: "t", sourceURL: bookmark.entryURL,
                                     extractionKind: .css, captureMode: .webView),
            fetchedAt: Date()
        )
        store.store(document, for: bookmark.id)

        bookmark.entryURL = "https://new.example.com"
        try store.updateBookmark(bookmark)

        #expect(store.bookmark(id: bookmark.id)?.id == bookmark.id)
        #expect(store.bookmark(id: bookmark.id)?.staticConfig.ttl == .minutes(90))
        #expect(store.cachedDocument(for: bookmark.id)?.markdown == "# Cached")
    }

    @Test func deleteBookmarkDoesNotAffectSameURLBookmark() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let first = try store.createBookmark(name: "A", entryURL: "https://same.example.com", kind: .dynamic)
        let second = try store.createBookmark(name: "B", entryURL: "https://same.example.com", kind: .dynamic)
        store.deleteBookmark(id: first.id)
        #expect(store.bookmark(id: first.id) == nil)
        #expect(store.bookmark(id: second.id) != nil)
    }

    @Test func groupingIsSingleLevelAndDeleteGroupKeepsBookmarks() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let group = try store.createGroup(name: "G")
        let bookmark = try store.createBookmark(name: "A", entryURL: "https://a.example.com", kind: .dynamic)
        store.moveBookmark(id: bookmark.id, toGroup: group.id, at: 0)
        #expect(store.library.bookmarks(inGroup: group.id).count == 1)

        store.deleteGroup(id: group.id)
        #expect(store.bookmark(id: bookmark.id)?.groupID == nil)
        #expect(store.library.rootOrder.contains(bookmark.id))
    }

    @Test func sessionSplitCloseZoomAndPersistence() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let session = store.createSession(name: "布局")
        let firstPane = try #require(session.root?.firstPane)
        store.splitPane(sessionID: session.id, paneID: firstPane.id, axis: .vertical)
        var current = try #require(store.session(id: session.id))
        #expect(current.allPanes.count == 2)
        let secondPane = try #require(current.allPanes.last)
        store.assignBookmark(UUID(), sessionID: session.id, paneID: secondPane.id)
        store.zoomPane(sessionID: session.id, paneID: firstPane.id, zoomed: true)

        current = try #require(store.session(id: session.id))
        #expect(current.zoomedPaneID == firstPane.id)

        store.closePane(sessionID: session.id, paneID: secondPane.id)
        current = try #require(store.session(id: session.id))
        #expect(current.allPanes.map(\.id) == [firstPane.id])
        #expect(current.zoomedPaneID == nil)

        store.closePane(sessionID: session.id, paneID: firstPane.id)
        current = try #require(store.session(id: session.id))
        #expect(current.root == nil)
        #expect(current.focusedPaneID == nil)

        store.splitPane(sessionID: session.id, paneID: nil, axis: .horizontal)
        current = try #require(store.session(id: session.id))
        #expect(current.allPanes.count == 1)

        let reloaded = try AppStore(directory: directory)
        #expect(reloaded.session(id: session.id)?.allPanes.count == 1)
    }

    @Test func settingsValidationAndHardConcurrencyLimit() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        var settings = store.settings
        settings.staticConcurrency = 99
        settings.maxInstancesWhenDegraded = 0
        settings.staticCaptureTimeout = 0
        try store.updateSettings(settings)
        #expect(store.settings.staticConcurrency == 4)
        #expect(store.settings.maxInstancesWhenDegraded == 1)
        #expect(store.settings.staticCaptureTimeout == 1)

        var invalid = store.settings
        invalid.globalProxy = ProxySettings(mode: .custom, host: "", port: 0)
        #expect(throws: AppStoreError.self) {
            try store.updateSettings(invalid)
        }
        #expect(store.settings.globalProxy.mode == .direct)
    }

    @Test func proxyResolutionInheritanceAndIsolation() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        var settings = store.settings
        settings.globalProxy = ProxySettings(mode: .custom, host: "10.0.0.1", port: 8080)
        try store.updateSettings(settings)

        let first = try store.createBookmark(name: "A", entryURL: "https://same.example.com", kind: .dynamic)
        let second = try store.createBookmark(name: "B", entryURL: "https://same.example.com", kind: .dynamic)
        var secondUpdated = second
        secondUpdated.proxy = ProxySettings(mode: .custom, host: "10.0.0.2", port: 9090)
        try store.updateBookmark(secondUpdated)

        #expect(store.resolvedProxy(for: try #require(store.bookmark(id: first.id))).proxy.host == "10.0.0.1")
        #expect(store.resolvedProxy(for: try #require(store.bookmark(id: second.id))).proxy.host == "10.0.0.2")
        #expect(store.resolvedProxy(for: try #require(store.bookmark(id: second.id))).source == .bookmark)
    }

    @Test func ttlEvaluatorModes() {
        let evaluator = TTLEvaluator(globalMinutes: 60)
        let now = Date(timeIntervalSince1970: 20_000)
        #expect(evaluator.freshness(ttl: .inherit, fetchedAt: nil, now: now) == .missing)
        #expect(evaluator.freshness(ttl: .inherit, fetchedAt: now.addingTimeInterval(-30 * 60), now: now) == .fresh)
        #expect(evaluator.freshness(ttl: .inherit, fetchedAt: now.addingTimeInterval(-61 * 60), now: now) == .stale)
        #expect(evaluator.freshness(ttl: .noCache, fetchedAt: now, now: now) == .stale)
        #expect(evaluator.freshness(ttl: .neverExpires, fetchedAt: now.addingTimeInterval(-10_000_000), now: now) == .fresh)
        #expect(evaluator.freshness(ttl: .minutes(10), fetchedAt: now.addingTimeInterval(-5 * 60), now: now) == .fresh)
        #expect(evaluator.freshness(ttl: .minutes(10), fetchedAt: now.addingTimeInterval(-11 * 60), now: now) == .stale)
    }

    @Test func cacheStoreIsolatesByBookmarkID() throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let first = try store.createBookmark(name: "A", entryURL: "https://same.example.com", kind: .staticPage)
        let second = try store.createBookmark(name: "B", entryURL: "https://same.example.com", kind: .staticPage)
        let metadata = StaticMetadata(title: "A", sourceURL: first.entryURL, extractionKind: .css, captureMode: .webView)
        store.store(CachedDocument(markdown: "A body", metadata: metadata, fetchedAt: Date()), for: first.id)

        #expect(store.cachedDocument(for: first.id)?.markdown == "A body")
        #expect(store.cachedDocument(for: second.id) == nil)

        let reloaded = try AppStore(directory: directory)
        #expect(reloaded.cachedDocument(for: first.id)?.markdown == "A body")
    }

    @Test func memoryPreciseBudgetEvictsLRUAndExemptsVisiblePinned() {
        let now = Date()
        let samples = [
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false, isPinned: false,
                                 lastVisibleAt: now.addingTimeInterval(-100)),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false, isPinned: false,
                                 lastVisibleAt: now.addingTimeInterval(-200)),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: true, isPinned: false,
                                 lastVisibleAt: now.addingTimeInterval(-300)),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 400_000_000, isVisible: false, isPinned: true,
                                 lastVisibleAt: now.addingTimeInterval(-400)),
        ]
        let plan = MemoryGovernor.plan(samples: samples, mode: .precise(budgetBytes: MemoryGovernor.dynamicBudgetBytes))
        #expect(plan.evict == [samples[1].bookmarkID])
        #expect(plan.overage.isEmpty)
        #expect(plan.totalFootprint == 1_200_000_000)
    }

    @Test func memoryOverageWhenNothingEvictable() {
        let samples = [
            InstanceMemorySample(bookmarkID: UUID(), footprint: 700_000_000, isVisible: true, isPinned: false, lastVisibleAt: Date()),
            InstanceMemorySample(bookmarkID: UUID(), footprint: 600_000_000, isVisible: false, isPinned: true, lastVisibleAt: Date()),
        ]
        let plan = MemoryGovernor.plan(samples: samples, mode: .precise(budgetBytes: MemoryGovernor.dynamicBudgetBytes))
        #expect(plan.evict.isEmpty)
        #expect(plan.overage == [samples[0].bookmarkID, samples[1].bookmarkID])
        #expect(plan.reason == .overBudget)
    }

    @Test func degradedModeUsesInstanceLimit() {
        var samples: [InstanceMemorySample] = []
        for _ in 0..<5 {
            samples.append(InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: true, isPinned: false, lastVisibleAt: Date()))
        }
        let under = MemoryGovernor.plan(samples: samples, mode: .degraded(instanceLimit: 6, pressure: .normal))
        #expect(under.evict.isEmpty)

        let over = MemoryGovernor.plan(samples: samples, mode: .degraded(instanceLimit: 4, pressure: .normal))
        #expect(over.evict.isEmpty) // 全部可见，豁免淘汰
        #expect(over.reason == .instanceLimit)
        #expect(over.overage.count == 5)
    }

    @Test func degradedEvictionSkipsVisibleAndPinned() {
        let now = Date()
        let pinned = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: false, isPinned: true,
                                          lastVisibleAt: now.addingTimeInterval(-500))
        let visible = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: true, isPinned: false,
                                           lastVisibleAt: now.addingTimeInterval(-400))
        let old = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: false, isPinned: false,
                                       lastVisibleAt: now.addingTimeInterval(-300))
        let recent = InstanceMemorySample(bookmarkID: UUID(), footprint: 100, isVisible: false, isPinned: false,
                                          lastVisibleAt: now.addingTimeInterval(-100))
        let plan = MemoryGovernor.plan(samples: [pinned, visible, old, recent],
                                       mode: .degraded(instanceLimit: 2, pressure: .normal))
        #expect(plan.evict == [old.bookmarkID, recent.bookmarkID])
        #expect(plan.overage.isEmpty)
    }
}
