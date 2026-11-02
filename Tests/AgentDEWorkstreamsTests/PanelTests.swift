import Foundation
import Testing
@testable import AgentDEWorkstreams

@Suite("Workstream panel")
struct PanelTests {
    @Test func shortTimes() {
        let now = Date()
        #expect(PanelSectionTime.short(now.addingTimeInterval(-20), now: now) == "now")
        #expect(PanelSectionTime.short(now.addingTimeInterval(-180), now: now) == "3m")
        #expect(PanelSectionTime.short(now.addingTimeInterval(-7_300), now: now) == "2h")
        #expect(PanelSectionTime.short(now.addingTimeInterval(-4 * 86_400), now: now) == "4d")
    }
}
