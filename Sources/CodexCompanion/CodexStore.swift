import Foundation

struct CodexStore: Sendable {
    private static var fm: FileManager { .default }

    static func stateDatabase(codexHome: URL) throws -> URL {
        let storage = try CodexConfig.read(codexHome).sqliteHome
        let files = try fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
        let candidates = files.compactMap { url -> (Int, URL)? in
            guard url.lastPathComponent.range(of: #"^state_\d+\.sqlite$"#, options: .regularExpression) != nil,
                  let version = Int(url.deletingPathExtension().lastPathComponent.dropFirst(6)) else { return nil }
            return (version, url)
        }.sorted { $0.0 > $1.0 }
        guard let url = candidates.first?.1 else { throw CompanionError.missingFile(storage.appending(path: "state_*.sqlite").path) }
        return url
    }

    static func compatibility(codexHome: URL) -> CompatibilityReport {
        var report = CompatibilityReport()
        do {
            let state = try stateDatabase(codexHome: codexHome)
            report.statePath = state.path
            let columns = try SQLite.columns(state, "threads")
            let required: Set<String> = ["id", "rollout_path", "cwd", "title", "model_provider", "archived"]
            guard required.isSubset(of: columns) else {
                throw CompanionError.unsupportedStorage("Unsupported threads schema: missing \(required.subtracting(columns).sorted().joined(separator: ", ")).")
            }
            report.checks.append("Session schema supported")
            let catalog = codexHome.appending(path: "sqlite/codex-dev.db")
            if fm.fileExists(atPath: catalog.path) {
                let c = try SQLite.columns(catalog, "local_thread_catalog")
                let m = try SQLite.columns(catalog, "local_thread_catalog_metadata")
                guard Set(["host_id", "thread_id", "model_provider", "observation_sequence"]).isSubset(of: c),
                      Set(["id", "catalog_revision"]).isSubset(of: m) else {
                    throw CompanionError.unsupportedStorage("Unsupported local catalog schema. No changes were made.")
                }
                report.catalogPath = catalog.path
                report.checks.append("Catalog writes restricted to host local")
            } else { report.checks.append("No desktop catalog; session store only") }
            let sessions = try scan(codexHome: codexHome)
            report.missingRollouts = sessions.filter { !fm.fileExists(atPath: $0.rolloutPath) }.count
            report.checks.append("\(sessions.count) indexed sessions · \(report.missingRollouts) missing logs")
            report.checks.append("Provider changes preserve model, messages and usage")
        } catch { report.blockers.append(error.localizedDescription) }
        return report
    }

    static func scan(codexHome: URL) throws -> [SessionRecord] {
        let db = try stateDatabase(codexHome: codexHome)
        let c = try SQLite.columns(db, "threads")
        guard Set(["id", "rollout_path", "cwd", "title", "model_provider", "archived"]).isSubset(of: c) else {
            throw CompanionError.unsupportedStorage("The threads table is not supported.")
        }
        let model = c.contains("model") ? "model" : "NULL AS model"
        let updated = c.contains("updated_at_ms") ? "COALESCE(updated_at_ms,0)" : (c.contains("updated_at") ? "updated_at*1000" : "0")
        let rows = try SQLite.rows(db, "SELECT id, rollout_path, cwd, title, model_provider, \(model), archived, \(updated) AS updated FROM threads ORDER BY updated DESC;")
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let path = row["rollout_path"] as? String else { return nil }
            let rawTitle = row["title"] as? String ?? "Untitled session"
            let title = (InputAnalysis.clean(rawTitle, kinds: nil) ?? rawTitle).components(separatedBy: .newlines).joined(separator: " ")
            return SessionRecord(id: id, rolloutPath: path, cwd: row["cwd"] as? String ?? "", title: title.isEmpty ? "Untitled session" : title,
                                 provider: row["model_provider"] as? String ?? "", model: row["model"] as? String ?? "Unknown model",
                                 isArchived: (row["archived"] as? Int ?? 0) != 0, updatedAt: (row["updated"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    static func configuredProviders(codexHome: URL) throws -> Set<String> { try CodexConfig.read(codexHome).providers }

    static func isCodexRunning() -> Bool {
        guard let list = try? SQLite.process("/bin/ps", ["-axo", "comm="]) else { return true }
        return list.components(separatedBy: .newlines).contains { line in
            let name = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased()
            return ["codex", "chatgpt", "codex-app-server"].contains(name)
        }
    }

    static func migrate(_ request: MigrationRequest, requireCodexStopped: Bool = true) throws -> MigrationResult {
        guard !request.sessions.isEmpty else { throw CompanionError.noSessionsSelected }
        guard request.sourceProvider != request.targetProvider else { throw CompanionError.sameProvider }
        if requireCodexStopped && isCodexRunning() { throw CompanionError.codexIsRunning }
        guard try configuredProviders(codexHome: request.codexHome).contains(request.targetProvider) else {
            throw CompanionError.targetProviderNotConfigured(request.targetProvider)
        }
        let report = compatibility(codexHome: request.codexHome)
        guard report.canMigrate else { throw CompanionError.unsupportedStorage(report.blockers.joined(separator: " ")) }
        let current = Dictionary(uniqueKeysWithValues: try scan(codexHome: request.codexHome).map { ($0.id, $0) })
        guard Set(request.sessions.map(\.id)).count == request.sessions.count else {
            throw CompanionError.unsupportedStorage("Duplicate selection.")
        }
        for session in request.sessions {
            guard session.id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw CompanionError.unsupportedStorage("Invalid session identifier.")
            }
            guard let live = current[session.id], live.provider == request.sourceProvider,
                  live.rolloutPath == session.rolloutPath else {
                throw CompanionError.unsupportedStorage("Session state changed. Scan again.")
            }
            let path = URL(fileURLWithPath: session.rolloutPath).resolvingSymlinksInPath().path
            let allowed = ["sessions", "archived_sessions"].contains { name in
                path.hasPrefix(request.codexHome.appending(path: name).resolvingSymlinksInPath().path + "/")
            }
            guard allowed else { throw CompanionError.unsupportedStorage("A selected log is outside this Codex home.") }
            guard fm.fileExists(atPath: path) else { throw CompanionError.missingFile(path) }
        }
        let backup = try createBackup(request, report)
        var count = 0
        do {
            if requireCodexStopped && isCodexRunning() { throw CompanionError.codexIsRunning }
            for s in request.sessions {
                let url = URL(fileURLWithPath: s.rolloutPath)
                let result = try providerFieldReplacements(in: String(contentsOf: url, encoding: .utf8), source: request.sourceProvider, target: request.targetProvider)
                if result.count > 0 { try result.text.write(to: url, atomically: true, encoding: .utf8) }
                count += result.count
            }
            if requireCodexStopped && isCodexRunning() { throw CompanionError.codexIsRunning }
            try updateDatabases(request, report)
            try verify(request, report)
        } catch {
            let original = error
            if requireCodexStopped && isCodexRunning() {
                throw CompanionError.rollbackFailed("Codex started during migration. Quit it before restoring: \(backup.path)")
            }
            do { try restoreBackup(backup, codexHome: request.codexHome) }
            catch { throw CompanionError.rollbackFailed("Backup: \(backup.path). \(error.localizedDescription)") }
            throw original
        }
        return MigrationResult(migratedCount: request.sessions.count, jsonReplacementCount: count, backupDirectory: backup)
    }

    /// Rewrite only known metadata locations. Never traverse user messages, tool output or historical model data.
    static func providerFieldReplacements(in input: String, source: String, target: String) throws -> (text: String, count: Int) {
        var count = 0
        let lines = try input.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return line }
            guard let data = line.data(using: .utf8), var record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = record["type"] as? String else { throw CompanionError.verificationFailed("Invalid JSONL record.") }
            guard var payload = record["payload"] as? [String: Any] else { return line }
            var changed = 0
            if type == "session_meta" || type == "turn_context" {
                if payload["model_provider"] as? String == source { payload["model_provider"] = target; changed += 1 }
            }
            if type == "event_msg", payload["type"] as? String != "thread_settings_applied",
               let settings = payload["thread_settings"] as? [String: Any],
               ["model_provider", "model_provider_id"].contains(where: { settings[$0] as? String == source }) {
                throw CompanionError.unsupportedStorage("Unknown provider-settings event. No metadata format was assumed.")
            }
            if type == "event_msg", payload["type"] as? String == "thread_settings_applied",
               var settings = payload["thread_settings"] as? [String: Any] {
                for key in ["model_provider_id", "model_provider"] where settings[key] as? String == source {
                    settings[key] = target; changed += 1
                }
                payload["thread_settings"] = settings
            }
            guard changed > 0 else { return line }
            record["payload"] = payload
            count += changed
            return String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return (lines.joined(separator: "\n"), count)
    }

    private static func createBackup(_ request: MigrationRequest, _ report: CompatibilityReport) throws -> URL {
        let format = DateFormatter(); format.dateFormat = "yyyyMMdd-HHmmss"; format.locale = Locale(identifier: "en_US_POSIX")
        let root = request.codexHome.appending(path: "backup/provider-migrator-\(format.string(from: Date()))-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for (name, path) in [("state.sqlite", Optional(report.statePath)), ("catalog.sqlite", report.catalogPath)] {
            if let path { _ = try SQLite.text(URL(fileURLWithPath: path), ".backup \(SQLite.quote(root.appending(path: name).path))") }
        }
        for s in request.sessions { try fm.copyItem(atPath: s.rolloutPath, toPath: root.appending(path: "sessions/\(s.id).jsonl").path) }
        // Credentials/config are not changed and are intentionally not copied into backups.
        let manifest = BackupManifest(createdAt: Date(), sourceProvider: request.sourceProvider, targetProvider: request.targetProvider,
                                      sessions: request.sessions, stateDatabasePath: report.statePath, catalogDatabasePath: report.catalogPath)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appending(path: "manifest.json"), options: .atomic)
        return root
    }

    static func restoreBackup(_ backup: URL, codexHome: URL) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: backup.appending(path: "manifest.json")))
        let state = URL(fileURLWithPath: manifest.stateDatabasePath ?? codexHome.appending(path: "state_5.sqlite").path)
        let stateSaved = backup.appending(path: manifest.stateDatabasePath == nil ? "state_5.sqlite" : "state.sqlite")
        // SQLite .restore preserves WAL consistency; replacing only the main file can replay stale WAL pages.
        _ = try SQLite.text(state, ".restore \(SQLite.quote(stateSaved.path))", writable: true)
        if let path = manifest.catalogDatabasePath {
            _ = try SQLite.text(URL(fileURLWithPath: path), ".restore \(SQLite.quote(backup.appending(path: "catalog.sqlite").path))", writable: true)
        }
        for s in manifest.sessions {
            let data = try Data(contentsOf: backup.appending(path: "sessions/\(s.id).jsonl"))
            try data.write(to: URL(fileURLWithPath: s.rolloutPath), options: .atomic)
        }
    }

    private static func updateDatabases(_ request: MigrationRequest, _ report: CompatibilityReport) throws {
        let ids = request.sessions.map { SQLite.quote($0.id) }.joined(separator: ",")
        var script = ""
        if let catalog = report.catalogPath { script += "ATTACH DATABASE \(SQLite.quote(catalog)) AS catalog;\n" }
        script += "BEGIN IMMEDIATE;\nUPDATE threads SET model_provider=\(SQLite.quote(request.targetProvider)) WHERE id IN (\(ids)) AND model_provider=\(SQLite.quote(request.sourceProvider));\n"
        if report.catalogPath != nil {
            script += """
            UPDATE catalog.local_thread_catalog SET model_provider=\(SQLite.quote(request.targetProvider)), observation_sequence=observation_sequence+1
            WHERE host_id='local' AND thread_id IN (\(ids)) AND model_provider=\(SQLite.quote(request.sourceProvider));
            UPDATE catalog.local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1;
            """
        }
        script += "\nCOMMIT;"
        _ = try SQLite.text(URL(fileURLWithPath: report.statePath), script, writable: true)
    }

    private static func verify(_ request: MigrationRequest, _ report: CompatibilityReport) throws {
        let ids = request.sessions.map { SQLite.quote($0.id) }.joined(separator: ",")
        let rows = try SQLite.rows(URL(fileURLWithPath: report.statePath), "SELECT COUNT(*) AS count FROM threads WHERE id IN (\(ids)) AND model_provider=\(SQLite.quote(request.targetProvider));")
        guard rows.first?["count"] as? Int == request.sessions.count else { throw CompanionError.verificationFailed("Session rows did not match the selection.") }
        if let path = report.catalogPath {
            let stale = try SQLite.rows(URL(fileURLWithPath: path), "SELECT COUNT(*) AS count FROM local_thread_catalog WHERE host_id='local' AND thread_id IN (\(ids)) AND COALESCE(model_provider,'')!=\(SQLite.quote(request.targetProvider));")
            guard stale.first?["count"] as? Int == 0 else { throw CompanionError.verificationFailed("Local catalog provider mismatch.") }
        }
        for s in request.sessions {
            let text = try String(contentsOfFile: s.rolloutPath, encoding: .utf8)
            guard try providerFieldReplacements(in: text, source: request.sourceProvider, target: request.targetProvider).count == 0 else {
                throw CompanionError.verificationFailed("Old metadata remained in a selected log.")
            }
        }
        for path in [Optional(report.statePath), report.catalogPath].compactMap({ $0 }) {
            guard try SQLite.text(URL(fileURLWithPath: path), "PRAGMA integrity_check;").trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                throw CompanionError.verificationFailed("Database integrity check failed.")
            }
        }
    }
}
