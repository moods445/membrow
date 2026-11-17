import Foundation
import WebKit

@MainActor
final class ContentBlocker {
    private(set) var ruleList: WKContentRuleList?
    private(set) var lastError: String?
    private(set) var isLoaded = false
    private let store: WKContentRuleListStore

    init(storeURL: URL) {
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        self.store = WKContentRuleListStore(url: storeURL)
    }

    func load() async {
        guard !isLoaded else { return }
        guard let url = Bundle.module.url(forResource: "blocking_rules", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "未找到 blocking_rules.json"
            isLoaded = true
            return
        }
        do {
            ruleList = try await store.compileContentRuleList(forIdentifier: "membrow-default",
                                                             encodedContentRuleList: json)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            FileHandle.standardError.write(Data("内容规则编译失败：\(error.localizedDescription)\n".utf8))
        }
        isLoaded = true
    }
}
