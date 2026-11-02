import Foundation
import Testing
@testable import AgentDEWorkstreams
@testable import WorkstreamKit

@Suite("Overlap notes")
struct OverlapNoteTests {
    @Test func overlapsGroupByPairWhicheverWayRound() {
        let now = Date()
        let groups = WorkstreamsModel.overlapsByPair([
            .init(path: "/p/b.swift", first: "T1", second: "T2", at: now),
            .init(path: "/p/a.swift", first: "T2", second: "T1", at: now),
            .init(path: "/p/a.swift", first: "T1", second: "T2", at: now),
            .init(path: "/p/c.swift", first: "T1", second: "T3", at: now),
        ])
        #expect(groups.map { "\($0.pair.first)+\($0.pair.second)" } == ["T1+T2", "T1+T3"])
        #expect(groups.first?.paths == ["/p/a.swift", "/p/b.swift"])
    }

    @Test func oneNoteNamesSeveralFiles() {
        #expect(WorkstreamsModel.overlapText(["x.py"], "A", "B") == "x.py is being edited by both A and B")
        #expect(WorkstreamsModel.overlapText(["x.py"], nil, "B") == "x.py is also being edited by B")
        let six = ["a", "b", "c", "d", "e", "f"]
        #expect(WorkstreamsModel.overlapText(six, "A", "B") == "6 files are being edited by both A and B: a, b, c, d and 2 more")
        #expect(WorkstreamsModel.overlapText(Array(six.prefix(2)), nil, "B") == "2 files are also being edited by B: a, b")
    }

    @Test func aRewrittenNoteKeepsItsPlace() {
        var w = Workstream(id: "w")
        w.replaceNote(.init(id: "ov-1", text: "x is being edited by both A and B", at: Date(), by: "app"))
        w.addNote(.init(id: "f2", text: "other", at: Date()))
        w.replaceNote(.init(id: "ov-1", text: "2 files are being edited by both A and B: x, y", at: Date(), by: "app"))
        #expect(w.fyi?.items.map(\.id) == ["ov-1", "f2"])
        #expect(w.fyi?.items.first?.text.hasPrefix("2 files") == true)
    }
}
