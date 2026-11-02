import Foundation
import Testing
@testable import AgentDEWorkstreams
@testable import WorkstreamKit

@Suite("Stats")
struct StatsTests {
    @Test func pricesUsage() {
        var usage = TranscriptFacts.Usage()
        usage.input = 1_000_000
        usage.output = 1_000_000
        #expect(abs(Pricing.cost(usage, model: "claude-opus-5-5") - 24) < 1e-9)
        usage = TranscriptFacts.Usage()
        usage.cacheRead = 1_000_000
        usage.cacheWrite5m = 1_000_000
        usage.cacheWrite1h = 1_000_000
        // Sonnet 5.5: reads $0.20, 5-minute writes 1.25 × $2, 1-hour writes 2 × $2.
        #expect(abs(Pricing.cost(usage, model: "claude-sonnet-5-5") - (0.20 + 2.5 + 4)) < 1e-9)
        #expect(Pricing.rates(for: "claude-opus-4-1-20250805").input == 15)
        #expect(Pricing.rates(for: "claude-opus-4-8").input == 5)
        #expect(Stat.tokens(2_100_000_000) == "2.1B" && Stat.tokens(54_500_000) == "54.5M" && Stat.tokens(950) == "950")
        #expect(Stat.duration(913_500) == "10d 13h")
    }

    @Test func notesExpireAndKeepTheirIDs() {
        var workstream = Workstream(id: "W")
        let now = Date()
        let added = workstream.addNote(.init(id: "ov-1", text: "x.py is also being edited by B", at: now, by: "app", expires: now.addingTimeInterval(60)))
        let again = workstream.addNote(.init(id: "ov-1", text: "again", at: now, by: "app"))
        #expect(added && !again)
        workstream.addFYI("from an agent", agent: "S", at: now)
        let early = workstream.removeExpiredNotes(now: now)
        let late = workstream.removeExpiredNotes(now: now.addingTimeInterval(61))
        #expect(!early && late)
        #expect(workstream.fyi?.items.map(\.text) == ["from an agent"])
    }
}
