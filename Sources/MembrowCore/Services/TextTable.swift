import Foundation

/// 等宽文本表格：诊断信息用它排版，比一长串 `key：value` 更容易扫读。
public enum TextTable {
    /// - Parameters:
    ///   - headers: 表头单元格。
    ///   - rows: 数据行，单元格数量不足时按空串补齐。
    public static func render(headers: [String], rows: [[String]]) -> String {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return "" }

        var widths = Array(repeating: 0, count: columnCount)
        for row in [headers] + rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], cellWidth(cell))
            }
        }

        func line(_ cells: [String]) -> String {
            var parts: [String] = []
            for index in 0..<columnCount {
                let cell = index < cells.count ? cells[index] : ""
                parts.append(cell + String(repeating: " ", count: max(0, widths[index] - cellWidth(cell))))
            }
            return parts.joined(separator: "  ")
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }

        var lines = [line(headers)]
        lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: rows.map(line))
        return lines.joined(separator: "\n")
    }

    /// 中日韩全角字符按 2 列计算，保证等宽字体下竖列对齐。
    static func cellWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
