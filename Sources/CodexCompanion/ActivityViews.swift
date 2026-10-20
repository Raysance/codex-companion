import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            if let s = model.slice {
                VStack(spacing: 18) {
                    HStack(spacing: 14) {
                        MetricCard(title: "Tokens processed", value: Display.number(s.tokens.total), detail: "\(s.requests.count) model requests", icon: "cpu")
                        MetricCard(title: "Input cache hit", value: Display.ratio(s.tokens.cacheRate), detail: "\(Display.number(s.tokens.uncached)) non-cached input", icon: "arrow.triangle.2.circlepath")
                        MetricCard(title: "Quota observed", value: s.quota.observationsInRange > 0 ? "≈" + Display.percent(s.quota.observedPercent) : "—", detail: "All projects · selected quota window", icon: "gauge.with.dots.needle.50percent")
                        MetricCard(title: "Your inputs", value: "\(s.prompts.count)", detail: "\(Display.number(Int64(s.characters))) characters", icon: "text.bubble")
                    }
                    Panel(title: "Daily token activity") { TokenActivityChart(days: s.daily) }
                    HStack(alignment: .top, spacing: 18) {
                        Panel(title: "Most active chats") {
                            if s.sessions.isEmpty { Text("No requests in this period").foregroundStyle(.secondary) }
                            ForEach(Array(s.sessions.prefix(5))) { group in
                                HStack { Text(group.title).lineLimit(1); Spacer(); Text(Display.number(group.tokens.total)).monospacedDigit().foregroundStyle(.secondary) }
                                if group.id != s.sessions.prefix(5).last?.id { Divider() }
                            }
                        }
                        Panel(title: "Input vocabulary") {
                            if s.terms.isEmpty { Text("No inputs in this period").foregroundStyle(.secondary) }
                            ForEach(Array(s.terms.prefix(5))) { term in
                                HStack { Text(term.text); Spacer(); Text("\(term.count)").monospacedDigit().foregroundStyle(.secondary) }
                                if term.id != s.terms.prefix(5).last?.id { Divider() }
                            }
                        }
                    }
                    CoverageNote()
                }.padding(24)
            } else { EmptyActivityView() }
        }
    }
}

struct TokenActivityChart: View {
    let days: [DailyActivity]
    var body: some View {
        if days.isEmpty { Text("No activity in this period").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180) }
        else {
            Chart(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens.cached)).foregroundStyle(by: .value("Kind", "Cached input"))
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens.uncached)).foregroundStyle(by: .value("Kind", "Other input"))
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens.output)).foregroundStyle(by: .value("Kind", "Output"))
            }
            .chartForegroundStyleScale(["Cached input": Color.indigo.opacity(0.35), "Other input": .indigo, "Output": .teal])
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let n = value.as(Double.self) { Text(Display.number(Int64(n))) } }
                }
            }.frame(height: 210)
        }
    }
}

struct CoverageNote: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
            Text("\(model.report.filesRead) readable logs · \(model.report.indexedMissingLogs) indexed chats without logs · \(model.report.requests.filter(\.estimated).count) legacy estimates. \(model.report.malformedLines) skipped records, \(model.report.unreadableFiles) unreadable files.")
            Spacer()
        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct EmptyActivityView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ContentUnavailableView(model.isWorking ? "Reading history" : "No activity", systemImage: "chart.bar", description: Text(model.isWorking ? "" : "Choose another period or Codex home."))
            .frame(maxWidth: .infinity, minHeight: 300)
    }
}

