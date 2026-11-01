import CoreGraphics
import Foundation
import Testing
@testable import TBDApp

// Tier 1: deterministic, in-process state only. Pure values; no view is drawn.

/// `SplitDivider.clampedOffset`: how far a drag may move a divider before a
/// pane beside it would go below its smallest share. With no minimums every
/// pane stops at `SplitDivider.defaultMinimumRatio`, which the legacy split
/// layouts rely on; the workspace view's side region passes a larger one for
/// itself, sized to its strip's fixed controls.
@Suite("Split divider clamp")
@MainActor
struct SplitDividerClampTests {
    /// `SplitDivider.clampedOffset` for the divider at `index`.
    private static func offset(
        _ translation: CGFloat, from start: [CGFloat], index: Int = 0, space: CGFloat,
        minimums: [CGFloat] = []
    ) -> CGFloat {
        SplitDivider.clampedOffset(
            translation: translation,
            startRatios: start,
            index: index,
            availableSpace: space,
            minimumRatios: minimums)
    }

    @Test("with no minimums both panes stop at the default floor, and a drag inside the range moves freely")
    func noMinimumsStopAtTheDefaultFloor() {
        #expect(SplitDivider.defaultMinimumRatio == 0.1)

        let start: [CGFloat] = [0.5, 0.5]
        let forwardLimit: CGFloat = (0.5 - 0.1) * 1000
        let backwardLimit: CGFloat = -(0.5 - 0.1) * 1000
        #expect(Self.offset(1000, from: start, space: 1000) == forwardLimit)
        #expect(Self.offset(-1000, from: start, space: 1000) == backwardLimit)
        #expect(Self.offset(120, from: start, space: 1000) == 120)
        #expect(Self.offset(-120, from: start, space: 1000) == -120)

        // The divider between the second and third of three panes.
        let three: [CGFloat] = [0.2, 0.3, 0.5]
        let threeForwardLimit: CGFloat = (0.5 - 0.1) * 1000
        let threeBackwardLimit: CGFloat = -(0.3 - 0.1) * 1000
        #expect(Self.offset(1000, from: three, index: 1, space: 1000) == threeForwardLimit)
        #expect(Self.offset(-1000, from: three, index: 1, space: 1000) == threeBackwardLimit)

        // A minimum below the default floor does not lower it.
        let belowFloor: [CGFloat] = [0.05, 0.05]
        #expect(Self.offset(1000, from: start, space: 1000, minimums: belowFloor) == forwardLimit)
        #expect(Self.offset(-1000, from: start, space: 1000, minimums: belowFloor) == backwardLimit)
    }

    @Test("a side minimum stops a drag that shrinks the side at that share, and the primary still stops at the floor")
    func sideMinimumStopsTheDrag() {
        let start: [CGFloat] = [0.5, 0.5]
        let minimums: [CGFloat] = [SplitDivider.defaultMinimumRatio, 0.15]
        let forwardLimit: CGFloat = (0.5 - 0.15) * 1400
        let backwardLimit: CGFloat = -(0.5 - 0.1) * 1400

        #expect(Self.offset(1000, from: start, space: 1400, minimums: minimums) == forwardLimit)
        #expect(Self.offset(-1000, from: start, space: 1400, minimums: minimums) == backwardLimit)
    }

    @Test("a pane that starts below its minimum is never shrunk further, and can still grow")
    func startBelowTheMinimumNeverShrinksFurther() {
        let start: [CGFloat] = [0.95, 0.05]
        let minimums: [CGFloat] = [SplitDivider.defaultMinimumRatio, 0.15]

        // Forward would shrink the side further, so the divider does not
        // move, and is not pushed the other way either.
        #expect(Self.offset(100, from: start, space: 1400, minimums: minimums) == 0)
        // Backward grows the side.
        #expect(Self.offset(-100, from: start, space: 1400, minimums: minimums) == -100)
    }

    @Test("no space to drag in, or a divider the ratios do not have, moves nothing")
    func nothingToDragMovesNothing() {
        let start: [CGFloat] = [0.5, 0.5]
        #expect(Self.offset(100, from: start, space: 0) == 0)
        #expect(Self.offset(100, from: start, index: 1, space: 1000) == 0)
    }
}
