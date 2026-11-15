import AgentDEKit
import SwiftUI
import WorkstreamKit

/// Claude's 5-hour and 7-day limits used, in the status bar. They come from the status-line feed
/// (`StatusLineFeed`), so they show once the status line is registered (`scripts/register-workstream.sh`).
struct RateLimitsItem: View {
    let model: WorkstreamsModel
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let limits = model.rateLimits(now: context.date)
            HStack(spacing: 8) {
                if let five = limits?.fiveHourUsedPercent { figure("5h", five) }
                if let seven = limits?.sevenDayUsedPercent { figure("7d", seven) }
            }
        }
    }

    private func figure(_ label: String, _ used: Double) -> some View {
        Text("\(label) \(Int(used.rounded()))%")
            .foregroundStyle(used > 85 ? Theme.needsYou : theme.muted)
            .help("Claude's \(label == "5h" ? "5-hour" : "7-day") limit used")
    }
}
