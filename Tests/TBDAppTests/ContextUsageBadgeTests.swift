import Foundation
import SwiftUI
import Testing

@testable import TBDApp

@Suite("ContextUsageBadge")
struct ContextUsageBadgeTests {
    @Test func formatted_floor_thousands_with_tokens_suffix() {
        #expect(ContextUsageBadge.formatted(0) == "0k tokens")
        #expect(ContextUsageBadge.formatted(999) == "0k tokens")
        #expect(ContextUsageBadge.formatted(124_300) == "124k tokens")
        #expect(ContextUsageBadge.formatted(1_500_000) == "1500k tokens")
    }

    @Test func color_thresholds() {
        #expect(ContextUsageBadge.color(for: 0) == .secondary)
        #expect(ContextUsageBadge.color(for: 189_999) == .secondary)
        #expect(ContextUsageBadge.color(for: 190_000) == .yellow)
        #expect(ContextUsageBadge.color(for: 259_999) == .yellow)
        #expect(ContextUsageBadge.color(for: 260_000) == .orange)
        #expect(ContextUsageBadge.color(for: 299_999) == .orange)
        #expect(ContextUsageBadge.color(for: 300_000) == .red)
    }
}
