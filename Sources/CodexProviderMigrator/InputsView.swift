import Charts
import SwiftUI

struct InputsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var search = ""
    var body: some View {
        ScrollView {
            if let s = model.slice {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        MetricCard(title: "Inputs", value: "\(s.prompts.count)", detail: "Human text messages")
                        MetricCard(title: "Characters", value: Display.number(Int64(s.characters)), detail: "Includes spaces and punctuation")
                        MetricCard(title: "Average length", value: s.prompts.isEmpty ? "0" : "\(s.characters / s.prompts.count)", detail: "Characters per input")
                        MetricCard(title: "Words", value: Display.number(Int64(s.wordCount)), detail: "Language-aware segmentation")
                    }
                    Panel(title: "Word cloud") {
                        if s.terms.isEmpty { Text("No words in this period").foregroundStyle(.secondary) }
                        else {
                            WordFlow(spacing: 14) {
                                ForEach(Array(s.terms.prefix(45).enumerated()), id: \.element.id) { index, term in
                                    let scale = Double(term.count) / Double(s.terms.first?.count ?? 1)
                                    Text(term.text).font(.system(size: 14 + 22 * sqrt(scale), weight: scale > 0.4 ? .semibold : .medium))
                                        .foregroundStyle(index % 3 == 0 ? Color.teal : Color.indigo.opacity(0.55 + 0.45 * scale))
                                        .help("\(term.count) occurrences · \(term.documents) inputs")
                                        .accessibilityLabel("\(term.text), \(term.count) occurrences")
                                }
                            }.padding(.vertical, 10)
                        }
                    }
                    HStack(alignment: .top, spacing: 18) {
                        Panel(title: "Word frequency") {
                            HStack { Text("Term"); Spacer(); Text("Count / inputs") }.font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(s.terms.prefix(12))) { term in
                                HStack { Text(term.text); Spacer(); Text("\(term.count) / \(term.documents)").monospacedDigit() }
                            }
                        }
                        Panel(title: "Daily input volume") {
                            Chart(s.daily) { day in
                                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Characters", day.characters)).foregroundStyle(.teal.opacity(0.75))
                            }.chartYAxis { AxisMarks(position: .leading) }.frame(height: 260)
                        }
                    }
                    Panel(title: "Input history") {
                        TextField("Search your inputs", text: $search).textFieldStyle(.roundedBorder)
                        let matching = s.prompts.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(matching.prefix(200))) { p in
                                DisclosureGroup {
                                    Text(p.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.top, 8)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(p.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                                        Text("\(Display.date(p.date)) · \(p.characters) characters · \(model.report.title(p.threadID))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Divider()
                            }
                        }
                        if matching.count > 200 { Text("Showing 200 of \(matching.count) inputs. Narrow the period or search.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Context attachments and agent prompts are excluded. Common stopwords are removed from frequencies; characters are not prompt-token counts.").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            } else { EmptyActivityView() }
        }
    }
}

/// A real wrapping layout: word sizes encode frequency without clipping at narrow window widths.
struct WordFlow: Layout {
    var spacing: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 600, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += height + spacing; height = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; height = max(height, size.height)
        }
        return (CGSize(width: width, height: y + height), points)
    }
}
