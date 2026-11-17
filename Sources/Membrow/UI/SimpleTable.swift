import AppKit

/// 只读表格控件：定宽列 + 斑马纹，用于设置窗口里的诊断信息。
@MainActor
final class SimpleTable: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let columns: [String]
    private var rows: [[String]] = []
    private var heightConstraint: NSLayoutConstraint?

    private static let rowHeight: CGFloat = 18
    private static let headerHeight: CGFloat = 24

    init(columns: [String], widths: [CGFloat]) {
        self.columns = columns
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for (index, title) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column\(index)"))
            column.title = title
            column.width = index < widths.count ? widths[index] : 80
            column.minWidth = 40
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 6, height: 0)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let height = heightAnchor.constraint(equalToConstant: Self.headerHeight + 4)
        height.isActive = true
        heightConstraint = height
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRows(_ rows: [[String]]) {
        self.rows = rows
        tableView.reloadData()
        // 行数变化时同步高度，避免留白或截断；外层滚动视图负责整体滚动。
        let content = Self.headerHeight + CGFloat(max(rows.count, 1)) * Self.rowHeight + 4
        heightConstraint?.constant = content
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let index = tableView.tableColumns.firstIndex(of: tableColumn),
              row < rows.count, index < rows[row].count else { return nil }
        let identifier = tableColumn.identifier
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = NSFont.systemFont(ofSize: 11)
            field.lineBreakMode = .byTruncatingTail
        }
        field.stringValue = rows[row][index]
        return field
    }
}
