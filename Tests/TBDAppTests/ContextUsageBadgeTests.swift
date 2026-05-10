import Foundation
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
}
