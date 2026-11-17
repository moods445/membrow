import Foundation
import Testing
@testable import MembrowCore

@Suite struct ExtractionTests {
    private let articleHTML = """
    <!doctype html>
    <html>
      <head><title>示例文章</title><style>.x{color:red}</style></head>
      <body>
        <nav><a href="/">首页</a><a href="/about">关于</a></nav>
        <article id="content" class="post main">
          <h1>示例标题</h1>
          <p>第一段正文，包含 <strong>重点</strong> 与 <a href="https://example.com/link">链接</a>。</p>
          <p>第二段正文，延续内容。</p>
          <ul><li>条目一</li><li>条目二</li></ul>
          <pre><code>let value = 1</code></pre>
          <script>console.log('noise')</script>
        </article>
        <footer>版权信息</footer>
      </body>
    </html>
    """

    private var pageURL: URL { URL(string: "https://example.com/post")! }

    @Test func cssSelectorExtraction() throws {
        let rule = ExtractionRule(kind: .css, cssSelector: "article#content")
        let result = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL, rule: rule)
        #expect(result.title == "示例文章")
        #expect(result.extractionKind == .css)
        #expect(result.markdown.contains("# 示例标题"))
        #expect(result.markdown.contains("**重点**"))
        #expect(result.markdown.contains("[链接](https://example.com/link)"))
        #expect(result.markdown.contains("- 条目一"))
        #expect(result.markdown.contains("```"))
        #expect(!result.markdown.contains("console.log"))
        #expect(!result.markdown.contains("版权信息"))
    }

    @Test func cssSelectorWithClassAndDescendant() throws {
        let rule = ExtractionRule(kind: .css, cssSelector: "article.post p")
        let result = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL, rule: rule)
        #expect(result.markdown.contains("第一段正文"))
        #expect(result.markdown.contains("第二段正文"))
        #expect(!result.markdown.contains("示例标题"))
    }

    @Test func cssSelectorNotConfiguredFails() {
        let rule = ExtractionRule(kind: .css, cssSelector: "   ")
        #expect(throws: ExtractionError.selectorNotConfigured) {
            try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL, rule: rule)
        }
    }

    @Test func cssSelectorNotMatchedFailsWithoutFallback() {
        let rule = ExtractionRule(kind: .css, cssSelector: ".does-not-exist")
        #expect(throws: ExtractionError.selectorNotMatched(".does-not-exist")) {
            try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL, rule: rule)
        }
    }

    @Test func genericExtractionPicksMainContent() throws {
        let rule = ExtractionRule(kind: .generic)
        let result = try ExtractorFactory.extract(html: articleHTML, pageURL: pageURL, rule: rule)
        #expect(result.extractionKind == .generic)
        #expect(result.markdown.contains("第一段正文"))
        #expect(!result.markdown.contains("首页"))
    }

    @Test func genericExtractionEmptyBodyDistinctFromFailure() {
        let emptyHTML = "<html><head><title>空</title></head><body><nav>导航</nav></body></html>"
        #expect(throws: ExtractionError.emptyBody) {
            try ExtractorFactory.extract(html: emptyHTML, pageURL: pageURL,
                                         rule: ExtractionRule(kind: .generic))
        }
    }

    @Test func cssConverterRejectsUnsupportedPseudoSelector() {
        #expect(throws: ExtractionError.self) {
            try CSSSelectorConverter.xpath(for: "div:nth-child(2)")
        }
    }

    @Test func markdownTableConversion() throws {
        let html = "<html><body><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table></body></html>"
        let result = try ExtractorFactory.extract(html: html, pageURL: pageURL,
                                                  rule: ExtractionRule(kind: .css, cssSelector: "table"))
        #expect(result.markdown.contains("| A | B |"))
        #expect(result.markdown.contains("| --- | --- |"))
        #expect(result.markdown.contains("| 1 | 2 |"))
    }
}
