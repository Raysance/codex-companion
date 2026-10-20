import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum AnalyticsRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days", all = "All history", custom = "Custom"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var codexHomePath = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSString(string: "~/.codex").expandingTildeInPath
    @Published var sessions: [SessionRecord] = []
    @Published var selectedIDs: Set<String> = []
    @Published var sourceProvider = ""
    @Published var targetProvider = "openai"
    @Published var projectFilter = ""
    @Published var searchText = ""
    @Published var configuredProviders: Set<String> = ["openai"]
    @Published var isWorking = false
    @Published var isSlicing = false
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?
    @Published var lastBackupDirectory: URL?
    @Published var codexRunning = false
    @Published var showConfirmation = false
    @Published var compatibility = CompatibilityReport()
    @Published var report = AnalyticsReport()
    @Published var slice: AnalyticsSlice?
    @Published var range: AnalyticsRange = .week
    @Published var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var customEnd = Date()
    @Published var quotaScope = ""
    @Published var analyticsProject = ""
    @Published var includeBackups = false
    @Published var selectedSessionID: String?
    @Published var promptSearch = ""
    private var slicing: Task<Void, Never>?
    private var generation = 0

    var sourceProviders: [String] { Array(Set(sessions.map(\.provider))).sorted() }
    var projects: [String] { Array(Set(report.sessions.map(\.cwd).filter { !$0.isEmpty })).sorted() }
    var filteredSessions: [SessionRecord] {
        sessions.filter { s in
            (sourceProvider.isEmpty || s.provider == sourceProvider) && (projectFilter.isEmpty || s.cwd == projectFilter) &&
            (searchText.isEmpty || s.title.localizedCaseInsensitiveContains(searchText) || s.cwd.localizedCaseInsensitiveContains(searchText) || s.id.localizedCaseInsensitiveContains(searchText))
        }
    }
    var selectedSessions: [SessionRecord] { sessions.filter { selectedIDs.contains($0.id) && $0.provider == sourceProvider } }
    var canMigrate: Bool {
        !isWorking && compatibility.canMigrate && !selectedSessions.isEmpty && !sourceProvider.isEmpty &&
        sourceProvider != targetProvider && configuredProviders.contains(targetProvider) && !codexRunning &&
        selectedSessions.allSatisfy { FileManager.default.fileExists(atPath: $0.rolloutPath) }
    }

    func scan() {
        guard !isWorking else { return }
        if CommandLine.arguments.contains("--demo") {
            report = DemoData.report(); sessions = report.sessions
            compatibility = CompatibilityReport(blockers: ["Demo mode is read-only"])
            quotaScope = report.quotaScopes.first ?? ""; codexHomePath = "Demo data"
            statusMessage = "Demo data · no local history read"; refreshSlice(); return
        }
        isWorking = true; errorMessage = nil; statusMessage = "Reading local history…"
        generation += 1; slicing?.cancel()
        let home = URL(fileURLWithPath: NSString(string: codexHomePath).expandingTildeInPath, isDirectory: true)
        let backups = includeBackups
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let report = try AnalyticsStore.scan(home: home, includeBackups: backups)
                    let compatibility = CodexStore.compatibility(codexHome: home)
                    let providers = (try? CodexStore.configuredProviders(codexHome: home)) ?? ["openai"]
                    return (report, compatibility, providers, CodexStore.isCodexRunning())
                }.value
                report = result.0; sessions = result.0.sessions; compatibility = result.1
                configuredProviders = result.2; codexRunning = result.3
                if sourceProvider.isEmpty || !sourceProviders.contains(sourceProvider) {
                    sourceProvider = sourceProviders.first(where: { $0 != "openai" }) ?? sourceProviders.first ?? ""
                }
                if !report.quotaScopes.contains(quotaScope) {
                    quotaScope = report.quotas.last(where: { $0.minutes == 10080 && $0.limitID == "codex" })?.scope ?? report.quotaScopes.first ?? ""
                }
                if !analyticsProject.isEmpty && !projects.contains(analyticsProject) { analyticsProject = "" }
                selectedIDs.formIntersection(Set(sessions.map(\.id)))
                statusMessage = "\(report.filesRead) logs · \(report.requests.count) requests · \(report.prompts.count) inputs"
                isWorking = false; refreshSlice()
            } catch {
                errorMessage = error.localizedDescription; statusMessage = "Could not read history"; isWorking = false
            }
        }
    }

    func refreshSlice() {
        generation += 1; let revision = generation
        slicing?.cancel()
        let report = report, scope = quotaScope, project = analyticsProject
        let end: Date = range == .custom ? (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customEnd)) ?? customEnd).addingTimeInterval(-0.001) : Date()
        let start: Date
        switch range {
        case .today: start = Calendar.current.startOfDay(for: end)
        case .week: start = end.addingTimeInterval(-7 * 86400)
        case .month: start = end.addingTimeInterval(-30 * 86400)
        case .all: start = report.oldest ?? end
        case .custom: start = Calendar.current.startOfDay(for: customStart)
        }
        guard start <= end else { isSlicing = false; slice = nil; statusMessage = "Start date must precede end date"; return }
        isSlicing = true
        slicing = Task {
            let value = await Task.detached(priority: .userInitiated) {
                AnalyticsSlice.build(report: report, start: start, end: end, scope: scope, project: project)
            }.value
            if !Task.isCancelled && generation == revision { slice = value; isSlicing = false }
        }
    }

    func selectAllFiltered() { selectedIDs.formUnion(filteredSessions.map(\.id)) }
    func clearSelection() { selectedIDs.removeAll() }
    func chooseCodexHome() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: codexHomePath)
        if panel.runModal() == .OK, let url = panel.url { codexHomePath = url.path; scan() }
    }
    func chooseProject() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK, let url = p.url { projectFilter = url.path }
    }
    func migrate() {
        codexRunning = CodexStore.isCodexRunning()
        guard canMigrate else { return }
        isWorking = true; errorMessage = nil; statusMessage = "Backing up and migrating…"
        let request = MigrationRequest(codexHome: URL(fileURLWithPath: codexHomePath), sourceProvider: sourceProvider, targetProvider: targetProvider, sessions: selectedSessions)
        Task {
            do {
                let result = try await Task.detached { try CodexStore.migrate(request) }.value
                lastBackupDirectory = result.backupDirectory; selectedIDs.removeAll(); isWorking = false
                scan()
            } catch {
                errorMessage = error.localizedDescription; statusMessage = "Migration stopped"
                codexRunning = CodexStore.isCodexRunning(); isWorking = false
            }
        }
    }
    func revealBackup() {
        if let lastBackupDirectory { NSWorkspace.shared.activateFileViewerSelecting([lastBackupDirectory]) }
    }
    func exportRequests() {
        guard let slice else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "codex-usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func cell(_ value: String) -> String {
            let safe = ["=", "+", "-", "@"].contains(String(value.prefix(1))) ? "'" + value : value
            return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        let header = "timestamp,response_id,thread_id,turn_id,model,effort,input,cached_input,cache_write,output,reasoning,total,estimated\n"
        let rows = slice.requests.map { r in
            [r.date.ISO8601Format(), r.id, r.threadID, r.turnID, r.model, r.effort, String(r.tokens.input), String(r.tokens.cached), String(r.tokens.cacheWrite), String(r.tokens.output), String(r.tokens.reasoning), String(r.tokens.total), String(r.estimated)].map(cell).joined(separator: ",")
        }
        do { try (header + rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8); statusMessage = "Exported \(rows.count) requests" }
        catch { errorMessage = error.localizedDescription }
    }
}
