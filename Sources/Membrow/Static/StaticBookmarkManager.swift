import Foundation
import MembrowCore

@MainActor
final class StaticBookmarkManager {
    enum Phase: Equatable {
        case idle
        case updating
        case failed(String)
    }

    private let store: AppStore
    private let service: StaticCaptureService
    private var phases: [UUID: Phase] = [:]

    var onChange: (() -> Void)?

    init(store: AppStore, sharedWebData: SharedWebData) {
        self.store = store
        self.service = StaticCaptureService(store: store, sharedWebData: sharedWebData)
    }

    func phase(for bookmarkID: UUID) -> Phase {
        phases[bookmarkID] ?? .idle
    }

    func isUpdating(_ bookmarkID: UUID) -> Bool {
        phase(for: bookmarkID) == .updating
    }

    func failureMessage(for bookmarkID: UUID) -> String? {
        if case .failed(let message) = phase(for: bookmarkID) {
            return message
        }
        return nil
    }

    func document(for bookmarkID: UUID) -> CachedDocument? {
        store.cachedDocument(for: bookmarkID)
    }

    func present(bookmarkID: UUID, allowAutoCapture: Bool, forceRefresh: Bool = false) {
        guard let bookmark = store.bookmark(id: bookmarkID), bookmark.kind == .staticPage else { return }
        if forceRefresh {
            startCapture(bookmark, force: true)
            return
        }
        let freshness = store.freshness(for: bookmark)
        if allowAutoCapture && freshness != .fresh {
            startCapture(bookmark, force: false)
        }
    }

    func forceRefresh(bookmarkID: UUID) {
        guard let bookmark = store.bookmark(id: bookmarkID), bookmark.kind == .staticPage else { return }
        startCapture(bookmark, force: true)
    }

    func clearPhase(for bookmarkID: UUID) {
        phases[bookmarkID] = nil
    }

    private func startCapture(_ bookmark: Bookmark, force: Bool) {
        guard phase(for: bookmark.id) != .updating else { return }
        if !force, store.freshness(for: bookmark) == .fresh {
            return
        }

        phases[bookmark.id] = .updating
        onChange?()

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.capture(bookmark: bookmark)
                let extracted = try ExtractorFactory.extract(html: result.html,
                                                             pageURL: result.finalURL,
                                                             rule: bookmark.staticConfig.extraction)
                // 快照模式额外存一份精简后的 HTML（去脚本/事件/表单，保留样式布局）。
                let snapshot = bookmark.staticConfig.displayMode == .snapshot
                    ? HTMLSnapshotSanitizer.sanitize(html: result.html)
                    : nil
                let document = CachedDocument(
                    markdown: extracted.markdown,
                    metadata: StaticMetadata(title: extracted.title,
                                             sourceURL: result.finalURL.absoluteString,
                                             extractionKind: extracted.extractionKind,
                                             captureMode: bookmark.staticConfig.captureMode),
                    fetchedAt: self.store.now(),
                    snapshotHTML: snapshot?.isEmpty == false ? snapshot : nil
                )
                // 抓取期间收藏可能被删除或改为动态：此时写入会留下孤儿缓存（删除后又被写回）。
                guard let current = self.store.bookmark(id: bookmark.id), current.kind == .staticPage else {
                    self.phases[bookmark.id] = nil
                    self.onChange?()
                    return
                }
                do {
                    try self.store.saveCachedDocument(document, for: bookmark.id)
                    self.phases[bookmark.id] = .idle
                } catch {
                    self.phases[bookmark.id] = .failed("缓存写入失败：\(error.localizedDescription)")
                }
            } catch {
                self.phases[bookmark.id] = .failed(error.localizedDescription)
            }
            self.onChange?()
        }
    }
}
