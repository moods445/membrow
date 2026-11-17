import Foundation

// MARK: - Results and errors

public struct ExtractionResult: Equatable, Sendable {
    public var markdown: String
    public var title: String
    public var extractionKind: ExtractionKind

    public init(markdown: String, title: String, extractionKind: ExtractionKind) {
        self.markdown = markdown
        self.title = title
        self.extractionKind = extractionKind
    }
}

public enum ExtractionError: Error, Equatable, LocalizedError {
    case selectorNotConfigured
    case selectorNotMatched(String)
    case invalidSelector(String)
    case parseFailed(String)
    case emptyBody
    case genericFailed

    public var errorDescription: String? {
        switch self {
        case .selectorNotConfigured:
            return "未配置 CSS 选择器，提取失败"
        case .selectorNotMatched(let selector):
            return "CSS 选择器未匹配到内容：\(selector)"
        case .invalidSelector(let selector):
            return "CSS 选择器无法解析：\(selector)"
        case .parseFailed(let message):
            return "HTML 解析失败：\(message)"
        case .emptyBody:
            return "提取结果为空正文"
        case .genericFailed:
            return "通用正文提取失败"
        }
    }
}

// MARK: - Tolerant HTML tree

public final class HTMLNode {
    public enum Kind: Equatable {
        case document
        case element
        case text
    }

    public let kind: Kind
    public var name: String?
    public var attributes: [String: String]
    public var text: String?
    public weak var parent: HTMLNode?
    public private(set) var children: [HTMLNode] = []

    public init(document: Void = ()) {
        self.kind = .document
        self.attributes = [:]
    }

    public init(element name: String, attributes: [String: String]) {
        self.kind = .element
        self.name = name
        self.attributes = attributes
    }

    public init(text: String) {
        self.kind = .text
        self.text = text
        self.attributes = [:]
    }

    public func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
    }

    public var textContent: String {
        if kind == .text { return text ?? "" }
        var result = ""
        for child in children {
            result += child.textContent
        }
        return result
    }

    public func attribute(_ name: String) -> String? {
        attributes[name.lowercased()]
    }

    /// 深度优先遍历所有元素。
    public func allElements() -> [HTMLNode] {
        var result: [HTMLNode] = []
        func visit(_ node: HTMLNode) {
            for child in node.children {
                if child.kind == .element {
                    result.append(child)
                }
                visit(child)
            }
        }
        visit(self)
        return result
    }

    public func firstElement(named name: String) -> HTMLNode? {
        if kind == .element, self.name == name { return self }
        for child in children {
            if let found = child.firstElement(named: name) { return found }
        }
        return nil
    }
}

