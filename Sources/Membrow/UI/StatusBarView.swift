import AppKit
import MembrowCore

/// 窗口底部通栏状态栏：左侧切换侧栏模式的小按钮，右侧一行内存文案。
/// 只做展示与事件转发，模式状态与内存数据由主窗口控制器维护。
@MainActor
final class StatusBarView: NSView {
    /// 状态栏固定高度。
    static let height: CGFloat = 26

    /// 点击左侧按钮时回调；按钮本身不改变任何状态。
    var onToggle: (() -> Void)?

    private let toggleButton = NSButton()
    private let separator = NSView()
    private let memoryLabel = makeLabel("", font: NSFont.systemFont(ofSize: 11),
                                        color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // 顶部 1pt 分隔线：独立视图承载，避免依赖 layer 的 sublayer 布局。
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        // 左端 24×24 切换按钮：优先 SF Symbol，缺失时退化为文字“侧栏”。
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.bezelStyle = .inline
        toggleButton.isBordered = false
        toggleButton.font = NSFont.systemFont(ofSize: 11)
        toggleButton.imageScaling = .scaleProportionallyDown
        toggleButton.target = self
        toggleButton.action = #selector(handleToggle)
        // 初始提示，避免在 configure 之前出现空 tooltip / 空辅助功能标签。
        toggleButton.toolTip = SidebarDisplayMode.expanded.toggleLabel
        toggleButton.setAccessibilityLabel(SidebarDisplayMode.expanded.toggleLabel)
        if let image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil) {
            image.isTemplate = true
            toggleButton.image = image
            toggleButton.imagePosition = .imageOnly
        } else {
            toggleButton.title = "侧栏"
            toggleButton.imagePosition = .noImage
        }
        addSubview(toggleButton)

        memoryLabel.translatesAutoresizingMaskIntoConstraints = false
        // 窗口变窄时优先压缩标签，保持按钮与边距不被挤出。
        memoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(memoryLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 24),
            toggleButton.heightAnchor.constraint(equalToConstant: 24),

            memoryLabel.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 8),
            memoryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            memoryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// 父视图按固定高度摆放即可（内部子视图全部相对自身定位）。
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    /// 更新侧栏模式提示与内存文案；模式本身由主窗口控制器保存。
    func configure(mode: SidebarDisplayMode, memoryText: String) {
        toggleButton.toolTip = mode.toggleLabel
        toggleButton.setAccessibilityLabel(mode.toggleLabel)
        memoryLabel.stringValue = memoryText
    }

    @objc private func handleToggle() {
        onToggle?()
    }
}
