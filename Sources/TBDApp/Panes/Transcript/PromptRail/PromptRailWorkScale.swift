import CoreGraphics
import Foundation

/// How long each prompt rail notch is, and each card dash with it: its turn's
/// work (`PromptOutline.workCounts`) on a log scale against the session's
/// busiest turn. A turn with no tool calls is `minLength` long and the busiest
/// turn so far `maxLength`, so the rail always spans the whole range; a busier
/// turn arriving raises `busiest`, which rescales every other notch.
struct PromptRailWorkScale: Equatable {
    static let minLength: CGFloat = 4
    static let maxLength: CGFloat = 16

    /// Each entry's work, parallel to the entries it was delivered with.
    let counts: [Int]
    /// The busiest turn's work, and at least 1, so a session that has done no
    /// work at all draws every notch at `minLength` instead of dividing by
    /// log 1.
    let busiest: Int

    init(counts: [Int]) {
        self.counts = counts
        busiest = max(1, counts.max() ?? 0)
    }

    /// `minLength + (maxLength − minLength) × log(1 + n) / log(1 + busiest)`,
    /// with `n` held to `0...busiest` and `busiest` to at least 1.
    static func length(work: Int, busiest: Int) -> CGFloat {
        let ceiling = max(1, busiest)
        let n = min(max(0, work), ceiling)
        let fraction = log1p(Double(n)) / log1p(Double(ceiling))
        return minLength + (maxLength - minLength) * CGFloat(fraction)
    }

    /// Entry `index`'s work; 0 past the end of `counts`. The counts arrive
    /// just after the entries they describe, so for that moment a presenter
    /// can hold more entries than counts.
    func count(at index: Int) -> Int {
        counts.indices.contains(index) ? counts[index] : 0
    }

    /// Entry `index`'s notch length.
    func length(at index: Int) -> CGFloat {
        Self.length(work: count(at: index), busiest: busiest)
    }
}
