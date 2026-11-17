import AppKit
import MembrowCore

@MainActor
final class MemoryBannerView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttonStack = NSStackView()
    private var items: [MemoryMonitor.OverageItem] = []

    var onUnpin: ((UUID) -> Void)?
    var onClosePage: ((UUID) -> Void)?

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
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        addSubview(label)

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6
        addSubview(buttonStack)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -8),

            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(items: [MemoryMonitor.OverageItem]) {
        self.items = items
        for view in buttonStack.arrangedSubviews {
            buttonStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !items.isEmpty else {
            label.stringValue = ""
            return
        }

        let names = items.prefix(3).map { item in
            "\(item.name)（\(MemoryProbe.formatted(item.footprint))）"
        }.joined(separator: "、")
        label.stringValue = "内存超限：超出预算，固定页面仍在占用：\(names)"

        for item in items.prefix(3) {
            let title = item.isPinned ? "取消固定 \(item.name)" : "关闭 \(item.name)"
            let button = NSButton(title: title, target: self, action: #selector(handleItem(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11)
            button.tag = items.firstIndex { $0.bookmarkID == item.bookmarkID } ?? 0
            buttonStack.addArrangedSubview(button)
        }
    }

    @objc private func handleItem(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        let item = items[sender.tag]
        if item.isPinned {
            onUnpin?(item.bookmarkID)
        } else {
            onClosePage?(item.bookmarkID)
        }
    }
}
