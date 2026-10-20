import CryptoKit
import Foundation

struct AnalyticsStore {
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    static func scan(home: URL, includeBackups: Bool = false) throws -> AnalyticsReport {
        var report = AnalyticsReport()
        let fm = FileManager.default
        guard fm.fileExists(atPath: home.path) else { throw CompanionError.missingFile(home.path) }
        report.sessions = (try? CodexStore.scan(codexHome: home)) ?? []
        report.indexedMissingLogs = report.sessions.filter { !fm.fileExists(atPath: $0.rolloutPath) }.count
        var files = Set<URL>()
        for folder in ["sessions", "archived_sessions"] + (includeBackups ? ["backup", "backups"] : []) {
            let root = home.appending(path: folder)
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                    if ["backup", "backups"].contains(folder) && !url.path.contains("/sessions/") && !url.path.contains("/archived_sessions/") { continue }
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                    if values?.isRegularFile == true { files.insert(url.standardizedFileURL) }
                }
            }
        }
        var requests: [String: UsageRequest] = [:], prompts: [String: UserPrompt] = [:]
        var quotaSet = Set<QuotaSnapshot>()
        let knownSessions = Set(report.sessions.map(\.id))
        var discovered: [String: SessionRecord] = [:]
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            var threadID = file.deletingPathExtension().lastPathComponent
            var turnID = "", model = "Unknown", effort = "Unknown", cwd = ""
            var isAgent = false
            var contexts: [String: (String, String)] = [:]
            var previousTokens: TokenUsage?
            var modern: [UsageRequest] = []
            var legacy: [(UsageRequest, String)] = []
            var eventPrompts: [UserPrompt] = [], itemPrompts: [UserPrompt] = []
            do {
                try JSONLines.read(file) { data in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let type = object["type"] as? String, let p = object["payload"] as? [String: Any] else {
                        report.malformedLines += 1; return
                    }
                    let timestamp = Self.date(object["timestamp"] as? String)
                    if type == "session_meta" {
                        threadID = p["id"] as? String ?? threadID
                        cwd = p["cwd"] as? String ?? cwd
                        isAgent = (p["source"] as? [String: Any])?["subagent"] != nil
                        if let v = p["cli_version"] as? String { report.runtimeVersions.insert(v) }
                        if !knownSessions.contains(threadID) {
                            discovered[threadID] = SessionRecord(id: threadID, rolloutPath: file.path, cwd: cwd,
                                title: discovered[threadID]?.title ?? "Session \(threadID.prefix(8))", provider: p["model_provider"] as? String ?? "Unknown",
                                model: model, isArchived: file.path.contains("/archived_sessions/"), updatedAt: Int64((timestamp?.timeIntervalSince1970 ?? 0) * 1000))
                        }
                    }
                    if type == "turn_context" {
                        turnID = p["turn_id"] as? String ?? turnID
                        model = p["model"] as? String ?? model; effort = p["effort"] as? String ?? effort
                        contexts[turnID] = (model, effort)
                    }
                    if type == "event_msg", ["task_started", "turn_started"].contains(p["type"] as? String ?? "") {
                        turnID = p["turn_id"] as? String ?? turnID
                    }
                    if type == "token_usage_record", let timestamp, let u = p["usage"] as? [String: Any],
                       let response = p["response_id"] as? String, !response.isEmpty {
                        let turn = p["turn_id"] as? String ?? turnID
                        let context = contexts[turn] ?? (model, effort)
                        modern.append(UsageRequest(id: response, date: timestamp, threadID: p["thread_id"] as? String ?? threadID,
                            turnID: turn, model: context.0, effort: context.1, tokens: TokenUsage(u), estimated: false))
                    }
                    if type == "event_msg", p["type"] as? String == "token_count", let timestamp {
                        if let info = p["info"] as? [String: Any] {
                            if let window = info["model_context_window"] as? Int { report.contextWindows[model] = window }
                            let last = (info["last_token_usage"] as? [String: Any]).map(TokenUsage.init)
                            let total = (info["total_token_usage"] as? [String: Any]).map(TokenUsage.init)
                            let delta: TokenUsage?
                            if let total, let previous = previousTokens, total.input >= previous.input, total.output >= previous.output {
                                delta = total.delta(from: previous)
                            } else { delta = last }
                            if let total { previousTokens = total }
                            if let delta, delta.total > 0 {
                                let id = "legacy:\(timestamp.timeIntervalSince1970):\(delta.signature)"
                                legacy.append((UsageRequest(id: id, date: timestamp, threadID: threadID, turnID: turnID,
                                    model: model, effort: effort, tokens: delta, estimated: true), (last ?? delta).signature))
                            }
                        }
                        if let limits = p["rate_limits"] as? [String: Any] {
                            for name in ["primary", "secondary"] {
                                guard let w = limits[name] as? [String: Any], let used = w["used_percent"] as? Double,
                                      let minutes = w["window_minutes"] as? Int, let reset = w["resets_at"] as? Double,
                                      used.isFinite, used >= 0, used <= 100, minutes > 0 else { continue }
                                quotaSet.insert(QuotaSnapshot(date: timestamp, limitID: limits["limit_id"] as? String ?? "unknown",
                                    plan: limits["plan_type"] as? String ?? "", minutes: minutes, used: used, resetsAt: Date(timeIntervalSince1970: reset)))
                            }
                        }
                    }
                    let isEvent = type == "event_msg" && p["type"] as? String == "user_message"
                    let isItem = type == "response_item" && p["role"] as? String == "user"
                    if isEvent || isItem {
                        if isAgent { report.subagentPrompts += 1; return }
                        let metadata = p["internal_chat_message_metadata_passthrough"] as? [String: Any] ?? [:]
                        let content = p["content"] as? [[String: Any]] ?? []
                        let raw = isEvent ? p["message"] as? String ?? "" : content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        guard let text = InputAnalysis.clean(raw, kinds: metadata["content_item_kinds"] as? [String]) else {
                            report.excludedContext += 1; return
                        }
                        let promptDate: Date?
                        if let created = metadata["create_time"] as? Double { promptDate = Date(timeIntervalSince1970: created > 1e12 ? created / 1000 : created) }
                        else { promptDate = timestamp }
                        guard let promptDate else { return }
                        let turn = metadata["turn_id"] as? String ?? turnID
                        let digest = SHA256.hash(data: Data("\(promptDate.timeIntervalSince1970):\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
                        let id = (p["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? digest
                        let words = InputAnalysis.terms(text)
                        let prompt = UserPrompt(id: id, date: promptDate, threadID: threadID, turnID: turn,
                                                text: text, words: words.counts, wordCount: words.words)
                        if isEvent { eventPrompts.append(prompt) } else { itemPrompts.append(prompt) }
                        if var session = discovered[threadID], session.title.hasPrefix("Session ") {
                            session = SessionRecord(id: session.id, rolloutPath: session.rolloutPath, cwd: session.cwd,
                                title: String(text.prefix(80)).replacingOccurrences(of: "\n", with: " "), provider: session.provider,
                                model: model, isArchived: session.isArchived, updatedAt: session.updatedAt)
                            discovered[threadID] = session
                        }
                    }
                }
                report.filesRead += 1
            } catch is CancellationError { throw CancellationError() }
            catch { report.unreadableFiles += 1 }
            // Match modern requests to their token_count mirrors; keep legacy-only portions of mixed logs.
            var signatures: [String: Int] = [:]
            for r in modern { requests[r.id] = requests[r.id] ?? r; signatures[r.tokens.signature, default: 0] += 1 }
            for (r, signature) in legacy {
                if signatures[signature, default: 0] > 0 { signatures[signature, default: 0] -= 1 }
                else { requests[r.id] = requests[r.id] ?? r }
            }
            // Prefer the stable response-item ID for paired mirrors; retain legacy-only and mixed-version inputs.
            var paired = Set<Int>()
            for event in eventPrompts {
                let match = itemPrompts.indices.first { index in
                    let item = itemPrompts[index]
                    let sameTurn = !event.turnID.isEmpty && event.turnID == item.turnID
                    return !paired.contains(index) && item.text == event.text && (sameTurn || abs(item.date.timeIntervalSince(event.date)) <= 10)
                }
                if let match { paired.insert(match) }
                else { prompts[event.id] = prompts[event.id] ?? event }
            }
            for p in itemPrompts { prompts[p.id] = prompts[p.id] ?? p }
        }
        report.sessions += discovered.values.sorted { $0.id < $1.id }
        report.requests = requests.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        var turnThreads: [String: String] = [:]
        for r in report.requests where !r.turnID.isEmpty { turnThreads[r.turnID] = r.threadID }
        report.prompts = prompts.values.map { value in
            var p = value; p.threadID = turnThreads[p.turnID] ?? p.threadID; return p
        }.sorted { $0.date < $1.date }
        report.quotas = quotaSet.sorted { $0.date < $1.date }
        return report
    }
}
