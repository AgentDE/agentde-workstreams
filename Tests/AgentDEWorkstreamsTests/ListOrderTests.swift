import Foundation
import Testing
@testable import AgentDEWorkstreams

@Suite("Files and Artifacts order")
struct ListOrderTests {
    let now = Date()
    var items: [ListItem] {
        [ListItem(key: "/r/deck.pptx", name: "deck.pptx", date: now.addingTimeInterval(-60), count: 2, size: 900),
         ListItem(key: "/r/notes.md", name: "notes.md", date: now, count: 1, size: 10),
         ListItem(key: "/r/app/main.swift", name: "main.swift", date: now.addingTimeInterval(-3600), count: 9, size: 400),
         ListItem(key: "https://example.com/report", name: "Report", date: now.addingTimeInterval(-30), count: 1, size: nil)]
    }

    /// Most opened goes by your opens; Mix by opens, then use, then recency.
    @Test func openedAndMix() {
        var list = items
        list[1].opened = 3   // notes.md
        list[0].opened = 3   // deck.pptx, used more
        list[3].opened = 1   // Report
        #expect(ListOrder.arrange(list, sort: .opened, filter: "").map(\.name) == ["notes.md", "deck.pptx", "Report", "main.swift"])
        #expect(ListOrder.arrange(list, sort: .mix, filter: "").map(\.name) == ["deck.pptx", "notes.md", "Report", "main.swift"])
    }

    @Test func sorts() {
        #expect(ListOrder.arrange(items, sort: .recent, filter: "").map(\.name) == ["notes.md", "Report", "deck.pptx", "main.swift"])
        #expect(ListOrder.arrange(items, sort: .used, filter: "").map(\.name) == ["main.swift", "deck.pptx", "notes.md", "Report"])
        #expect(ListOrder.arrange(items, sort: .biggest, filter: "").map(\.name) == ["deck.pptx", "main.swift", "notes.md", "Report"])
        #expect(ListOrder.arrange(items, sort: .name, filter: "").map(\.name) == ["deck.pptx", "main.swift", "notes.md", "Report"])
    }

    /// Every word must match the name or the path; an extension works as a type filter.
    @Test func filters() {
        #expect(ListOrder.arrange(items, sort: .recent, filter: ".pptx").map(\.name) == ["deck.pptx"])
        #expect(ListOrder.arrange(items, sort: .recent, filter: "app swift").map(\.name) == ["main.swift"])
        #expect(ListOrder.arrange(items, sort: .recent, filter: "EXAMPLE").map(\.name) == ["Report"])
        #expect(ListOrder.arrange(items, sort: .recent, filter: "zzz").isEmpty)
    }

    /// Hidden items drop out of the list, and a filter that matches them brings them back.
    @Test func hiddenShowOnlyWhenFiltered() {
        var list = items
        list[0].hidden = true   // deck.pptx
        #expect(ListOrder.arrange(list, sort: .recent, filter: "").map(\.name) == ["notes.md", "Report", "main.swift"])
        #expect(ListOrder.arrange(list, sort: .recent, filter: "deck").map(\.name) == ["deck.pptx"])
        #expect(ListOrder.arrange(list, sort: .recent, filter: "/r/").map(\.name) == ["notes.md", "deck.pptx", "main.swift"])
    }
}
