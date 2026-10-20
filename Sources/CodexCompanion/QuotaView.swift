import Charts
import SwiftUI

struct QuotaView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            if let s = model.slice {
                let q = s.quota
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Picker("Window", selection: $model.quotaScope) {
                            if model.report.quotaScopes.isEmpty { Text("No quota snapshots").tag("") }
                            ForEach(model.report.quotaScopes, id: \.self) { Text($0).tag($0) }
                        }.frame(maxWidth: 580)
                        Spacer()
                    }
                    HStack(spacing: 14) {
                        MetricCard(title: "Observed consumption", value: q.observationsInRange > 0 ? "≈" + Display.percent(q.observedPercent) : "—", detail: q.latest?.minutes == 10080 ? "≈\((q.observedPercent / 100).formatted(.number.precision(.fractionLength(0...2)))) weekly allowances" : "Across observed windows")
                        MetricCard(title: "Latest window used", value: q.latest.map { Display.percent($0.used) } ?? "—", detail: q.latest.map { "As of " + Display.date($0.date) } ?? "No observations")
                        MetricCard(title: "Resets observed", value: "\(q.resets.count)", detail: "Inferred from window changes")
                    }
                    Panel(title: "Quota timeline") {
                        let cycles = q.cycles.filter { $0.last.date >= s.start }
                        if cycles.isEmpty { Text("No quota observations in this period").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180) }
                        else {
                            Chart {
                                ForEach(cycles) { cycle in
                                    ForEach(Array(cycle.samples.enumerated()).filter { $0.element.date >= s.start }, id: \.offset) { point in
                                        LineMark(x: .value("Time", point.element.date), y: .value("Used %", point.element.used), series: .value("Window", cycle.id)).foregroundStyle(.indigo)
                                    }
                                }
                                ForEach(q.resets) { cycle in
                                    RuleMark(x: .value("Reset", cycle.first.date)).foregroundStyle(.teal.opacity(0.6)).lineStyle(StrokeStyle(dash: [4, 4]))
                                }
                            }.chartYScale(domain: 0...100).chartYAxis { AxisMarks(position: .leading) }.frame(height: 220)
                        }
                        Text("Account snapshots across all chats and projects. Dashed lines mark inferred resets.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let latest = q.latest {
                        HStack {
                            Label("Expected reset", systemImage: "calendar.badge.clock").foregroundStyle(.secondary)
                            Text(Display.date(latest.resetsAt)).monospacedDigit()
                            Spacer()
                            Text("\(latest.minutes / 60) hour window").foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                    Panel(title: "Window history") {
                        ForEach(q.cycles.filter { $0.last.date >= s.start }) { cycle in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cycle.resetKind).font(.callout.weight(.medium))
                                    Text(Display.date(cycle.first.date) + " → " + Display.date(cycle.last.date)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(Display.percent(cycle.first.used)) → \(Display.percent(cycle.peak))").monospacedDigit()
                            }
                            if cycle.id != q.cycles.last?.id { Divider() }
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                        Text("Integer snapshots give an estimate, not a billing ledger. \(q.missingBaseline ? "The first window has no earlier baseline; its unseen usage is excluded. " : "")\(Display.percent(q.unattributed)) could not be linked to one local chat. Account or plan changes can split the history; a reset type does not prove a manual reset.")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            } else { EmptyActivityView() }
        }
    }
}
