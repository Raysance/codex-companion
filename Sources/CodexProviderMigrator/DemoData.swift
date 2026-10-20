import Foundation

/// Synthetic data for interface previews. Never mixed with a real Codex home.
enum DemoData {
    static func report(now: Date = Date()) -> AnalyticsReport {
        var r = AnalyticsReport()
        let titles = ["Refine settings navigation", "Audit migration safety", "Build the usage dashboard", "Write parser tests", "Polish keyboard shortcuts", "Review export formats"]
        for (i, title) in titles.enumerated() {
            let id = "demo-chat-\(i)"
            r.sessions.append(SessionRecord(id: id, rolloutPath: "", cwd: "/Projects/\(i < 3 ? "Companion" : "Workbench")", title: title, provider: "openai", model: "gpt-6.1-sol", isArchived: false, updatedAt: 0))
            for day in 0..<7 {
                let date = now.addingTimeInterval(Double(-7 + day) * 86400 + Double(i) * 900 + 3600)
                let text = ["Review the parser and add coverage for repeated usage records.", "整理用量统计，检查会话和额度，保留清晰的界面。", "Refine the settings navigation and simplify the export flow."][i % 3]
                let terms = InputAnalysis.terms(text)
                let turn = "demo-turn-\(i)-\(day)"
                r.prompts.append(UserPrompt(id: turn, date: date, threadID: id, turnID: turn, text: text, words: terms.counts, wordCount: terms.words))
                for call in 0..<4 {
                    let input = 32000 + day * 4800 + i * 4100 + call * 1900
                    let tokens = TokenUsage(["input_tokens":input,"cached_input_tokens":input * (80 + i) / 100,"output_tokens":300 + call * 250,"reasoning_output_tokens":100 + call * 100])
                    r.requests.append(UsageRequest(id: "demo-response-\(i)-\(day)-\(call)", date: date.addingTimeInterval(Double(call + 1) * 35), threadID: id, turnID: turn, model: i % 3 == 0 ? "gpt-6-sol" : "gpt-6.1-sol", effort: i % 2 == 0 ? "high" : "medium", tokens: tokens, estimated: false))
                }
            }
        }
        let base = now.addingTimeInterval(-7 * 86400)
        for hour in stride(from: 0, through: 168, by: 4) {
            let cycle = hour / 60
            let reset = base.addingTimeInterval(Double(cycle * 60 + 168) * 3600)
            r.quotas.append(QuotaSnapshot(date: base.addingTimeInterval(Double(hour) * 3600), limitID: "codex", plan: "Demo", minutes: 10080, used: Double(hour % 60) * 1.65, resetsAt: reset))
        }
        r.requests.sort { $0.date < $1.date }; r.prompts.sort { $0.date < $1.date }
        r.filesRead = titles.count; r.runtimeVersions = ["Demo data"]
        return r
    }
}
