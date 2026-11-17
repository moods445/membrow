import AppKit

/// 设置窗口的诊断面板：概览 / 实例 / 配置三张只读表格，整体可上下滚动。
@MainActor
final class DiagnosticsTablesView: NSView {
    private let stack = NSStackView()
    private let statusTable = SimpleTable(columns: ["项目", "值"], widths: [130, 320])
    private let instanceTable = SimpleTable(columns: ["名称", "类型", "状态", "内存"], widths: [190, 50, 50, 90])
    private let configTable = SimpleTable(columns: ["配置", "值"], widths: [130, 320])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        addSubview(stack)

        let tables = [statusTable, instanceTable, configTable]
        for table in tables {
            stack.addArrangedSubview(table)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ] + tables.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 翻转坐标系：让内容从滚动区域顶部开始显示。
    override var isFlipped: Bool { true }

    func update(status: [[String]], instances: [[String]], config: [[String]]) {
        statusTable.setRows(status)
        instanceTable.setRows(instances)
        configTable.setRows(config)
    }
}
