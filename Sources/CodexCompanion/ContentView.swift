import SwiftUI

// Use the stable property wrapper on SDKs that also expose the new State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

private enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", usage = "Token usage", quota = "Quota", inputs = "Your inputs", migration = "Provider migration", storage = "Storage"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .usage: "chart.bar.xaxis"
        case .quota: "gauge.with.dots.needle.50percent"
        case .inputs: "text.bubble"
        case .migration: "arrow.triangle.2.circlepath"
        case .storage: "externaldrive"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var page: Page? = .overview

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command.square.fill").font(.title).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex").font(.title3.weight(.semibold))
                        Text("Companion").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
                List(selection: $page) {
                    Section("Activity") {
                        ForEach([Page.overview, .usage, .quota, .inputs]) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
                    }
                    Section("Tools") {
                        ForEach([Page.migration, .storage]) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    Label("On this Mac", systemImage: "lock.shield").font(.caption.weight(.medium))
                    Text(model.statusMessage).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }.padding(16)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Text((page ?? .overview).rawValue).font(.title2.weight(.semibold))
                    Spacer()
                    if model.isWorking || model.isSlicing { ProgressView().controlSize(.small) }
                    Button { model.scan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.isWorking)
                }.padding(.horizontal, 24).padding(.vertical, 18)
                if [.overview, .usage, .quota, .inputs].contains(page ?? .overview) { filters }
                Divider()
                Group {
                    switch page ?? .overview {
                    case .overview: OverviewView()
                    case .usage: UsageView()
                    case .quota: QuotaView()
                    case .inputs: InputsView()
                    case .migration: MigrationView()
                    case .storage: StorageView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1080, minHeight: 740)
        .task { model.scan() }
        .onChange(of: model.range) { _, _ in model.refreshSlice() }
        .onChange(of: model.customStart) { _, _ in model.refreshSlice() }
        .onChange(of: model.customEnd) { _, _ in model.refreshSlice() }
        .onChange(of: model.analyticsProject) { _, _ in model.refreshSlice() }
        .onChange(of: model.quotaScope) { _, _ in model.refreshSlice() }
        .alert("Operation stopped", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Migrate \(model.selectedSessions.count) sessions?", isPresented: $model.showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Back up and migrate") { model.migrate() }
        } message: { Text("\(model.sourceProvider) → \(model.targetProvider). A backup is created before local metadata changes. Model and account settings stay as configured.") }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("Period", selection: $model.range) { ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 470)
                if page != .quota {
                    Picker("Project", selection: $model.analyticsProject) {
                        Text("All projects").tag("")
                        ForEach(model.projects, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                    }.labelsHidden().frame(maxWidth: 210)
                }
                Spacer(minLength: 0)
                if page == .usage { Button("Export CSV") { model.exportRequests() }.disabled(model.slice == nil || model.isWorking || model.isSlicing) }
            }
            if model.range == .custom {
                HStack {
                    DatePicker("From", selection: $model.customStart, displayedComponents: .date)
                    DatePicker("To", selection: $model.customEnd, displayedComponents: .date)
                }.fixedSize()
            }
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var detail: String = ""
    var icon: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.callout).foregroundStyle(.secondary); Spacer(); if !icon.isEmpty { Image(systemName: icon).foregroundStyle(.secondary) } }
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .topLeading)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06)))
    }
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { Text(title).font(.headline); content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06)))
    }
}

enum Display {
    static func number(_ n: Int64) -> String { n.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) }
    static func percent(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0...1))) + "%" }
    static func ratio(_ n: Double) -> String { percent(n * 100) }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}
