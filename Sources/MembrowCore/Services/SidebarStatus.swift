import Foundation

/// 底部状态栏的内存文案：把字节数与实例数拼成用户可读的一行。
/// 放在 Core 层是为了让格式本身可被 `MembrowSelfTest` 断言。
public enum MemoryStatusFormatter {
    /// 形如“内存 128 MB / 1 GB · 实例 2”；读不到占用时显示“无法读取”。
    public static func text(totalFootprint: Int64?,
                            budgetMB: Int,
                            dynamicInstances: Int,
                            snapshots: Int) -> String {
        let usage = totalFootprint.map(formattedBytes) ?? "无法读取"
        return "内存 \(usage) / \(formattedBytes(Int64(budgetMB) * 1024 * 1024))"
            + " · 实例 \(dynamicInstances + snapshots)"
    }

    public static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
