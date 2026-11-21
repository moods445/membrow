import Foundation

/// 应用诊断日志：`info` 与 `warn / error` 分成两个 jsonl 文件，单文件上限 20MB。
///
/// - 行格式：`{"category":"web","level":"info","message":"…","ts":"…","fields":{…}}`，一行一条，便于 `grep`/`jq`。
/// - 超过上限时把当前文件改名为 `<文件名>.1`（只保留一份归档），随后新建空文件继续写。
/// - 写入在串行后台队列进行，不阻塞主线程；未 `configure` 时整条链路直接丢弃（自测/无数据目录时不写盘）。
/// - 只写调用方传入的字段：凭据、表单值不得进入本日志。
///
/// ponytail: 单份归档 + 固定 20MB，够用；要保留更长历史再按份数扩展。
public final class DiagnosticLog: @unchecked Sendable {
    public enum Level: String, Sendable {
        case info
        case warn
        case error
    }

    public static let shared = DiagnosticLog()
    public static let defaultMaxFileBytes = 20 * 1024 * 1024
    public static let infoFileName = "info.jsonl"
    public static let problemFileName = "problems.jsonl"

    private struct Writer {
        let handle: FileHandle
        var bytes: Int
    }

    private let queue = DispatchQueue(label: "com.membrow.diagnostic-log", qos: .utility)
    private let maxFileBytes: Int
    private var directory: URL?
    private var writers: [String: Writer] = [:]

    public init(directory: URL? = nil, maxFileBytes: Int = DiagnosticLog.defaultMaxFileBytes) {
        self.directory = directory
        self.maxFileBytes = max(64, maxFileBytes)
    }

    /// 数据目录确定后调用；传 nil 表示停止写入。
    public func configure(directory: URL?) {
        queue.sync {
            closeWriters()
            self.directory = directory
        }
    }

    public func info(_ message: String, category: String, fields: [String: String] = [:]) {
        write(.info, category: category, message: message, fields: fields)
    }

    public func warn(_ message: String, category: String, fields: [String: String] = [:]) {
        write(.warn, category: category, message: message, fields: fields)
    }

    public func error(_ message: String, category: String, fields: [String: String] = [:]) {
        write(.error, category: category, message: message, fields: fields)
    }

    /// 等待队列里的写入落盘；自测与退出前使用。
    public func flush() {
        queue.sync {}
    }

    public func logDirectory() -> URL? {
        queue.sync { directory }
    }

    // MARK: - 写入

    private func write(_ level: Level,
                       category: String,
                       message: String,
                       fields: [String: String]) {
        queue.async { [weak self] in
            guard let self, let directory = self.directory else { return }
            var entry: [String: Any] = [
                "ts": Date.now.ISO8601Format(),
                "level": level.rawValue,
                "category": category,
                "message": message,
            ]
            if !fields.isEmpty {
                entry["fields"] = fields
            }
            guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
                return
            }
            line.append(0x0A)

            let fileName = level == .info ? Self.infoFileName : Self.problemFileName
            let fileURL = directory.appendingPathComponent(fileName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var writer = try writers[fileName] ?? openWriter(at: fileURL)
                if writer.bytes + line.count > maxFileBytes {
                    try? writer.handle.close()
                    writers[fileName] = nil
                    rotate(fileURL)
                    writer = try openWriter(at: fileURL)
                }
                try writer.handle.write(contentsOf: line)
                writer.bytes += line.count
                writers[fileName] = writer
            } catch {
                // 写日志失败不能影响主流程，也不能再记日志（会递归）。
                closeWriters()
            }
        }
    }

    private func openWriter(at url: URL) throws -> Writer {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        let size = (try? handle.seekToEnd()) ?? 0
        return Writer(handle: handle, bytes: Int(size))
    }

    private func rotate(_ url: URL) {
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    private func closeWriters() {
        for writer in writers.values {
            try? writer.handle.close()
        }
        writers.removeAll()
    }
}
