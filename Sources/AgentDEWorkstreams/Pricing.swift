import AgentDEKit
import WorkstreamKit

/// List prices per million tokens, for Stats' cost estimate when Claude's own figure (from the status line)
/// isn't available. Cache writes cost 1.25× input (5-minute) and 2× input (1-hour). From Anthropic's pricing
/// as of October 2026; an unknown model is priced like the current Opus.
enum Pricing {
    struct Rates: Equatable {
        var input: Double
        var output: Double
        var cacheRead: Double
    }

    /// Longest matching prefix wins.
    static let table: [(prefix: String, rates: Rates)] = [
        ("claude-fable-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rates(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Rates(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Rates(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-8", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-7", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-6", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-5", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4", Rates(input: 15, output: 75, cacheRead: 1.5)),
        ("claude-sonnet-5-5", Rates(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", Rates(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", Rates(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-5-5", Rates(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4-5", Rates(input: 1, output: 5, cacheRead: 0.1)),
        ("claude-3-5-haiku", Rates(input: 0.8, output: 4, cacheRead: 0.08)),
    ]

    static func rates(for model: String) -> Rates {
        table.filter { model.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.rates
            ?? Rates(input: 4, output: 20, cacheRead: 0.20)
    }

    /// The estimated cost in dollars of this usage on `model`.
    static func cost(_ usage: TranscriptFacts.Usage, model: String) -> Double {
        let r = rates(for: model)
        let million = 1_000_000.0
        return (Double(usage.input) * r.input + Double(usage.output) * r.output + Double(usage.cacheRead) * r.cacheRead
                + Double(usage.cacheWrite5m) * r.input * 1.25 + Double(usage.cacheWrite1h) * r.input * 2) / million
    }

    static func cost(_ facts: TranscriptFacts) -> Double {
        facts.usage.reduce(0) { $0 + cost($1.value, model: $1.key) }
    }
}
