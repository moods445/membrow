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
        guard let url = Bundle.module.url(forResource: "blocking_rules", withExtension: "json") else {
            lastError = "未找到 blocking_rules.json"
            return
        }
        let json: String
        do {
            json = try String(contentsOf: url, encoding: .utf8)
        } catch {
            lastError = "读取 blocking_rules.json 失败：\(error.localizedDescription)"
            return
        }
        do {
            ruleList = try await store.compileContentRuleList(forIdentifier: "membrow-default",
                                                             encodedContentRuleList: json)
            lastError = nil
            // 只有真正编译成功才算加载完成：失败时保持 false，后续调用可以重试，
            // 也不会让“拦截开关已开启”的界面与实际行为不符。
            isLoaded = ruleList != nil
        } catch {
            lastError = error.localizedDescription
            FileHandle.standardError.write(Data("内容规则编译失败：\(error.localizedDescription)\n".utf8))
        }
    }
}
