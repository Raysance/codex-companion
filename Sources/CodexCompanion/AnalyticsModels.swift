import Foundation

struct TokenUsage: Codable, Hashable, Sendable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var cacheWrite: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var total: Int64 { input + output }
    var uncached: Int64 { max(0, input - cached) }
    var cacheRate: Double { input > 0 ? Double(cached) / Double(input) : 0 }

    init(_ object: [String: Any] = [:]) {
        func number(_ key: String) -> Int64 { max(0, (object[key] as? NSNumber)?.int64Value ?? 0) }
        input = number("input_tokens"); cached = min(input, number("cached_input_tokens"))
        cacheWrite = number("cache_write_input_tokens"); output = number("output_tokens")
        reasoning = min(output, number("reasoning_output_tokens"))
    }
    static func + (a: Self, b: Self) -> Self {
        var v = Self(); v.input = a.input + b.input; v.cached = a.cached + b.cached
        v.cacheWrite = a.cacheWrite + b.cacheWrite; v.output = a.output + b.output; v.reasoning = a.reasoning + b.reasoning
        return v
    }
    func delta(from old: Self) -> Self {
        var v = Self(); v.input = max(0, input - old.input); v.cached = min(v.input, max(0, cached - old.cached))
        v.cacheWrite = max(0, cacheWrite - old.cacheWrite); v.output = max(0, output - old.output)
        v.reasoning = min(v.output, max(0, reasoning - old.reasoning)); return v
    }
    var signature: String { "\(input):\(cached):\(cacheWrite):\(output):\(reasoning)" }
}

struct UsageRequest: Identifiable, Codable, Sendable {
    let id: String
    let date: Date
    let threadID: String
    let turnID: String
    let model: String
    let effort: String
    let tokens: TokenUsage
    let estimated: Bool
}

struct UserPrompt: Identifiable, Sendable {
    let id: String
    let date: Date
    var threadID: String
    let turnID: String
    let text: String
    let words: [String: Int]
    let wordCount: Int
    var characters: Int { text.count }
}

struct QuotaSnapshot: Codable, Hashable, Sendable {
    let date: Date
    let limitID: String
    let plan: String
    let minutes: Int
    let used: Double
    let resetsAt: Date
    var scope: String { "\(limitID) · \(plan.isEmpty ? "unknown plan" : plan) · \(minutes)m" }
}

struct QuotaCycle: Identifiable, Sendable {
    let id: Int
    var samples: [QuotaSnapshot]
    var first: QuotaSnapshot { samples[0] }
    var last: QuotaSnapshot { samples[samples.count - 1] }
    var peak: Double { samples.map(\.used).max() ?? 0 }
    var resetKind: String
}

struct QuotaAnalysis: Sendable {
    var cycles: [QuotaCycle] = []
    var observedPercent: Double = 0
    var observationsInRange = 0
    var resets: [QuotaCycle] = []
    var latest: QuotaSnapshot?
    var missingBaseline = false
    var byThread: [String: Double] = [:]
    var byTurn: [String: Double] = [:]
    var unattributed: Double = 0
}

struct AnalyticsReport: Sendable {
    var requests: [UsageRequest] = []
    var prompts: [UserPrompt] = []
    var quotas: [QuotaSnapshot] = []
    var sessions: [SessionRecord] = []
    var filesRead = 0
    var malformedLines = 0
    var unreadableFiles = 0
    var excludedContext = 0
    var subagentPrompts = 0
    var indexedMissingLogs = 0
    var contextWindows: [String: Int] = [:]
    var runtimeVersions: Set<String> = []
    var scannedAt = Date()
    var quotaScopes: [String] { Array(Set(quotas.map(\.scope))).sorted() }
    var oldest: Date? { (requests.map(\.date) + prompts.map(\.date) + quotas.map(\.date)).min() }
    func title(_ id: String) -> String { sessions.first { $0.id == id }?.title ?? String(id.prefix(12)) }
    func project(_ id: String) -> String { sessions.first { $0.id == id }?.cwd ?? "" }
}

struct DailyActivity: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    var tokens = TokenUsage()
    var prompts = 0
    var characters = 0
}

struct UsageGroup: Identifiable, Sendable {
    let id: String
    let title: String
    var requests = 0
    var tokens = TokenUsage()
    var estimated = 0
}

struct InputTerm: Identifiable, Sendable {
    var id: String { text }
    let text: String
    let count: Int
    let documents: Int
}

struct AnalyticsSlice: Sendable {
    let start: Date
    let end: Date
    var requests: [UsageRequest]
    var prompts: [UserPrompt]
    var tokens: TokenUsage
    var daily: [DailyActivity]
    var sessions: [UsageGroup]
    var models: [UsageGroup]
    var turns: [UsageGroup]
    var terms: [InputTerm]
    var quota: QuotaAnalysis
    var characters: Int { prompts.reduce(0) { $0 + $1.characters } }
    var wordCount: Int { prompts.reduce(0) { $0 + $1.wordCount } }

    static func build(report: AnalyticsReport, start: Date, end: Date, scope: String, project: String = "") -> Self {
        let requests = report.requests.filter { $0.date >= start && $0.date <= end && (project.isEmpty || report.project($0.threadID) == project) }
        let prompts = report.prompts.filter { $0.date >= start && $0.date <= end && (project.isEmpty || report.project($0.threadID) == project) }
        let tokens = requests.reduce(TokenUsage()) { $0 + $1.tokens }
        func grouped(_ key: (UsageRequest) -> String, _ title: (String) -> String) -> [UsageGroup] {
            var groups: [String: UsageGroup] = [:]
            for r in requests {
                let id = key(r); var g = groups[id] ?? UsageGroup(id: id, title: title(id))
                g.requests += 1; g.tokens = g.tokens + r.tokens; g.estimated += r.estimated ? 1 : 0; groups[id] = g
            }
            return groups.values.sorted { $0.tokens.total == $1.tokens.total ? $0.id < $1.id : $0.tokens.total > $1.tokens.total }
        }
        var days: [Date: DailyActivity] = [:]
        for r in requests { let day = Calendar.current.startOfDay(for: r.date); var v = days[day] ?? DailyActivity(date: day); v.tokens = v.tokens + r.tokens; days[day] = v }
        for p in prompts { let day = Calendar.current.startOfDay(for: p.date); var v = days[day] ?? DailyActivity(date: day); v.prompts += 1; v.characters += p.characters; days[day] = v }
        var counts: [String: Int] = [:], documents: [String: Int] = [:]
        for p in prompts { for (word, count) in p.words { counts[word, default: 0] += count; documents[word, default: 0] += 1 } }
        let terms = counts.map { InputTerm(text: $0.key, count: $0.value, documents: documents[$0.key] ?? 0) }.sorted { $0.count == $1.count ? $0.text < $1.text : $0.count > $1.count }
        return Self(start: start, end: end, requests: requests, prompts: prompts, tokens: tokens,
                    daily: days.values.sorted { $0.date < $1.date }, sessions: grouped({ $0.threadID }, report.title),
                    models: grouped({ $0.model }, { $0 }), turns: grouped({ $0.turnID }, { String($0.prefix(12)) }), terms: terms,
                    quota: QuotaEngine.analyze(report.quotas.filter { $0.scope == scope }, requests: report.requests, start: start, end: end))
    }
}
