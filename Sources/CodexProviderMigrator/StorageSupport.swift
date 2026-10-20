import Foundation

/// All ordinary queries are opened read-only; only the migration path uses writes.
enum SQLite {
    static func text(_ database: URL, _ sql: String, writable: Bool = false) throws -> String {
        let args = (writable ? [] : ["-readonly"]) + ["-bail", "-cmd", ".timeout 5000", database.path, sql]
        return try query(database, args, writable: writable)
    }

    static func rows(_ database: URL, _ sql: String) throws -> [[String: Any]] {
        let output = try query(database, ["-readonly", "-json", "-bail", "-cmd", ".timeout 5000", database.path, sql])
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else {
            throw MigratorError.invalidDatabaseOutput
        }
        return rows
    }

    static func columns(_ database: URL, _ table: String) throws -> Set<String> {
        Set(try rows(database, "PRAGMA table_info(\(quote(table))); ").compactMap { $0["name"] as? String })
    }

    static func quote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "''"))'" }

    private static func query(_ database: URL, _ arguments: [String], writable: Bool = false) throws -> String {
        do { return try process("/usr/bin/sqlite3", arguments) }
        catch {
            // Some macOS SQLite builds cannot initialize an absent WAL index in read-only mode.
            // Immutable reads are safe only for a stable main file with no pending WAL pages.
            guard !writable, error.localizedDescription.contains("(14)") else { throw error }
            let fm = FileManager.default
            func stamp() throws -> (UInt64, Date) {
                let attrs = try fm.attributesOfItem(atPath: database.path)
                let wal = database.path + "-wal"
                if fm.fileExists(atPath: wal), (try fm.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.int64Value != 0 {
                    throw MigratorError.unsupportedStorage("Pending WAL could not be read. Refresh after Codex finishes writing.")
                }
                return ((attrs[.size] as? NSNumber)?.uint64Value ?? 0, attrs[.modificationDate] as? Date ?? .distantPast)
            }
            let before = try stamp()
            let uri = database.absoluteString + "?immutable=1"
            let result = try process("/usr/bin/sqlite3", arguments.map { $0 == database.path ? uri : $0 })
            guard try stamp() == before else { throw MigratorError.unsupportedStorage("Storage changed while reading. Refresh and try again.") }
            return result
        }
    }

    static func process(_ executable: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw MigratorError.commandFailed(command: URL(fileURLWithPath: executable).lastPathComponent + " " + (args.first(where: { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") }) ?? ""), output: text)
        }
        return text
    }
}

enum JSONLines {
    /// Keeps memory bounded by one line, including for long, actively written rollouts.
    static func read(_ url: URL, _ body: (Data) throws -> Void) throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var pending = Data()
        while let chunk = try h.read(upToCount: 262144), !chunk.isEmpty {
            pending.append(chunk)
            while let split = pending.firstIndex(of: 10) {
                let line = pending[..<split]
                if !line.isEmpty { try body(Data(line)) }
                pending.removeSubrange(...split)
            }
        }
        if !pending.isEmpty { try body(pending) }
    }
}

enum CodexConfig {
    /// Only the small set needed for storage discovery. Unsupported relevant TOML fails closed.
    static func read(_ home: URL) throws -> (providers: Set<String>, sqliteHome: URL) {
        let url = home.appending(path: "config.toml")
        var providers: Set<String> = ["openai"]
        var storage = home
        if FileManager.default.fileExists(atPath: url.path) {
            let content = try String(contentsOf: url, encoding: .utf8)
            var atRoot = true
            for raw in content.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    atRoot = false
                    let pattern = #"^\[\s*model_providers\.(?:"([^"\\]+)"|'([^']+)'|([A-Za-z0-9_-]+))\s*\]\s*(?:#.*)?$"#
                    let regex = try NSRegularExpression(pattern: pattern)
                    if let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                        for n in 1...3 where m.range(at: n).location != NSNotFound {
                            if let r = Range(m.range(at: n), in: line) { providers.insert(String(line[r])) }
                        }
                    } else if line.hasPrefix("[model_providers.") {
                        throw MigratorError.unsupportedStorage("Unsupported provider declaration in config.toml.")
                    }
                } else if atRoot && line.range(of: #"^sqlite_home\s*="#, options: .regularExpression) != nil {
                    let value = line.split(separator: "=", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)
                    let pattern = #"^("(?:[^"\\]|\\.)*"|'[^']*')\s*(?:#.*)?$"#
                    let regex = try NSRegularExpression(pattern: pattern)
                    guard let m = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                          let r = Range(m.range(at: 1), in: value) else {
                        throw MigratorError.unsupportedStorage("Unsupported sqlite_home value in config.toml.")
                    }
                    let literal = String(value[r])
                    let path: String
                    if literal.hasPrefix("\"") {
                        guard let decoded = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)) else {
                            throw MigratorError.unsupportedStorage("Cannot decode sqlite_home.")
                        }
                        path = decoded
                    } else { path = String(literal.dropFirst().dropLast()) }
                    let expanded = NSString(string: path).expandingTildeInPath
                    storage = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : home.appending(path: expanded)
                }
            }
        }
        // Honor this only for the actual configured CODEX_HOME, never for a fixture or another chosen home.
        let env = ProcessInfo.processInfo.environment
        let actualHome = URL(fileURLWithPath: env["CODEX_HOME"] ?? NSString(string: "~/.codex").expandingTildeInPath)
        if home.standardizedFileURL == actualHome.standardizedFileURL,
           let override = env["CODEX_SQLITE_HOME"], !override.isEmpty {
            storage = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return (providers, storage)
    }
}
