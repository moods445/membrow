import AppKit
import MembrowCore

enum MembrowPasteboard {
    static let bookmark = NSPasteboard.PasteboardType("com.membrow.bookmark-id")
    static let group = NSPasteboard.PasteboardType("com.membrow.group-id")
}

struct BookmarkStatus {
    let symbol: String
    let text: String
    let detail: String

    var display: String { "\(symbol) \(text)" }
}

@MainActor
extension AppEnvironment {
    func status(for bookmark: Bookmark) -> BookmarkStatus {
        if bookmark.kind == .staticPage {
            if case .failed(let message) = staticManager.phase(for: bookmark.id) {
                return BookmarkStatus(symbol: "!", text: "错误", detail: message)
            }
            if staticManager.isUpdating(bookmark.id) {
                return BookmarkStatus(symbol: "↻", text: "更新中", detail: "正在抓取正文")
            }
            switch store.freshness(for: bookmark) {
            case .fresh:
                return BookmarkStatus(symbol: "●", text: "已缓存", detail: "缓存新鲜")
            case .stale:
                return BookmarkStatus(symbol: "◐", text: "缓存过期", detail: "需要更新")
            case .missing:
                return BookmarkStatus(symbol: "○", text: "无缓存", detail: "尚未抓取")
            }
        }

        if let instance = runtime.instance(for: bookmark.id) {
            let pinSuffix = bookmark.isPinned ? " · 固定" : ""
            return BookmarkStatus(symbol: "●",
                                  text: "运行中\(pinSuffix)",
                                  detail: instance.lastError ?? (instance.webView.url?.absoluteString ?? ""))
        }
        if let termination = runtime.termination(for: bookmark.id) {
            switch termination {
            case .evicted:
                return BookmarkStatus(symbol: "▼", text: "已回收", detail: "可由 LRU 重新载入")
            case .closed:
                return BookmarkStatus(symbol: "○", text: "已关闭", detail: "收藏与登录态保留")
            case .crashed:
                return BookmarkStatus(symbol: "!", text: "进程结束", detail: "网页进程已结束")
            }
        }
        let pinSuffix = bookmark.isPinned ? " · 固定" : ""
        return BookmarkStatus(symbol: "○", text: "未启动\(pinSuffix)", detail: "")
    }
}

func makeLabel(_ text: String = "",
               font: NSFont,
               color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

func makeHeaderButton(title: String,
                      toolTip: String,
                      target: AnyObject?,
                      action: Selector?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = NSFont.systemFont(ofSize: 12)
    button.toolTip = toolTip
    return button
}

@MainActor
final class MessageView: NSView {
    private let symbolLabel = makeLabel("○", font: NSFont.systemFont(ofSize: 26, weight: .light), color: .tertiaryLabelColor)
    private let titleLabel = makeLabel("", font: NSFont.systemFont(ofSize: 14, weight: .medium))
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.maximumNumberOfLines = 4

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(trigger)
        actionButton.isHidden = true

        stack.addArrangedSubview(symbolLabel)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(actionButton)
        addSubview(stack)

        // 左右留白用非必需优先级：Pane 首次布局宽度为 0 时不与居中约束硬冲突。
        let leadingInset = stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20)
        leadingInset.priority = .defaultHigh
        let trailingInset = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
        trailingInset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingInset,
            trailingInset,
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
    }

    func configure(symbol: String,
                   title: String,
                   detail: String = "",
                   actionTitle: String? = nil,
                   action: (() -> Void)? = nil) {
        symbolLabel.stringValue = symbol
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        self.action = action
        if let actionTitle, action != nil {
            actionButton.title = actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    @objc private func trigger() {
        action?()
    }
}
