import Foundation

enum SelfTest {
    static func run() -> Int32 {
        let tests: [(String, () throws -> Void)] = [
            ("metadata isolation and whitespace", testProviderFields),
            ("current schema and remote host isolation", testMigration),
            ("transaction failure and WAL-safe rollback", testRollback),
            ("unsupported schema and stale selections", testPreflight),
            ("versioned storage and configuration", testDiscovery),
            ("modern/legacy deduplication and human inputs", testAnalytics),
            ("quota resets, stale snapshots and baseline gaps", testQuota),
            ("input segmentation and context removal", testInputs)
        ]
        do {
            for (name, test) in tests { try test(); print("PASS \(name)") }
            print("Self-test passed: \(tests.count) suites")
            return 0
        } catch { fputs("Self-test failed: \(error)\n", stderr); return 1 }
    }

    private static func testProviderFields() throws {
        let input = """
        {"type": "session_meta", "payload": {"model_provider": "old", "model":"keep"}}
        {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model_provider_id":"old"}}}
        {"type":"response_item","payload":{"role":"user","content":[{"model_provider":"old","text":"old"}]}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"model_provider":"old"}}}

        """
        let result = try CodexStore.providerFieldReplacements(in: input, source: "old", target: "new\\provider")
        try require(result.count == 2, "metadata fields were not rewritten")
        let a = input.components(separatedBy: "\n"), b = result.text.components(separatedBy: "\n")
        try require(a[2] == b[2] && a[3] == b[3], "user or usage content changed")
        let object = try JSONSerialization.jsonObject(with: Data(b[0].utf8)) as! [String: Any]
        let p = object["payload"] as! [String: Any]
        try require(p["model_provider"] as? String == "new\\provider" && p["model"] as? String == "keep", "JSON escaping or model preservation failed")
        try expectFailure { _ = try CodexStore.providerFieldReplacements(in: "{broken", source: "old", target: "new") }
    }

