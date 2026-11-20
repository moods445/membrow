import Foundation
import SQLite3

public struct StaticMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var sourceURL: String
    public var extractionKind: ExtractionKind
    public var captureMode: CaptureMode

    public init(title: String, sourceURL: String, extractionKind: ExtractionKind, captureMode: CaptureMode) {
        self.title = title
        self.sourceURL = sourceURL
        self.extractionKind = extractionKind
        self.captureMode = captureMode
    }
}

public struct CachedDocument: Codable, Equatable, Sendable {
    public var markdown: String
    public var metadata: StaticMetadata
    public var fetchedAt: Date
    /// 精简快照（清洗后的 HTML）；只有“精简快照”显示方式才会写入。
    public var snapshotHTML: String?

    public init(markdown: String, metadata: StaticMetadata, fetchedAt: Date, snapshotHTML: String? = nil) {
        self.markdown = markdown
        self.metadata = metadata
        self.fetchedAt = fetchedAt
        self.snapshotHTML = snapshotHTML
    }
}

public enum StaticCacheError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "缓存数据库打开失败：\(message)"
        case .prepareFailed(let message): return "缓存数据库语句准备失败：\(message)"
        case .stepFailed(let message): return "缓存数据库执行失败：\(message)"
        case .decodeFailed(let message): return "缓存数据解析失败：\(message)"
        }
    }
}

/// 以收藏 ID 为键的 SQLite 静态缓存。
public final class StaticCacheStore {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let path: URL

    public init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StaticCacheError.openFailed(message)
        }
        database = handle
        try execute("""
        CREATE TABLE IF NOT EXISTS static_cache (
            bookmark_id TEXT PRIMARY KEY NOT NULL,
            markdown TEXT NOT NULL,
            metadata TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            snapshot_html TEXT
        );
        """)
        // 旧库没有 snapshot_html 列：只有“列已存在”可以忽略。
        // 其余失败（只读库/磁盘满/被锁）必须上抛，否则会拖到第一次写入才报误导性的语句错误。
        do {
            try execute("ALTER TABLE static_cache ADD COLUMN snapshot_html TEXT;")
        } catch {
            let message = error.localizedDescription.lowercased()
            if !message.contains("duplicate column") {
                sqlite3_close(database)
                self.database = nil
                throw error
            }
        }
    }

    deinit {
        sqlite3_close(database)
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw StaticCacheError.openFailed("database closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw StaticCacheError.stepFailed(message)
        }
    }

    public func save(_ document: CachedDocument, for bookmarkID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw StaticCacheError.openFailed("database closed") }
        let metadataData = try JSONEncoder().encode(document.metadata)
        let metadata = String(data: metadataData, encoding: .utf8) ?? "{}"
        let sql = """
        INSERT INTO static_cache (bookmark_id, markdown, metadata, fetched_at, snapshot_html)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(bookmark_id) DO UPDATE SET
            markdown = excluded.markdown,
            metadata = excluded.metadata,
            fetched_at = excluded.fetched_at,
            snapshot_html = excluded.snapshot_html;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StaticCacheError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(bookmarkID.uuidString, to: statement, at: 1)
        bind(document.markdown, to: statement, at: 2)
        bind(metadata, to: statement, at: 3)
        sqlite3_bind_double(statement, 4, document.fetchedAt.timeIntervalSince1970)
        if let snapshot = document.snapshotHTML {
            bind(snapshot, to: statement, at: 5)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StaticCacheError.stepFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    public func load(bookmarkID: UUID) throws -> CachedDocument? {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw StaticCacheError.openFailed("database closed") }
        let sql = "SELECT markdown, metadata, fetched_at, snapshot_html FROM static_cache WHERE bookmark_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StaticCacheError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(bookmarkID.uuidString, to: statement, at: 1)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            return nil
        }
        // 之前把所有非 SQLITE_ROW 都当作“无缓存”，会掩盖数据库损坏等真实错误。
        guard step == SQLITE_ROW else {
            throw StaticCacheError.stepFailed(String(cString: sqlite3_errmsg(database)))
        }
        guard let markdownCString = sqlite3_column_text(statement, 0),
              let metadataCString = sqlite3_column_text(statement, 1) else {
            throw StaticCacheError.decodeFailed("存在空列")
        }
        let markdown = String(cString: markdownCString)
        let metadataString = String(cString: metadataCString)
        let fetchedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let snapshotHTML = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        guard let metadataData = metadataString.data(using: .utf8) else {
            throw StaticCacheError.decodeFailed("元信息编码无效")
        }
        let metadata = try JSONDecoder().decode(StaticMetadata.self, from: metadataData)
        return CachedDocument(markdown: markdown,
                              metadata: metadata,
                              fetchedAt: fetchedAt,
                              snapshotHTML: snapshotHTML)
    }

    public func delete(bookmarkID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw StaticCacheError.openFailed("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM static_cache WHERE bookmark_id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw StaticCacheError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(bookmarkID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StaticCacheError.stepFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("DELETE FROM static_cache;")
    }

    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
