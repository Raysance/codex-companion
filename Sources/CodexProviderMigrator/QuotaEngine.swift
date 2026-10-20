import Foundation

enum QuotaEngine {
    static func analyze(_ snapshots: [QuotaSnapshot], requests: [UsageRequest], start: Date, end: Date) -> QuotaAnalysis {
        var result = QuotaAnalysis()
        // Small reset timestamp differences and stale responses from concurrent chats are not new resets.
        let sorted = Set(snapshots.filter { $0.date <= end }).sorted {
            if $0.date == $1.date { return $0.resetsAt == $1.resetsAt ? $0.used < $1.used : $0.resetsAt < $1.resetsAt }
            return $0.date < $1.date
        }
        for s in sorted {
            guard let last = result.cycles.last else {
                result.cycles.append(QuotaCycle(id: 0, samples: [s], resetKind: "First observation")); continue
            }
            let drift = s.resetsAt.timeIntervalSince(last.first.resetsAt)
            if abs(drift) <= 120 {
                result.cycles[result.cycles.count - 1].samples.append(s)
            } else if drift > 120 {
                let kind: String
                if s.date >= last.first.resetsAt.addingTimeInterval(-120) { kind = "Scheduled reset · inferred" }
                else if s.used < last.peak { kind = "Early reset · inferred" }
                else { kind = "Window changed" }
                result.cycles.append(QuotaCycle(id: result.cycles.count, samples: [s], resetKind: kind))
            }
            // Older windows arriving after a reset are stale; do not start another cycle.
        }
        result.latest = result.cycles.last?.last
        for cycle in result.cycles {
            let points = cycle.samples
            let inside = points.filter { $0.date >= start && $0.date <= end }
            guard !inside.isEmpty else { continue }
            result.observationsInRange += inside.count
            let prior = points.filter { $0.date < start }
            let knownReset = cycle.id > 0 && cycle.resetKind.contains("reset")
            let baseline: Double
            if !prior.isEmpty { baseline = prior.map(\.used).max() ?? 0 }
            else if knownReset || cycle.first.used == 0 { baseline = 0 }
            else { baseline = cycle.first.used; result.missingBaseline = true }
            let consumed = max(0, (inside.map(\.used).max() ?? baseline) - baseline)
            result.observedPercent += consumed
            if knownReset && cycle.first.date >= start { result.resets.append(cycle) }

            // Only offer attribution when a complete observed increment has activity from one local chat.
            // The account may still have other devices: these figures remain estimates.
            var high = baseline
            var previous = prior.last?.date ?? cycle.first.date
            for point in inside {
                let increase = max(0, point.used - high)
                guard increase > 0 else { continue }
                if previous >= start {
                    let active = requests.filter { $0.date > previous && $0.date <= point.date }
                    let threads = Set(active.map(\.threadID)), turns = Set(active.map(\.turnID))
                    if threads.count == 1, let thread = threads.first { result.byThread[thread, default: 0] += increase }
                    if turns.count == 1, let turn = turns.first, !turn.isEmpty { result.byTurn[turn, default: 0] += increase }
                }
                high = max(high, point.used); previous = point.date
            }
        }
        result.unattributed = max(0, result.observedPercent - result.byThread.values.reduce(0, +))
        return result
    }
}
