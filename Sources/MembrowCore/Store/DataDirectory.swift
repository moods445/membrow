import Foundation

public enum DataDirectoryError: Error, LocalizedError {
    case applicationSupportUnavailable

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法定位用户的应用支持目录（~/Library/Application Support）"
        }
    }
}

/// 应用数据目录的解析与版本迁移。
///
/// 约定：默认 `<Application Support>/<Bundle Identifier>`；早期版本用的是 `<Application Support>/Membrow`，
/// 首次启动时整体迁移。迁移失败时保留旧目录继续使用，绝不新建空目录顶替（否则用户会以为配置丢失）。
public enum DataDirectory {
    public static let legacyFolderName = "Membrow"

    public static func applicationSupportBase() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            throw DataDirectoryError.applicationSupportUnavailable
        }
        return base
    }

    public static func resolve(base: URL,
                               folderName: String,
                               legacyFolderName: String = DataDirectory.legacyFolderName) throws -> URL {
        let fileManager = FileManager.default
        let directory = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)

        if folderName != legacyFolderName,
           !fileManager.fileExists(atPath: directory.path),
           fileManager.fileExists(atPath: legacy.path) {
            do {
                try fileManager.moveItem(at: legacy, to: directory)
            } catch {
                return legacy
            }
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
