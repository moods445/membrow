import Foundation

/// 侧栏显示模式：最窄只保留一列图标，点击状态栏按钮在两种模式间循环。
public enum SidebarDisplayMode: String, Codable, CaseIterable, Sendable {
    /// 仅图标栏（宽度固定，不能继续拖动收窄）。
    case rail
    /// 完整侧栏（图标 + 标题文字，可拖动宽度）。
    case expanded

    /// 循环点击的下一个模式：图标栏 → 完整 → 图标栏。
    public var next: SidebarDisplayMode {
        self == .rail ? .expanded : .rail
    }

    public var displayName: String {
        switch self {
        case .rail: return "仅图标"
        case .expanded: return "图标 + 标题"
        }
    }

    /// 状态栏切换按钮的提示文案：描述点击后会发生什么。
    public var toggleLabel: String {
        switch self {
        case .rail: return "展开侧栏（图标 + 标题）"
        case .expanded: return "收起为仅图标栏"
        }
    }
}

/// 侧栏两种模式的尺寸常量。
public enum SidebarLayout {
    /// 仅图标栏宽度：一列 19pt 图标 + 左右留白。
    public static let railWidth: CGFloat = 52
    /// 完整侧栏最小可用宽度：拖到该宽度以下会自动切到图标栏。
    public static let expandedMinimumWidth: CGFloat = 180
    /// 展开时若无历史宽度可恢复，使用该默认值。
    public static let expandedDefaultWidth: CGFloat = 260
    /// 完整侧栏最大宽度占窗口宽度的比例。
    public static let expandedMaximumWidthRatio: CGFloat = 0.3
    /// 图标栏单个图标的边长：原 28pt 缩为 2/3（18.67）后取整，保持字模清晰。
    public static let railIconSize: CGFloat = 19
}