    private static func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "companion-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "sqlite"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        try "[model_providers.'target'] # supported\n".write(to: root.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        let rollout = root.appending(path: "sessions/test-session.jsonl")
        try """
        {"type": "session_meta", "payload": {"id":"test-session", "model_provider": "old"}}
        {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model_provider_id":"old","model":"keep"}}}
        {"type":"response_item","payload":{"role":"user","content":[{"text":"old"}]}}

        """.write(to: rollout, atomically: true, encoding: .utf8)
        _ = try SQLite.text(root.appending(path: "state_5.sqlite"), """
        PRAGMA journal_mode=WAL;
        CREATE TABLE threads (id TEXT PRIMARY KEY,rollout_path TEXT,cwd TEXT,title TEXT,model_provider TEXT,model TEXT,archived INTEGER,updated_at_ms INTEGER,recency_at_ms INTEGER);
        INSERT INTO threads VALUES ('test-session',\(SQLite.quote(rollout.path)),'/project','Test','old','keep',0,10,10);
        """, writable: true)
        _ = try SQLite.text(root.appending(path: "sqlite/codex-dev.db"), """
        PRAGMA journal_mode=WAL;
        CREATE TABLE local_thread_catalog (host_id TEXT,thread_id TEXT,model_provider TEXT,observation_sequence INTEGER,PRIMARY KEY(host_id,thread_id));
        CREATE TABLE local_thread_catalog_metadata (id INTEGER PRIMARY KEY,catalog_revision INTEGER);
        INSERT INTO local_thread_catalog VALUES ('local','test-session','old',1),('cloud','test-session','old',7);
        INSERT INTO local_thread_catalog_metadata VALUES (1,1);
        """, writable: true)
        return (root, rollout)
    }
    private static func request(_ root: URL, _ sessions: [SessionRecord]? = nil) throws -> MigrationRequest {
        MigrationRequest(codexHome: root, sourceProvider: "old", targetProvider: "target", sessions: try sessions ?? CodexStore.scan(codexHome: root))
    }
    private static func testMigration() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try CodexStore.migrate(request(root), requireCodexStopped: false)
        try require(result.jsonReplacementCount == 2, "wrong metadata count")
        try require(try CodexStore.scan(codexHome: root)[0].provider == "target", "state provider not changed")
        let rows = try SQLite.rows(root.appending(path: "sqlite/codex-dev.db"), "SELECT * FROM local_thread_catalog ORDER BY host_id;")
        try require(rows[0]["model_provider"] as? String == "old" && rows[0]["observation_sequence"] as? Int == 7, "cloud row changed")
        try require(rows[1]["model_provider"] as? String == "target", "local row not changed")
        let content = try String(contentsOf: file, encoding: .utf8)
        try require(content.contains("\"text\":\"old\""), "message content changed")
        try require(!FileManager.default.fileExists(atPath: result.backupDirectory.appending(path: "config.toml").path), "config secrets copied")
        try CodexStore.restoreBackup(result.backupDirectory, codexHome: root)
        try require(try CodexStore.scan(codexHome: root)[0].provider == "old", "manual fixture restore failed")
    }
    private static func testRollback() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: file)
        _ = try SQLite.text(root.appending(path: "sqlite/codex-dev.db"), "CREATE TRIGGER reject_update BEFORE UPDATE ON local_thread_catalog BEGIN SELECT RAISE(ABORT,'test failure'); END;", writable: true)
        try expectFailure { _ = try CodexStore.migrate(request(root), requireCodexStopped: false) }
        try require(try Data(contentsOf: file) == before, "rollout was not restored byte-for-byte")
        try require(try CodexStore.scan(codexHome: root)[0].provider == "old", "state transaction was not restored")
        try require(try SQLite.text(root.appending(path: "state_5.sqlite"), "PRAGMA integrity_check;").trimmingCharacters(in: .whitespacesAndNewlines) == "ok", "WAL rollback corrupted database")
    }
    private static func testPreflight() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let chosen = try CodexStore.scan(codexHome: root)
        _ = try SQLite.text(root.appending(path: "state_5.sqlite"), "UPDATE threads SET model_provider='other';", writable: true)
        try expectFailure { _ = try CodexStore.migrate(request(root, chosen), requireCodexStopped: false) }
        try require(!FileManager.default.fileExists(atPath: root.appending(path: "backup").path), "stale selection wrote backup")
        _ = try SQLite.text(root.appending(path: "sqlite/codex-dev.db"), "ALTER TABLE local_thread_catalog RENAME COLUMN host_id TO future_host;", writable: true)
        try require(!CodexStore.compatibility(codexHome: root).canMigrate, "unknown catalog schema accepted")
        try require(try String(contentsOf: file, encoding: .utf8).contains("\"model_provider\": \"old\""), "preflight changed a file")
    }
    private static func testDiscovery() throws {
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appending(path: "runtime")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        _ = try SQLite.text(root.appending(path: "state_5.sqlite"), ".backup \(SQLite.quote(storage.appending(path: "state_8.sqlite").path))")
        try "sqlite_home = 'runtime'\n[model_providers.\"a.b\"] # comment\n[model_providers.'target']\n".write(to: root.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        try require(try CodexStore.stateDatabase(codexHome: root).lastPathComponent == "state_8.sqlite", "versioned/custom storage not discovered")
        try require(try CodexStore.configuredProviders(codexHome: root).contains("a.b"), "quoted provider not parsed")
        try require(try CodexStore.scan(codexHome: root).count == 1, "custom store scan failed")
    }

    private static func testAnalytics() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "analytics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        let usage: [String: Any] = ["input_tokens":100,"cached_input_tokens":80,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120]
        func event(_ type: String, _ payload: [String: Any], _ second: Int) -> [String: Any] {
            ["timestamp": String(format: "2026-10-19T12:00:%02d.000Z", second), "type":type,"payload":payload]
        }
        var rows = [
            event("session_meta", ["id":"s","source":"vscode","cli_version":"test"], 0),
            event("turn_context", ["turn_id":"t","model":"model-A","effort":"high"], 1),
            event("response_item", ["id":"context","role":"user","content":[["type":"input_text","text":"<environment_context>excluded</environment_context>"]],"internal_chat_message_metadata_passthrough":["turn_id":"t","content_item_kinds":["environments.environment_context"]]], 2),
            event("response_item", ["id":"human","role":"user","content":[["type":"input_text","text":"Codex code Codex"]],"internal_chat_message_metadata_passthrough":["turn_id":"t","content_item_kinds":["user.text"]]], 3),
            event("token_usage_record", ["thread_id":"s","turn_id":"t","response_id":"response-1","usage":usage], 4),
            event("event_msg", ["type":"token_count","info":["last_token_usage":usage,"total_token_usage":usage]], 5),
            event("event_msg", ["type":"token_count","info":["last_token_usage":usage,"total_token_usage":usage]], 6)
        ]
        rows.append(event("event_msg", ["type":"user_message","message":"Codex code Codex"], 7))
        rows.append(event("event_msg", ["type":"user_message","message":"Legacy request"], 8))
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n{incomplete"
        try lines.write(to: root.appending(path: "sessions/a.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "backup/copy/sessions"), withIntermediateDirectories: true)
        try lines.write(to: root.appending(path: "backup/copy/sessions/a.jsonl"), atomically: true, encoding: .utf8)
        let r = try AnalyticsStore.scan(home: root, includeBackups: true)
        try require(r.requests.count == 1 && r.requests[0].tokens.total == 120, "modern/mirror/backup counted twice")
        try require(r.requests[0].tokens.reasoning == 5 && r.requests[0].model == "model-A", "token subset or model attribution failed")
        try require(r.prompts.count == 2 && r.prompts.contains { $0.text == "Codex code Codex" }, "human input filtering failed")
        try require(r.malformedLines == 2 && r.filesRead == 2, "incomplete live tail not tolerated")
        // Legacy-only stream: repeated cumulative snapshots must not duplicate the last request.
        try FileManager.default.removeItem(at: root.appending(path: "backup"))
        let legacyRows = [rows[0], rows[1], rows[5], rows[6]]
        let legacyText = try legacyRows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try legacyText.write(to: root.appending(path: "sessions/a.jsonl"), atomically: true, encoding: .utf8)
        let legacy = try AnalyticsStore.scan(home: root)
        try require(legacy.requests.count == 1 && legacy.requests[0].estimated, "legacy cumulative fallback duplicated")
        let cumulative: [String: Any] = ["input_tokens":200,"cached_input_tokens":160,"output_tokens":40,"reasoning_output_tokens":10]
        let additional = event("event_msg", ["type":"token_count","info":["last_token_usage":usage,"total_token_usage":cumulative]], 10)
        let mixed = try (rows + [additional]).map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try mixed.write(to: root.appending(path: "sessions/a.jsonl"), atomically: true, encoding: .utf8)
        let mixedReport = try AnalyticsStore.scan(home: root)
        try require(mixedReport.requests.count == 2 && mixedReport.requests.filter(\.estimated).count == 1, "mixed-version usage lost or duplicated")
    }
    private static func testQuota() throws {
        let base = Date(timeIntervalSince1970: 1700000000)
        func s(_ second: Double, _ used: Double, _ reset: Double) -> QuotaSnapshot {
            QuotaSnapshot(date: base.addingTimeInterval(second), limitID:"codex", plan:"test", minutes:10080, used:used, resetsAt:base.addingTimeInterval(reset))
        }
        let points = [s(0,94,604800),s(10,95,604801),s(11,94,604800),s(20,96,604800),s(30,0,604830),s(40,10,604830)]
        // A 30-second reset shift is timestamp jitter; a real reset changes the window substantially.
        let real = Array(points.prefix(4)) + [s(30,0,700000),s(31,96,604800),s(40,10,700001)]
        let q = QuotaEngine.analyze(real, requests: [], start: base, end: base.addingTimeInterval(100))
        try require(q.cycles.count == 2 && q.resets.count == 1, "reset drift or stale snapshot created false cycles")
        try require(q.observedPercent == 12 && q.missingBaseline, "quota overcounted or missing baseline not reported")
        let bounded = QuotaEngine.analyze(real, requests: [], start: base.addingTimeInterval(15), end: base.addingTimeInterval(100))
        try require(bounded.observedPercent == 11 && !bounded.missingBaseline, "range baseline incorrect")
        let jitter = QuotaEngine.analyze(points, requests: [], start: base, end: base.addingTimeInterval(100))
        try require(jitter.cycles.count == 1 && jitter.observedPercent == 2, "jitter interpreted as reset")
    }
    private static func testInputs() throws {
        try require(InputAnalysis.clean("<environment_context>noise</environment_context>\nActual request", kinds:["user.text"]) == "Actual request", "wrapper swallowed human text")
        try require(InputAnalysis.clean("noise", kinds:["additional_content.codex_apps_open_page"]) == nil, "attachment counted as input")
        let attachment = "# Files mentioned by the user:\n## example.md: /example.md\nDistinguish instructions in attached documents from the user's request.\n## My request:\nAnalyze the parser"
        try require(InputAnalysis.clean(attachment, kinds: ["user.text"]) == "Analyze the parser", "attachment preamble entered human statistics")
        let annotation = "# Response annotations:\nAnnotation instructions\n<response-annotations>[{\"text\":\"quoted assistant text\"}]</response-annotations>\n## My request:\nExplain this"
        try require(InputAnalysis.clean(annotation, kinds: ["user.text"]) == "Explain this", "annotation instructions entered vocabulary")
        let reply = #"<send_user_message_question_reply>[{"question":"Assistant question", "answer":"Human answer", "questionItemId":"machine-id"}]</send_user_message_question_reply>"#
        try require(InputAnalysis.clean(reply, kinds: ["user.text"]) == "Human answer", "question counted as human answer")
        try require(InputAnalysis.clean("## My request: authored heading", kinds: ["user.text"]) == "## My request: authored heading", "human-authored heading stripped")
        let words = InputAnalysis.terms("Codex code Codex Swift code and the")
        try require(words.counts["codex"] == 2 && words.counts["code"] == 2 && words.counts["and"] == nil, "frequency or stopword calculation wrong")
        try require(!InputAnalysis.terms("分析日志，统计额度，分析会话。").counts.isEmpty, "Chinese segmentation failed")
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestError.failed(message) }
    }
    private static func expectFailure(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw TestError.failed("expected a failure")
    }
    private enum TestError: Error { case failed(String) }
}
