import AgentDEKit
import AgentDEWidgets
import SwiftUI
import WorkstreamKit

/// Time in turns and estimated cost, per workstream, for today, the last 7 days, or all time: from the
/// transcripts of every agent attached to a workstream (`TranscriptFacts.days`).
enum UsagePeriod: String, CaseIterable {
    case today, week, all

    var name: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .all: "All"
        }
    }

    /// The day keys it covers, or nil for all time.
    func days(now: Date, calendar: Calendar = .current) -> Set<String>? {
        switch self {
        case .today: [TranscriptFacts.dayKey(now, calendar: calendar)]
        case .week: Set((0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map { TranscriptFacts.dayKey($0, calendar: calendar) })
        case .all: nil
        }
    }
}

struct UsageRow: Equatable {
    var id: String
    var name: String
    var seconds: Double
    var cost: Double
}

enum UsageSummary {
    /// One row per workstream with any activity in the period, most time first.
    static func rows(_ workstreams: [(id: String, name: String, facts: [TranscriptFacts])], period: UsagePeriod, now: Date,
                     calendar: Calendar = .current) -> [UsageRow] {
        let days = period.days(now: now, calendar: calendar)
        return workstreams.compactMap { workstream in
            var seconds = 0.0, cost = 0.0
            for facts in workstream.facts {
                if let days {
                    for (key, day) in facts.days where days.contains(key) {
                        seconds += day.activeSeconds
                        cost += day.usage.reduce(0) { $0 + Pricing.cost($1.value, model: $1.key) }
                    }
                } else {
                    seconds += facts.activeSeconds
                    cost += Pricing.cost(facts)
                }
            }
            guard seconds > 0 || cost >= 0.005 else { return nil }
            return UsageRow(id: workstream.id, name: workstream.name, seconds: seconds, cost: cost)
        }
        .sorted { ($0.seconds, $0.cost) > ($1.seconds, $1.cost) }
    }
}

struct UsageWidget: View {
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @AppStorage("usageWidgetPeriod") private var period = UsagePeriod.today

    var body: some View {
        let rows = UsageSummary.rows(store.workstreams.values.map { workstream in
            (workstream.id, store.workstreamName(workstream),
             workstream.agents.compactMap { agent in
                 store.workstreamSessionIndex[agent.session] == workstream.id ? store.transcriptFacts[agent.session] : nil
             })
        }, period: period, now: Date())
        let longest = rows.first?.seconds ?? 0
        WidgetCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(UsagePeriod.allCases, id: \.self) { option in
                        Button { period = option } label: {
                            Text(option.name).font(.system(size: 11, weight: option == period ? .semibold : .regular))
                                .foregroundStyle(option == period ? theme.text : theme.muted)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(option == period ? theme.selected : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                if rows.isEmpty {
                    Text(period == .today ? "No agent time yet today." : "No agent time in this period.")
                        .font(.system(size: 11.5)).foregroundStyle(theme.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Stat.duration(rows.reduce(0) { $0 + $1.seconds })).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(theme.text)
                        Text("in turns").font(.system(size: 11)).foregroundStyle(theme.muted)
                        Spacer(minLength: 4)
                        Text("≈ " + Stat.money(rows.reduce(0) { $0 + $1.cost })).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(theme.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(rows, id: \.id) { row in UsageRowView(row: row, longest: longest) }
                        }
                    }
                    .widgetListHeight(150)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .help("Time agents spent working, per workstream, and its estimated cost at list prices")
    }
}

private struct UsageRowView: View {
    let row: UsageRow
    let longest: Double
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { open() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(row.name).font(.system(size: 11.5)).foregroundStyle(hovering ? theme.text : theme.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Stat.duration(row.seconds)) · \(Stat.money(row.cost))").font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(theme.muted)
                }
                GeometryReader { geo in
                    Capsule().fill(theme.secondary.opacity(hovering ? 0.9 : 0.55))
                        .frame(width: max(3, geo.size.width * (longest > 0 ? row.seconds / longest : 0)))
                }
                .frame(height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Go to \(row.name)")
    }

    /// Selects the workstream's first agent tab.
    private func open() {
        guard let workstream = store.workstreams[row.id], let tab = store.agentTabs(of: workstream).first else { return }
        store.host.selectTab(tab.id, focus: true)
    }
}
