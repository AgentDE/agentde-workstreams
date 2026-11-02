import Foundation
import Testing
@testable import AgentDEWorkstreams
@testable import WorkstreamKit

@Suite("Usage widget")
struct UsageTests {
    @Test func rowsCoverTheirPeriodAndSkipIdleWorkstreams() {
        let day1 = ScheduleScanner.parseDate("2026-10-19T12:00:00.000Z")!, day2 = ScheduleScanner.parseDate("2026-10-20T12:00:00.000Z")!
        var facts = TranscriptFacts()
        for (day, seconds, output) in [(day1, 30.0, 100), (day2, 5.0, 7)] {
            var usage = TranscriptFacts.Usage()
            usage.output = output
            var record = TranscriptFacts.Day()
            record.activeSeconds = seconds
            record.usage = ["claude-opus-5-5": usage]
            facts.days[TranscriptFacts.dayKey(day)] = record
            facts.activeSeconds += seconds   // all time reads the totals
            facts.usage["claude-opus-5-5"] = (facts.usage["claude-opus-5-5"] ?? .init()) + usage
        }
        let rows = { (period: UsagePeriod) in UsageSummary.rows([("w1", "Logging", [facts]), ("w2", "Idle", [TranscriptFacts()])], period: period, now: day2) }
        #expect(rows(.today).map(\.seconds) == [5])
        #expect(rows(.week).first?.seconds == 35 && rows(.all).first?.seconds == 35)
        #expect(rows(.all).map(\.name) == ["Logging"])   // nothing for a workstream without activity
        #expect(rows(.week).first!.cost > rows(.today).first!.cost)
    }
}
