import Foundation

enum HeadlessAudit {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            var path = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSString(string: "~/.codex").expandingTildeInPath
            if let index = arguments.firstIndex(of: "--home") {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                    throw MigratorError.unsupportedStorage("--home requires a folder path")
                }
                path = NSString(string: arguments[index + 1]).expandingTildeInPath
            }
            let home = URL(fileURLWithPath: path)
            let report = try AnalyticsStore.scan(home: home, includeBackups: arguments.contains("--include-backups"))
            let compatibility = CodexStore.compatibility(codexHome: home)
            let now = Date(), start = now.addingTimeInterval(-7 * 86400)
            let scope = report.quotas.last(where: { $0.minutes == 10080 && $0.limitID == "codex" })?.scope ?? ""
            let slice = AnalyticsSlice.build(report: report, start: start, end: now, scope: scope)
            let object: [String: Any] = [
                "scanned_at": now.ISO8601Format(),
                "migration_supported": compatibility.canMigrate,
                "migration_blockers": compatibility.blockers,
                "state_database": compatibility.statePath,
                "files_read": report.filesRead,
                "missing_indexed_logs": report.indexedMissingLogs,
                "malformed_records": report.malformedLines,
                "unreadable_files": report.unreadableFiles,
                "oldest_observation": report.oldest?.ISO8601Format() ?? "",
                "runtime_versions": report.runtimeVersions.sorted(),
                "all_history": ["requests":report.requests.count, "human_inputs":report.prompts.count, "quota_snapshots":report.quotas.count],
                "last_7_days": ["requests":slice.requests.count, "legacy_estimates":slice.requests.filter(\.estimated).count,
                    "input_tokens":slice.tokens.input, "cached_input_tokens":slice.tokens.cached, "output_tokens":slice.tokens.output,
                    "reasoning_output_tokens":slice.tokens.reasoning, "total_tokens":slice.tokens.total,
                    "human_inputs":slice.prompts.count, "input_characters":slice.characters,
                    "observed_weekly_percent":slice.quota.observedPercent, "inferred_resets":slice.quota.resets.count,
                    "missing_quota_baseline":slice.quota.missingBaseline]
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
            return compatibility.canMigrate ? 0 : 2
        } catch { fputs("Audit failed: \(error.localizedDescription)\n", stderr); return 1 }
    }
}