struct UsageView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var search = ""
    @ViewState private var grouping = "Chats"
    @ViewState private var selected: String?
    @ViewState private var detail: UsageGroup?
    var body: some View {
        if let s = model.slice {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    MetricCard(title: "Input", value: Display.number(s.tokens.input), detail: "Includes cached input")
                    MetricCard(title: "Cached input", value: Display.number(s.tokens.cached), detail: Display.ratio(s.tokens.cacheRate) + " of input")
                    MetricCard(title: "Output", value: Display.number(s.tokens.output), detail: "\(Display.number(s.tokens.reasoning)) reasoning tokens included")
                }
                HStack {
                    Picker("Group", selection: $grouping) { Text("Chats").tag("Chats"); Text("Models").tag("Models") }.pickerStyle(.segmented).frame(width: 200)
                    if grouping == "Chats" {
                        Button("Inspect chat") { detail = s.sessions.first { $0.id == selected } }
                            .disabled(!s.sessions.contains { $0.id == selected })
                    }
                    Spacer()
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                let groups = (grouping == "Chats" ? s.sessions : s.models).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
                Table(groups, selection: $selected) {
                    TableColumn(grouping == "Chats" ? "Chat" : "Model") { g in Text(g.title).lineLimit(1).help(g.title) }.width(min: 160, ideal: 250)
                    TableColumn("Calls") { g in Text("\(g.requests)").monospacedDigit() }.width(50)
                    TableColumn("Input") { g in Text(Display.number(g.tokens.input)).help(g.tokens.input.formatted()) }.width(85)
                    TableColumn("Cache hit") { g in Text(Display.ratio(g.tokens.cacheRate)) }.width(75)
                    TableColumn("Output") { g in Text(Display.number(g.tokens.output)) }.width(75)
                    TableColumn("Total") { g in Text(Display.number(g.tokens.total)).fontWeight(.medium) }.width(90)
                    TableColumn("Quota ≈") { g in
                        Text(grouping == "Chats" ? s.quota.byThread[g.id].map(Display.percent) ?? "—" : "—")
                            .help("Observed increments with activity from one local chat. Shared account usage cannot be precisely attributed.")
                    }.width(80)
                    TableColumn("") { g in
                        if grouping == "Chats" { Button("Inspect") { detail = g }.buttonStyle(.link) }
                    }.width(55)
                }
                CoverageNote()
            }.padding(24)
            .sheet(item: $detail) { group in UsageDetailView(group: group, slice: s, report: model.report) }
        } else { EmptyActivityView() }
    }
}

struct UsageDetailView: View {
    let group: UsageGroup
    let slice: AnalyticsSlice
    let report: AnalyticsReport
    @Environment(\.dismiss) private var dismiss
    @ViewState private var turn: String?
    private var requests: [UsageRequest] { slice.requests.filter { $0.threadID == group.id } }
    private var turns: [String] { Array(Set(requests.map(\.turnID))).sorted { a, b in (requests.first { $0.turnID == a }?.date ?? .distantPast) < (requests.first { $0.turnID == b }?.date ?? .distantPast) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(group.title).font(.title3.weight(.semibold)).lineLimit(1); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("\(requests.count) requests · \(Display.number(group.tokens.total)) tokens").foregroundStyle(.secondary)
            Picker("Turn", selection: $turn) {
                Text("All turns").tag(String?.none)
                ForEach(turns, id: \.self) { id in
                    let prompt = slice.prompts.first { $0.turnID == id }
                    Text(prompt.map { String($0.text.prefix(60)) } ?? String(id.prefix(16))).tag(Optional(id))
                }
            }
            if let turn {
                ForEach(slice.prompts.filter { $0.turnID == turn }) { p in
                    ScrollView { Text(p.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 120)
                }
                let amount = requests.filter { $0.turnID == turn }.reduce(TokenUsage()) { $0 + $1.tokens }
                Text("Turn total \(amount.total.formatted()) · observed quota ≈ \(slice.quota.byTurn[turn].map(Display.percent) ?? "unattributed")").font(.caption).foregroundStyle(.secondary)
            }
            Table(requests.filter { turn == nil || $0.turnID == turn }) {
                TableColumn("Time") { r in Text(r.date.formatted(date: .omitted, time: .standard)).help(Display.date(r.date)) }.width(90)
                TableColumn("Model") { r in Text(r.model + " · " + r.effort).lineLimit(1) }.width(min: 160)
                TableColumn("Input") { r in Text(r.tokens.input.formatted()) }.width(90)
                TableColumn("Cached") { r in Text(r.tokens.cached.formatted()) }.width(90)
                TableColumn("Output") { r in Text(r.tokens.output.formatted()) }.width(70)
                TableColumn("Reasoning") { r in Text(r.tokens.reasoning.formatted()) }.width(75)
                TableColumn("Record") { r in Text(r.estimated ? "Legacy ≈" : String(r.id.suffix(8))).font(.caption.monospaced()).help(r.id) }.width(90)
            }
            Text("Reasoning is part of output; cached input is part of input. Token totals include repeated context.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 960, height: 620)
    }
}
