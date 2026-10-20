import SwiftUI

struct MigrationView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Picker("From", selection: $model.sourceProvider) {
                    if model.sourceProviders.isEmpty { Text("No providers").tag("") }
                    ForEach(model.sourceProviders, id: \.self) { Text($0).tag($0) }
                }.frame(width: 240)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("To", selection: $model.targetProvider) {
                    ForEach(model.configuredProviders.sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 230)
                Spacer()
            }
            if model.codexRunning {
                HStack(spacing: 10) {
                    Label("Quit Codex before migrating", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Check again") { model.codexRunning = CodexStore.isCodexRunning() }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !model.compatibility.canMigrate {
                ForEach(model.compatibility.blockers, id: \.self) { Text($0).font(.callout).foregroundStyle(.red) }
            }
            HStack {
                TextField("Search chats or paths", text: $model.searchText).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                TextField("Project path", text: $model.projectFilter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button("Choose…") { model.chooseProject() }
                if !model.projectFilter.isEmpty { Button("Clear") { model.projectFilter = "" } }
                Spacer()
                Button("Select all") { model.selectAllFiltered() }
                Button("Clear") { model.clearSelection() }
            }
            Table(model.filteredSessions, selection: $model.selectedIDs) {
                TableColumn("Chat") { s in VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).lineLimit(1)
                    Text(s.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }}.width(min: 240)
                TableColumn("Provider", value: \.provider).width(110)
                TableColumn("Model", value: \.model).width(140)
                TableColumn("Log") { s in
                    Text(FileManager.default.fileExists(atPath: s.rolloutPath) ? (s.isArchived ? "Archived" : "Available") : "Missing")
                        .foregroundStyle(FileManager.default.fileExists(atPath: s.rolloutPath) ? Color.secondary : .orange)
                }.width(90)
            }
            HStack {
                Text("\(model.selectedSessions.count) selected").foregroundStyle(.secondary)
                if model.lastBackupDirectory != nil { Button("Show backup") { model.revealBackup() } }
                Spacer()
                Button("Back up and migrate") {
                    model.codexRunning = CodexStore.isCodexRunning()
                    if model.canMigrate { model.showConfirmation = true }
                }.buttonStyle(.borderedProminent).disabled(!model.canMigrate)
            }
            Text("Changes provider metadata in selected local logs and databases. Authentication, model settings and cloud entries are preserved.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).onChange(of: model.sourceProvider) { _, _ in model.clearSelection() }
    }
}

struct StorageView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Panel(title: "Data source") {
                    HStack {
                        Text(model.codexHomePath).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Choose folder…") { model.chooseCodexHome() }.disabled(model.isWorking)
                    }
                    Toggle("Include migration backups", isOn: $model.includeBackups).disabled(model.isWorking)
                        .onChange(of: model.includeBackups) { _, _ in model.scan() }
                    Text("Active and archived logs are always included. Backup copies are deduplicated by request and message IDs.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    MetricCard(title: "Logs read", value: "\(model.report.filesRead)", detail: "\(model.report.indexedMissingLogs) indexed logs missing")
                    MetricCard(title: "First observation", value: model.report.oldest?.formatted(date: .abbreviated, time: .omitted) ?? "—", detail: "Within discovered logs")
                    MetricCard(title: "Context excluded", value: "\(model.report.excludedContext)", detail: "\(model.report.subagentPrompts) agent prompt records excluded")
                }
                Panel(title: "Migration compatibility") {
                    Label(model.compatibility.canMigrate ? "Supported storage schema" : "Migration unavailable", systemImage: model.compatibility.canMigrate ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.compatibility.canMigrate ? .green : .orange)
                    ForEach(model.compatibility.checks, id: \.self) { Text($0).font(.callout) }
                    ForEach(model.compatibility.blockers, id: \.self) { Text($0).foregroundStyle(.red) }
                    if !model.compatibility.statePath.isEmpty { Text(model.compatibility.statePath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Unsupported schemas block migration; analytics remain available.").font(.caption).foregroundStyle(.secondary)
                }
                Panel(title: "Coverage") {
                    CoverageNote()
                    Text("Recorded runtimes: " + model.report.runtimeVersions.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("History starts at the first available record. Missing or deleted logs cannot be reconstructed from the session index. Cached tokens and reasoning tokens are subsets, not extra tokens.").font(.callout).foregroundStyle(.secondary)
                }
                Panel(title: "Privacy") {
                    Text("Analysis runs locally, in memory. The app does not read credentials or send data to a service. Request CSV exports include IDs and usage; input text is not exported.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
    }
}
