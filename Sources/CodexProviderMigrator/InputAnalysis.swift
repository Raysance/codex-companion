import Foundation
import NaturalLanguage

struct InputAnalysis {
    private static let stopwords: Set<String> = Set("a an the and or but if of to in on at for from by with as is are was were be been being this that these those it its i me my we our you your he she they them their have has had do does did can could will would should shall may might must not no yes please just also about into then than so use using used want need help let now all each very how what why when where which who there here like get make more some any only already 我 你 您 他 她 它 我们 你们 他们 的 地 得 了 着 过 和 与 及 或 而 但 也 都 就 才 又 还 很 更 最 是 在 有 没有 不 要 为 被 把 将 给 对 从 到 以 用 这 那 这个 那个 这些 那些 一个 一些 一下 什么 怎么 如何 是否 可以 需要 帮 请 好 嗯 啊 吗 呢 吧 然后 现在 进行 以及 并且 还是 如果 所以 因为 中 上 下 里 各 每 次".components(separatedBy: " "))

    /// Reject app-injected context, preserving the human text that may follow its wrapper.
    static func clean(_ text: String, kinds: [String]?) -> String? {
        if let kinds, !kinds.isEmpty, !kinds.contains(where: { $0.hasPrefix("user.") }) { return nil }
        var value = text
        let contextTags = ["environment_context", "external_codex_apps_open_page", "codex_internal_context", "in-app-browser-context", "response-annotations", "recommended_plugins"]
        for tag in contextTags {
            value = value.replacingOccurrences(of: "(?s)<\(tag)(?:\\s[^>]*)?>.*?</\(tag)>", with: "", options: .regularExpression)
        }
        if kinds == nil {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("# AGENTS.md") || trimmed.hasPrefix("<INSTRUCTIONS>") { return nil }
        }
        value = value.replacingOccurrences(of: #"</?send_user_message_question_reply>"#, with: "", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func terms(_ text: String) -> (counts: [String: Int], words: Int) {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var counts: [String: Int] = [:], words = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).lowercased()
            guard token.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return true }
            words += 1
            if token.count > 1 && token.count <= 48 && !stopwords.contains(token) { counts[token, default: 0] += 1 }
            return true
        }
        return (counts, words)
    }
}
