import Foundation
import ServiceManagement

/// 开机自启：用 macOS 13+ 的 `SMAppService.mainApp` 把主应用注册为系统登录项。
/// ponytail: 不引入 helper app / LaunchAgent plist；应用需位于 /Applications 且签名稳定，
/// 否则系统可能拒绝注册或每次重建都被当成新应用。
@MainActor
enum LaunchAtLogin {
    /// 系统侧实际状态（设置窗口显示这个，而不是 settings.json 里记录的意向）。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "已开启"
        case .requiresApproval:
            return "待系统设置批准"
        case .notFound:
            return "未找到登录项"
        case .notRegistered:
            return "未开启"
        @unknown default:
            return "未知"
        }
    }

    /// 返回 nil 表示系统已接受变更；否则返回可直接展示给用户的失败原因。
    static func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
                if service.status == .requiresApproval {
                    return "已提交登录项，请在“系统设置 › 通用 › 登录项”中允许 Membrow"
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            return nil
        } catch {
            return "更新登录项失败：\(error.localizedDescription)"
        }
    }
}
