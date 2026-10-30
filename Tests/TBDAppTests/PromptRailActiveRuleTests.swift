import CoreGraphics
import Testing
@testable import TBDApp

@Suite("PromptRailActiveRule")
struct PromptRailActiveRuleTests {
    private func viewport(_ minY: CGFloat, document: CGFloat = 10_000) -> PromptRailActiveRule.Viewport {
        .init(minY: minY, height: 500, documentHeight: document)
    }

    @Test func lastEntryAboveProbe() {
        let index = PromptRailActiveRule.activeIndex(
            count: 100, rowTop: { CGFloat($0) * 100 }, viewport: viewport(1000), heldIndex: nil)
        #expect(index == 11)
    }

    @Test func bottomSlackPicksLast() {
        let index = PromptRailActiveRule.activeIndex(
            count: 50, rowTop: { CGFloat($0) * 100 }, viewport: viewport(4492, document: 5000), heldIndex: nil)
        #expect(index == 49)
    }

    @Test func noneAboveProbePicksFirst() {
        let index = PromptRailActiveRule.activeIndex(
            count: 100, rowTop: { 2000 + CGFloat($0) * 100 }, viewport: viewport(0), heldIndex: nil)
        #expect(index == 0)
    }

    @Test func heldIndexWins() {
        let top: (Int) -> CGFloat = { CGFloat($0) * 100 }
        #expect(PromptRailActiveRule.activeIndex(
            count: 100, rowTop: top, viewport: viewport(1000), heldIndex: 3) == 3)
        #expect(PromptRailActiveRule.activeIndex(
            count: 100, rowTop: top, viewport: viewport(1000), heldIndex: 99) == 99)
        #expect(PromptRailActiveRule.activeIndex(
            count: 100, rowTop: top, viewport: viewport(1000), heldIndex: 100) == 11)
    }

    @Test func emptyIsNil() {
        #expect(PromptRailActiveRule.activeIndex(
            count: 0, rowTop: { _ in 0 }, viewport: viewport(0), heldIndex: nil) == nil)
    }

    @Test func binarySearchCallsRowTopLogarithmically() {
        var calls = 0
        let index = PromptRailActiveRule.activeIndex(
            count: 200,
            rowTop: { calls += 1; return CGFloat($0) * 100 },
            viewport: viewport(5000, document: 20_000),
            heldIndex: nil)
        #expect(index == 51)
        #expect(calls <= 10)
    }
}