public enum HTMLParser {
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]

    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "main", "nav", "ol", "p", "pre", "section", "table", "ul",
    ]

    public static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode()
        var stack: [HTMLNode] = [root]
        var index = html.startIndex

        func current() -> HTMLNode { stack[stack.count - 1] }

        func closeTag(_ name: String) {
            guard let position = stack.lastIndex(where: { $0.name == name }) else { return }
            if position > 0 {
                stack.removeSubrange(position...)
            }
        }

        while index < html.endIndex {
            let character = html[index]
            if character != "<" {
                var text = ""
                while index < html.endIndex, html[index] != "<" {
                    text.append(html[index])
                    index = html.index(after: index)
                }
                if !text.isEmpty {
                    current().append(HTMLNode(text: decodeEntities(text)))
                }
                continue
            }

            // 注释、DOCTYPE、处理指令
            if html[index...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: index..<html.endIndex) {
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                continue
            }
            if html[index...].hasPrefix("<!") || html[index...].hasPrefix("<?") {
                if let end = html.range(of: ">", range: index..<html.endIndex) {
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                continue
            }

            // 结束标签
            if html[index...].hasPrefix("</") {
                var cursor = html.index(index, offsetBy: 2)
                var name = ""
                while cursor < html.endIndex, isNameCharacter(html[cursor]) {
                    name.append(html[cursor])
                    cursor = html.index(after: cursor)
                }
                if let end = html.range(of: ">", range: cursor..<html.endIndex) {
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                if !name.isEmpty {
                    closeTag(name.lowercased())
                }
                continue
            }

            // 开始标签
            var cursor = html.index(after: index)
            var name = ""
            while cursor < html.endIndex, isNameCharacter(html[cursor]) {
                name.append(html[cursor])
                cursor = html.index(after: cursor)
            }
            if name.isEmpty {
                // 不是合法标签，按文本处理
                current().append(HTMLNode(text: "<"))
                index = html.index(after: index)
                continue
            }
            let tag = name.lowercased()
            var attributes: [String: String] = [:]
            var selfClosing = false
            var closed = false

            while cursor < html.endIndex {
                skipWhitespace(&cursor, html)
                guard cursor < html.endIndex else { break }
                if html[cursor] == ">" {
                    cursor = html.index(after: cursor)
                    closed = true
                    break
                }
                if html[cursor] == "/" {
                    let next = html.index(after: cursor)
                    if next < html.endIndex, html[next] == ">" {
                        selfClosing = true
                        cursor = html.index(after: next)
                        closed = true
                        break
                    }
                    cursor = next
                    continue
                }
                var attributeName = ""
                while cursor < html.endIndex,
                      !html[cursor].isWhitespace,
                      html[cursor] != "=",
                      html[cursor] != ">",
                      html[cursor] != "/" {
                    attributeName.append(html[cursor])
                    cursor = html.index(after: cursor)
                }
                skipWhitespace(&cursor, html)
                var value = ""
                if cursor < html.endIndex, html[cursor] == "=" {
                    cursor = html.index(after: cursor)
                    skipWhitespace(&cursor, html)
                    if cursor < html.endIndex, html[cursor] == "\"" || html[cursor] == "'" {
                        let quote = html[cursor]
                        cursor = html.index(after: cursor)
                        while cursor < html.endIndex, html[cursor] != quote {
                            value.append(html[cursor])
                            cursor = html.index(after: cursor)
                        }
                        if cursor < html.endIndex { cursor = html.index(after: cursor) }
                    } else {
                        while cursor < html.endIndex,
                              !html[cursor].isWhitespace,
                              html[cursor] != ">" {
                            value.append(html[cursor])
                            cursor = html.index(after: cursor)
                        }
                    }
                }
                let key = attributeName.lowercased()
                if !key.isEmpty {
                    attributes[key] = decodeEntities(value)
                }
            }

            if !closed {
                index = html.endIndex
                break
            }
            index = cursor

            // 原始文本元素：整段读取到对应结束标签
            if rawTextElements.contains(tag) {
                let closing = "</\(tag)"
                let searchRange = index..<html.endIndex
                let rawContent: String
                if let range = html.range(of: closing, options: .caseInsensitive, range: searchRange) {
                    rawContent = String(html[index..<range.lowerBound])
                    if let end = html.range(of: ">", range: range.lowerBound..<html.endIndex) {
                        index = end.upperBound
                    } else {
                        index = html.endIndex
                    }
                } else {
                    rawContent = String(html[index..<html.endIndex])
                    index = html.endIndex
                }
                let element = HTMLNode(element: tag, attributes: attributes)
                current().append(element)
                if tag != "title" && tag != "textarea" {
                    // script/style 文本仍保留在树中，由 Markdown 渲染忽略。
                    element.append(HTMLNode(text: rawContent))
                } else if tag == "title" {
                    element.append(HTMLNode(text: decodeEntities(rawContent)))
                } else {
                    element.append(HTMLNode(text: decodeEntities(rawContent)))
                }
                continue
            }

            // 简单隐式闭合规则
            if tag == "li", current().name == "li" { closeTag("li") }
            if tag == "p" || blockElements.contains(tag) { closeTag("p") }
            if ["td", "th"].contains(tag), ["td", "th"].contains(current().name ?? "") {
                closeTag(current().name ?? "")
            }
            if tag == "tr", ["td", "th", "tr"].contains(current().name ?? "") {
                closeTag("td"); closeTag("th"); closeTag("tr")
            }
            if ["dt", "dd"].contains(tag), ["dt", "dd"].contains(current().name ?? "") {
                closeTag(current().name ?? "")
            }
            if tag == "option", current().name == "option" { closeTag("option") }

            let element = HTMLNode(element: tag, attributes: attributes)
            current().append(element)
            if !selfClosing && !voidElements.contains(tag) {
                stack.append(element)
            }
        }

        return root
    }

    public static func title(in root: HTMLNode) -> String {
        if let titleNode = root.firstElement(named: "title") {
            let title = titleNode.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        if let heading = root.firstElement(named: "h1") {
            let text = heading.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
    }

    private static func skipWhitespace(_ index: inout String.Index, _ string: String) {
        while index < string.endIndex, string[index].isWhitespace {
            index = string.index(after: index)
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…",
        "copy": "©", "reg": "®", "trade": "™", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "middot": "·", "bull": "•", "deg": "°",
        "times": "×", "divide": "÷", "euro": "€", "pound": "£", "yen": "¥",
    ]

    public static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var result = ""
        var index = input.startIndex
        while index < input.endIndex {
            guard input[index] == "&" else {
                result.append(input[index])
                index = input.index(after: index)
                continue
            }
            guard let semicolon = input[index...].firstIndex(of: ";"),
                  input.distance(from: index, to: semicolon) <= 12 else {
                result.append("&")
                index = input.index(after: index)
                continue
            }
            let body = String(input[input.index(after: index)..<semicolon])
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let value = UInt32(body.dropFirst(2), radix: 16), let scalar = UnicodeScalar(value) {
                    decoded = String(Character(scalar))
                }
            } else if body.hasPrefix("#") {
                if let value = UInt32(body.dropFirst()), let scalar = UnicodeScalar(value) {
                    decoded = String(Character(scalar))
                }
            } else if let named = namedEntities[body.lowercased()] {
                decoded = named
            }
            if let decoded {
                result.append(decoded)
                index = input.index(after: semicolon)
            } else {
                result.append("&")
                index = input.index(after: index)
            }
        }
        return result
    }
}

// MARK: - CSS selector matching

public struct CSSSelector {
    struct Step {
        var combinator: Character?
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attributes: [(name: String, value: String?)] = []
    }

    public static func matches(selector: String, in root: HTMLNode) throws -> [HTMLNode] {
        let groups = try parse(selector)
        guard !groups.isEmpty else { throw ExtractionError.invalidSelector(selector) }
        return root.allElements().filter { element in
            groups.contains { matchesGroup(steps: $0, index: $0.count - 1, element: element) }
        }
    }

    public static func validate(_ selector: String) throws {
        _ = try parse(selector)
    }

    static func parse(_ selector: String) throws -> [[Step]] {
        var groups: [[Step]] = []
        var current: [Step] = []
        var step = Step()
        var hasContent = false
        var pendingCombinator: Character?
        var index = selector.startIndex

        func flushStep() {
            if hasContent {
                current.append(step)
                step = Step()
                hasContent = false
            }
        }

        func flushGroup() {
            flushStep()
            if !current.isEmpty {
                groups.append(current)
                current = []
            }
        }

        while index < selector.endIndex {
            let character = selector[index]
            switch character {
            case ",":
                flushGroup()
                pendingCombinator = nil
                index = selector.index(after: index)
            case " ", "\t", "\n":
                flushStep()
                if !current.isEmpty {
                    pendingCombinator = " "
                }
                index = selector.index(after: index)
            case ">":
                flushStep()
                pendingCombinator = ">"
                index = selector.index(after: index)
            case "+", "~":
                throw ExtractionError.invalidSelector(selector)
            case "*":
                if !hasContent {
                    step.combinator = pendingCombinator
                    pendingCombinator = nil
                }
                step.tag = "*"
                hasContent = true
                index = selector.index(after: index)
            case ".":
                let (value, next) = try readIdentifier(selector, from: selector.index(after: index), full: selector)
                if !hasContent {
                    step.combinator = pendingCombinator
                    pendingCombinator = nil
                    hasContent = true
                }
                step.classes.append(value)
                index = next
            case "#":
                let (value, next) = try readIdentifier(selector, from: selector.index(after: index), full: selector)
                if !hasContent {
                    step.combinator = pendingCombinator
                    pendingCombinator = nil
                    hasContent = true
                }
                step.id = value
                index = next
            case "[":
                let (attribute, next) = try readAttribute(selector, from: selector.index(after: index))
                if !hasContent {
                    step.combinator = pendingCombinator
                    pendingCombinator = nil
                    hasContent = true
                }
                step.attributes.append(attribute)
                index = next
            case ":":
                throw ExtractionError.invalidSelector(selector)
            default:
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    let (value, next) = try readIdentifier(selector, from: index, full: selector)
                    if !hasContent {
                        step.combinator = pendingCombinator
                        pendingCombinator = nil
                    }
                    step.tag = value.lowercased()
                    hasContent = true
                    index = next
                } else {
                    throw ExtractionError.invalidSelector(selector)
                }
            }
        }
        flushGroup()
        return groups
    }

    private static func readIdentifier(_ selector: String,
                                       from start: String.Index,
                                       full: String) throws -> (String, String.Index) {
        var index = start
        var value = ""
        while index < selector.endIndex {
            let character = selector[index]
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                value.append(character)
                index = selector.index(after: index)
            } else {
                break
            }
        }
        if value.isEmpty {
            throw ExtractionError.invalidSelector(full)
        }
        return (value, index)
    }

    private static func readAttribute(_ selector: String,
                                      from start: String.Index) throws -> ((name: String, value: String?), String.Index) {
        var index = start
        var name = ""
        while index < selector.endIndex {
            let character = selector[index]
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                name.append(character)
                index = selector.index(after: index)
            } else {
                break
            }
        }
        guard !name.isEmpty else {
            throw ExtractionError.invalidSelector(selector)
        }
        while index < selector.endIndex, selector[index] == " " {
            index = selector.index(after: index)
        }
        guard index < selector.endIndex else {
            throw ExtractionError.invalidSelector(selector)
        }
        if selector[index] == "]" {
            return ((name.lowercased(), nil), selector.index(after: index))
        }
        guard selector[index] == "=" else {
            throw ExtractionError.invalidSelector(selector)
        }
        index = selector.index(after: index)
        while index < selector.endIndex, selector[index] == " " {
            index = selector.index(after: index)
        }
        var value = ""
        if index < selector.endIndex, selector[index] == "\"" || selector[index] == "'" {
            let quote = selector[index]
            index = selector.index(after: index)
            while index < selector.endIndex, selector[index] != quote {
                value.append(selector[index])
                index = selector.index(after: index)
            }
            guard index < selector.endIndex else {
                throw ExtractionError.invalidSelector(selector)
            }
            index = selector.index(after: index)
        } else {
            while index < selector.endIndex, selector[index] != "]" {
                value.append(selector[index])
                index = selector.index(after: index)
            }
        }
        guard index < selector.endIndex, selector[index] == "]" else {
            throw ExtractionError.invalidSelector(selector)
        }
        return ((name.lowercased(), value), selector.index(after: index))
    }

    private static func matchesGroup(steps: [Step], index: Int, element: HTMLNode) -> Bool {
        guard index >= 0, matchesCompound(steps[index], element: element) else { return false }
        if index == 0 { return true }
        let combinator = steps[index].combinator ?? " "
        if combinator == ">" {
            guard let parent = element.parent else { return false }
            return matchesGroup(steps: steps, index: index - 1, element: parent)
        }
        var ancestor = element.parent
        while let current = ancestor {
            if matchesGroup(steps: steps, index: index - 1, element: current) {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    private static func matchesCompound(_ step: Step, element: HTMLNode) -> Bool {
        guard element.kind == .element else { return false }
        if let tag = step.tag, tag != "*", element.name != tag {
            return false
        }
        if let id = step.id, element.attribute("id") != id {
            return false
        }
        if !step.classes.isEmpty {
            let classNames = (element.attribute("class") ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            for className in step.classes where !classNames.contains(className) {
                return false
            }
        }
        for attribute in step.attributes {
            guard let value = element.attribute(attribute.name) else { return false }
            if let expected = attribute.value, value != expected {
                return false
            }
        }
        return true
    }
}

// MARK: - Markdown conversion

public enum HTMLMarkdownConverter {
    public static func markdown(from node: HTMLNode) -> String {
        let raw = render(node: node, inPre: false)
        return cleanup(raw)
    }

    public static func cleanup(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines = lines.map { line in
            var line = line.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                line = ""
            }
            return line
        }
        var output: [String] = []
        var lastWasBlank = true
        for line in lines {
            if line.isEmpty {
                if !lastWasBlank {
                    output.append("")
                    lastWasBlank = true
                }
            } else {
                output.append(line)
                lastWasBlank = false
            }
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n")
    }

    private static func render(node: HTMLNode, inPre: Bool) -> String {
        if node.kind == .text {
            let value = node.text ?? ""
            if inPre { return value }
            return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        guard node.kind == .element, let tag = node.name else {
            return node.children.map { render(node: $0, inPre: inPre) }.joined()
        }
        // 只丢弃非内容元素：导航/页脚/侧栏等结构保留，整页转换才能维持原布局。
        if ["script", "style", "noscript", "iframe", "svg", "canvas", "form", "input",
            "button", "select", "textarea"].contains(tag) {
            return ""
        }
        if tag == "br" { return "\n" }
        if tag == "hr" { return "\n\n---\n\n" }
        if tag == "pre" {
            let content = node.textContent
            return "\n\n```\n\(content)\n```\n\n"
        }
        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag), let level = Int(tag.dropFirst()) {
            let content = inlineText(of: node)
            return "\n\n\(String(repeating: "#", count: level)) \(content)\n\n"
        }
        if tag == "p" {
            return "\n\n\(renderBlockChildren(node, paragraphs: false))\n\n"
        }
        if tag == "strong" || tag == "b" {
            let content = inlineText(of: node)
            return content.isEmpty ? "" : "**\(content)**"
        }
        if tag == "em" || tag == "i" {
            let content = inlineText(of: node)
            return content.isEmpty ? "" : "*\(content)*"
        }
        if tag == "code" {
            let content = inlineText(of: node)
            return content.isEmpty ? "" : "`\(content)`"
        }
        if tag == "blockquote" {
            let content = renderBlockChildren(node, paragraphs: false)
            let quoted = cleanup(content).components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            return "\n\n\(quoted)\n\n"
        }
        if tag == "a" {
            let content = inlineText(of: node)
            if let href = node.attribute("href"), !href.isEmpty, !content.isEmpty {
                return "[\(content)](\(href))"
            }
            return content
        }
        if tag == "img" {
            let alt = node.attribute("alt") ?? ""
            if let src = node.attribute("src"), !src.isEmpty {
                return "![\(alt)](\(src))"
            }
            return ""
        }
        if tag == "ul" || tag == "ol" {
            return "\n\n" + renderList(node, ordered: tag == "ol") + "\n\n"
        }
        if tag == "table" {
            return "\n\n" + renderTable(node) + "\n\n"
        }
        if ["div", "section", "article", "main", "body", "html", "figure", "figcaption",
            "dd", "dt", "nav", "header", "footer", "aside"].contains(tag) {
            return "\n\n\(renderBlockChildren(node, paragraphs: true))\n\n"
        }
        return renderBlockChildren(node, paragraphs: false)
    }

    /// 容器子节点之间的分隔方式。
    private enum ChildSeparation {
        case none
        case space
        case paragraph
    }

    /// 按视觉布局渲染子节点：相邻元素各自成段，紧贴元素的标签文本用空格隔开，
    /// 避免导航项、卡片、标签与数值被拼成一整行（原布局丢失）。
    /// - Parameter paragraphs: 是否允许段落分隔；段落内联文本（`<p>` 等）只用空格。
    private static func renderBlockChildren(_ node: HTMLNode, paragraphs: Bool) -> String {
        var result = ""
        var previous: HTMLNode?
        for child in node.children {
            if let previous {
                switch separation(between: previous, child, allowParagraph: paragraphs) {
                case .none: break
                case .space: result += " "
                case .paragraph: result += "\n\n"
                }
            }
            result += render(node: child, inPre: false)
            previous = child
        }
        return result
    }

    private static let punctuation: Set<Character> = [
        "，", "。", "；", "：", "、", ",", ".", ";", ":", "!", "?", "！", "？",
        ")", "）", "]", "】", "…", "—",
    ]

    /// 行内文本紧贴元素（“点击 <a>这里</a>”）时只补一个空格，源里已有空白则保持原样，
    /// 避免把句子或标点拆散。
    private static func separation(between lhs: HTMLNode,
                                   _ rhs: HTMLNode,
                                   allowParagraph: Bool) -> ChildSeparation {
        if lhs.kind == .text {
            let raw = lhs.text ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, raw.last?.isWhitespace != true else { return .none }
            guard rhs.kind == .element, let last = trimmed.last, !punctuation.contains(last) else { return .none }
            return .space
        }
        if rhs.kind == .text {
            let raw = rhs.text ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, raw.first?.isWhitespace != true else { return .none }
            guard lhs.kind == .element, let first = trimmed.first, !punctuation.contains(first) else { return .none }
            return .space
        }
        guard lhs.kind == .element, rhs.kind == .element else { return .none }
        // 只有块级元素相邻才分段；两个行内元素（span/a 包裹的句子）只补空格，
        // 避免把“欢迎体验 <a>WorkBuddy</a>，首月…”这类句子拆散。
        // ponytail: 按标签名判断块级，不解析 CSS display；flex 布局的行内元素会排成一行。
        if allowParagraph, isBlockLevel(lhs) || isBlockLevel(rhs) {
            return .paragraph
        }
        if let last = edgeCharacter(of: lhs, leading: false), punctuation.contains(last) { return .none }
        if let first = edgeCharacter(of: rhs, leading: true), punctuation.contains(first) { return .none }
        return .space
    }

    private static let blockLevelTags: Set<String> = [
        "div", "p", "section", "article", "main", "header", "footer", "nav", "aside",
        "ul", "ol", "li", "dl", "dt", "dd", "table", "pre", "blockquote", "figure", "figcaption",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "form", "fieldset",
    ]

    private static func isBlockLevel(_ node: HTMLNode) -> Bool {
        guard let name = node.name else { return false }
        return blockLevelTags.contains(name)
    }

    /// 子树的第一个/最后一个可见字符，用于判断标点边界。
    private static func edgeCharacter(of node: HTMLNode, leading: Bool) -> Character? {
        if node.kind == .text {
            let text = node.text ?? ""
            return leading ? text.first { !$0.isWhitespace } : text.last { !$0.isWhitespace }
        }
        let children = leading ? node.children : node.children.reversed()
        for child in children {
            if let character = edgeCharacter(of: child, leading: leading) { return character }
        }
        return nil
    }

    private static func inlineText(of node: HTMLNode) -> String {
        let rendered = node.children.map { render(node: $0, inPre: false) }.joined()
        return rendered
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderList(_ node: HTMLNode, ordered: Bool) -> String {
        var lines: [String] = []
        var counter = 1
        for child in node.children where child.kind == .element && child.name == "li" {
            // 去掉列表项开头的空白文本节点残留，避免渲染成“-  条目”。
            let content = cleanup(renderBlockChildren(child, paragraphs: true))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = ordered ? "\(counter). " : "- "
            let itemLines = content.components(separatedBy: "\n")
            if let first = itemLines.first {
                lines.append(prefix + first)
                for line in itemLines.dropFirst() where !line.isEmpty {
                    lines.append("  " + line)
                }
            }
            counter += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTable(_ node: HTMLNode) -> String {
        var rows: [String] = []
        var isFirstRow = true
        func collectRows(_ node: HTMLNode) {
            for child in node.children where child.kind == .element {
                if child.name == "tr" {
                    var cells: [String] = []
                    for cell in child.children where cell.kind == .element
                        && (cell.name == "td" || cell.name == "th") {
                        cells.append(inlineText(of: cell).replacingOccurrences(of: "|", with: "\\|"))
                    }
                    if !cells.isEmpty {
                        rows.append("| " + cells.joined(separator: " | ") + " |")
                        if isFirstRow {
                            rows.append("| " + cells.map { _ in "---" }.joined(separator: " | ") + " |")
                            isFirstRow = false
                        }
                    }
                } else if ["thead", "tbody", "tfoot"].contains(child.name) {
                    collectRows(child)
                }
            }
        }
        collectRows(node)
        return rows.joined(separator: "\n")
    }
}

// MARK: - Extractors

public protocol ContentExtractor {
    var kind: ExtractionKind { get }
    func extract(html: String, pageURL: URL, rule: ExtractionRule) throws -> ExtractionResult
}

/// 整页转换：不挑正文、不要求选择器，按文档顺序把整个 `<body>` 转成 Markdown。
public struct WholePageExtractor: ContentExtractor {
    public let kind: ExtractionKind = .fullPage

    public init() {}

    public func extract(html: String, pageURL: URL, rule: ExtractionRule) throws -> ExtractionResult {
        let document = HTMLParser.parse(html)
        let contentRoot: HTMLNode
        if let body = document.firstElement(named: "body") {
            contentRoot = body
        } else {
            // ponytail: 无 <body> 的片段直接丢 <head>（标题文字、样式残留），不引入额外解析分支。
            document.firstElement(named: "head")?.removeFromParent()
            contentRoot = document
        }
        let markdown = HTMLMarkdownConverter.markdown(from: contentRoot)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw document.allElements().isEmpty ? ExtractionError.genericFailed : ExtractionError.emptyBody
        }
        let title = HTMLParser.title(in: document)
        return ExtractionResult(markdown: markdown,
                                title: title.isEmpty ? pageURL.host ?? "" : title,
                                extractionKind: .fullPage)
    }
}

public struct CSSSelectorExtractor: ContentExtractor {
    public let kind: ExtractionKind = .css

    public init() {}

    public func extract(html: String, pageURL: URL, rule: ExtractionRule) throws -> ExtractionResult {
        let selector = rule.trimmedCSSSelector
        guard !selector.isEmpty else {
            throw ExtractionError.selectorNotConfigured
        }
        let document = HTMLParser.parse(html)
        let nodes = try CSSSelector.matches(selector: selector, in: document)
        guard let node = nodes.first else {
            throw ExtractionError.selectorNotMatched(selector)
        }
        let markdown = HTMLMarkdownConverter.markdown(from: node)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.emptyBody
        }
        let title = HTMLParser.title(in: document)
        return ExtractionResult(markdown: markdown,
                                title: title.isEmpty ? pageURL.host ?? "" : title,
                                extractionKind: .css)
    }
}

public struct GenericBodyExtractor: ContentExtractor {
    public let kind: ExtractionKind = .generic

    public init() {}

    public func extract(html: String, pageURL: URL, rule: ExtractionRule) throws -> ExtractionResult {
        let document = HTMLParser.parse(html)
        removeNoise(from: document)
        let candidates = document.allElements().filter {
            ["article", "main", "div", "section", "td", "body"].contains($0.name ?? "")
        }
        var best: (node: HTMLNode, score: Double)?
        for candidate in candidates {
            let score = scoreCandidate(candidate)
            if score > (best?.score ?? -Double.infinity) {
                best = (candidate, score)
            }
        }
        guard let best else {
            throw document.allElements().isEmpty ? ExtractionError.genericFailed : ExtractionError.emptyBody
        }
        let markdown = HTMLMarkdownConverter.markdown(from: best.node)
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else {
            throw ExtractionError.emptyBody
        }
        let title = HTMLParser.title(in: document)
        return ExtractionResult(markdown: markdown,
                                title: title.isEmpty ? pageURL.host ?? "" : title,
                                extractionKind: .generic)
    }

    private func removeNoise(from root: HTMLNode) {
        let noise = Set(["script", "style", "noscript", "nav", "footer", "aside", "header", "form", "iframe", "svg"])
        for element in root.allElements().reversed() {
            if let name = element.name, noise.contains(name) {
                element.removeFromParent()
            }
        }
    }

    private func scoreCandidate(_ element: HTMLNode) -> Double {
        let text = element.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let textLength = text.count
        guard textLength >= 20 else { return -Double.infinity }
        var linkLength = 0
        for descendant in element.allElements() where descendant.name == "a" {
            linkLength += descendant.textContent.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        let paragraphCount = element.allElements().filter { $0.name == "p" }.count
        let bonus: Double
        switch element.name {
        case "article": bonus = 400
        case "main": bonus = 300
        case "body": bonus = 100
        default: bonus = 0
        }
        return Double(textLength) - Double(linkLength) * 2.0 + Double(paragraphCount) * 50.0 + bonus
    }
}

public enum ExtractorFactory {
    public static func extractor(for kind: ExtractionKind) -> ContentExtractor {
        switch kind {
        case .fullPage: return WholePageExtractor()
        case .generic: return GenericBodyExtractor()
        case .css: return CSSSelectorExtractor()
        }
    }

    public static func extract(html: String,
                               pageURL: URL,
                               rule: ExtractionRule) throws -> ExtractionResult {
        // 不级联降级：只运行收藏明确选择的一种实现。
        try extractor(for: rule.kind).extract(html: html, pageURL: pageURL, rule: rule)
    }
}
