import CoreGraphics
import Foundation
import Testing
@testable import TBDApp

/// The open lens's motion (lens spec, "Steady motion"): 40 prompts in a 601pt
/// rail, opened with the pointer on notch 20, and frames stepped by hand.
/// Tier 1: pure values, no clock.
@Suite("PromptRailSteadyLens")
struct PromptRailSteadyLensTests {
    private static let geometry = PromptRailLensGeometry(
        layout: PromptRailLayout(count: 40, railHeight: 601), restOffset: 0)
    private static let frame = 1.0 / 60

    /// A notch's resting centre in rail coordinates.
    private static func restingCentre(of notch: Int) -> CGFloat {
        PromptRailLayout.topInset + (CGFloat(notch) + 0.5) * geometry.restPitch
    }

    private static func opened() -> PromptRailSteadyLens {
        PromptRailSteadyLens(geometry: geometry, pointerY: restingCentre(of: 20))
    }

    @Test func opensOnThePointedNotch() {
        let lens = Self.opened()
        #expect(lens.rows.index(atY: Self.restingCentre(of: 20)) == 20)
        #expect(lens.rows == Self.geometry.rows(centre: lens.centre, anchor: lens.anchor))
    }

    /// Two rows from the centre is inside the 2.7-row dead zone.
    @Test func holdsInDeadZone() {
        var lens = Self.opened()
        let start = lens.centre
        let pointer = lens.rows.y(ofFraction: start + 2)
        var moves = 0
        for _ in 0..<60 {
            if lens.step(pointerY: pointer, dt: Self.frame) { moves += 1 }
        }
        #expect(moves == 0)
        #expect(lens.centre == start, "the centre moved from \(start) to \(lens.centre)")
    }

    /// Pushed to row 30, the lens follows without going back, until the
    /// pointer sits on the dead zone's edge.
    @Test func followsPastDeadZone() {
        var lens = Self.opened()
        let start = lens.centre
        let pointer = lens.rows.y(ofFraction: 30.5)
        var previous = start
        var backwards: [String] = []
        for frame in 0..<60 {
            _ = lens.step(pointerY: pointer, dt: Self.frame)
            if lens.centre < previous { backwards.append("frame \(frame): \(previous) → \(lens.centre)") }
            previous = lens.centre
        }
        #expect(backwards.isEmpty, "the centre went back: \(backwards.prefix(5))")
        #expect(lens.centre > start + 1, "the lens stayed at \(lens.centre)")
        let gap = abs(lens.rows.fraction(atY: pointer) - lens.centre)
        #expect(gap <= 2.7 + 0.05, "the pointer ended \(gap) rows from the centre")
    }

    /// The same move at 60Hz and at 120Hz leaves the centre in the same place
    /// after the same time. The pointer first rests just inside the dead zone,
    /// then moves 15pt past its edge in one frame, slowly enough at either
    /// rate that it is no flick, so the time-based ease alone moves the lens.
    @Test func frameRateIndependent() {
        func move(hz: Int) -> (start: CGFloat, end: CGFloat) {
            var lens = Self.opened()
            let dt = 1.0 / Double(hz)
            let inside = lens.rows.y(ofFraction: lens.centre + 2.6)
            for _ in 0..<(hz / 2) { _ = lens.step(pointerY: inside, dt: dt) }
            let start = lens.centre
            for _ in 0..<(hz / 2) { _ = lens.step(pointerY: inside + 15, dt: dt) }
            return (start, lens.centre)
        }
        let at60 = move(hz: 60)
        let at120 = move(hz: 120)
        #expect(at60.end - at60.start > 1, "at 60Hz the lens moved only \(at60.start) → \(at60.end)")
        #expect(at120.end - at120.start > 1, "at 120Hz the lens moved only \(at120.start) → \(at120.end)")
        #expect(abs(at60.end - at120.end) <= 0.01, "60Hz ended at \(at60.end), 120Hz at \(at120.end)")
    }

    /// The speed smoothing is time-based: a pointer moving a steady
    /// 0.12pt/ms reads the same smoothed speed after 0.25s at either rate,
    /// `0.12 × (1 − 0.6^15)`.
    @Test func speedSmoothingIsTimeBased() {
        func speedAfterSweep(hz: Int) -> CGFloat {
            var lens = Self.opened()
            var pointer = Self.restingCentre(of: 20)
            let dt = 1.0 / Double(hz)
            for _ in 0..<(hz / 4) {
                pointer += 0.12 * CGFloat(dt) * 1000
                _ = lens.step(pointerY: pointer, dt: dt)
            }
            return lens.speed
        }
        let at60 = speedAfterSweep(hz: 60)
        let at120 = speedAfterSweep(hz: 120)
        let kept: Double = pow(0.6, 15)
        let expected = 0.12 * (1 - CGFloat(kept))
        #expect(abs(at60 - at120) <= 1e-9, "60Hz read \(at60), 120Hz \(at120)")
        #expect(abs(at60 - expected) <= 1e-9, "the smoothed speed is \(at60), not \(expected)")
    }

    /// A 200pt jump in one frame is a flick: the lens holds still, and
    /// follows once the smoothed speed falls.
    @Test func flickFreezes() {
        var lens = Self.opened()
        let start = lens.centre
        let far = Self.restingCentre(of: 20) + 200
        let moved = lens.step(pointerY: far, dt: Self.frame)
        #expect(!moved)
        #expect(lens.centre == start, "the centre moved from \(start) to \(lens.centre)")
        #expect(lens.speed > PromptRailSteadyLens.flickSpeed)

        var frames = 0
        while frames < 10, !lens.step(pointerY: far, dt: Self.frame) { frames += 1 }
        #expect(frames < 10, "the lens never followed once the flick ended")
    }

    /// Once the pointer stops, the lens stops within 60 frames and stays put.
    @Test func settles() throws {
        var lens = Self.opened()
        let pointer = lens.rows.y(ofFraction: 30.5)
        var frozen = 0
        while frozen < 10, !lens.step(pointerY: pointer, dt: Self.frame) { frozen += 1 }
        try #require(frozen < 10, "the lens never started following")

        var moving = 0
        while moving < 60, lens.step(pointerY: pointer, dt: Self.frame) { moving += 1 }
        #expect(moving < 60, "the lens still moved 60 frames after the pointer stopped")
        let settled = lens.centre
        var movedAgain = false
        for _ in 0..<10 { movedAgain = lens.step(pointerY: pointer, dt: Self.frame) || movedAgain }
        #expect(!movedAgain)
        #expect(lens.centre == settled)
    }

    /// After a pause the lens resumes tracking where the pointer is, at rest:
    /// a 150pt move made while it was not stepping is no flick, and the first
    /// step follows the pointer. Without the resume, the same step reads the
    /// whole move as one frame's motion and freezes.
    @Test func resumedTrackingIsNoFlick() {
        var lens = Self.opened()
        let start = lens.centre
        let far = Self.restingCentre(of: 20) + 150

        var stale = lens
        let staleMoved = stale.step(pointerY: far, dt: Self.frame)
        #expect(!staleMoved, "precondition: an unresumed step reads a flick")
        #expect(stale.speed > PromptRailSteadyLens.flickSpeed)

        lens.resumeTracking(pointerY: far)
        #expect(lens.speed == 0)
        let moved = lens.step(pointerY: far, dt: Self.frame)
        #expect(moved, "the first step after resuming froze")
        #expect(lens.centre > start + 1, "the lens moved only from \(start) to \(lens.centre)")
        #expect(lens.speed <= PromptRailSteadyLens.flickSpeed)
    }

    /// A lens moved away from the anchor it opened with, on a windowed rail,
    /// keeps its centre where it is drawn when the outline grows or shrinks
    /// by one, or the rail's height changes: the rebase re-anchors on the
    /// centre's drawn height, not its resting one. 200 prompts window a 600pt
    /// rail at a 200pt offset; the lens opens on row 150 and is drawn up the
    /// rail to about row 74, which re-anchoring on the resting height would
    /// move some 43pt.
    @Test func rebaseKeepsCentreWhereDrawn() throws {
        func windowed(_ count: Int, railHeight: CGFloat = 600) -> PromptRailLensGeometry {
            PromptRailLensGeometry(layout: PromptRailLayout(count: count, railHeight: railHeight), restOffset: 200)
        }
        let geometry = windowed(200)
        try #require(geometry.restOverflows && !geometry.keepsRestingRows,
                     "precondition: 200 prompts window a 600pt rail and squeeze")
        var pointer = PromptRailLayout.topInset + 150.5 * geometry.restPitch - geometry.restOffset
        var lens = PromptRailSteadyLens(geometry: geometry, pointerY: pointer)
        let opened = lens.centre
        // The pointer is drawn up the rail at 2pt a frame, then held until
        // the lens settles.
        while pointer > 150 {
            pointer = max(150, pointer - 2)
            _ = lens.step(pointerY: pointer, dt: Self.frame)
        }
        var frames = 0
        while frames < 600, lens.step(pointerY: pointer, dt: Self.frame) { frames += 1 }
        try #require(lens.centre < opened - 20, "precondition: the lens moved only from \(opened) to \(lens.centre)")
        let drawn = lens.rows.y(ofFraction: lens.centre)

        for (label, next) in [("201 prompts", windowed(201)), ("199 prompts", windowed(199)),
                              ("a 500pt rail", windowed(200, railHeight: 500))] {
            let rebased = lens.rebased(to: next)
            #expect(abs(rebased.centre - lens.centre) <= 1e-9, "\(label): the centre moved from \(lens.centre)")
            let now = rebased.rows.y(ofFraction: rebased.centre)
            #expect(abs(now - drawn) <= 1, "\(label): the centre moved from \(drawn)pt to \(now)pt")
        }
    }

    /// A rail that keeps its resting rows never moves (spec step 0), so `step`
    /// reports no movement and the caller can stop stepping: 5 prompts, with
    /// the pointer drawn steadily from notch 0 to notch 4, then held.
    @Test func restingRailNeverSteps() {
        let five = PromptRailLensGeometry(layout: PromptRailLayout(count: 5, railHeight: 601), restOffset: 0)
        #expect(five.keepsRestingRows)
        let top = PromptRailLayout.topInset
        var pointer = top + 0.5 * five.restPitch
        var lens = PromptRailSteadyLens(geometry: five, pointerY: pointer)
        let start = lens.centre
        let target = top + 4.5 * five.restPitch
        var moves = 0
        while pointer < target {
            pointer = min(target, pointer + 2)
            if lens.step(pointerY: pointer, dt: Self.frame) { moves += 1 }
        }
        #expect(lens.speed > 0.05, "the lens stopped tracking the pointer's speed: \(lens.speed)")
        for _ in 0..<60 {
            if lens.step(pointerY: pointer, dt: Self.frame) { moves += 1 }
        }
        #expect(moves == 0)
        #expect(lens.centre == start, "the centre moved from \(start) to \(lens.centre)")
        #expect(lens.rows == PromptRailLensRows.resting(five))
    }

    /// A shorter outline holds the centre to its count; a longer one keeps it.
    @Test func rebasedClampsCentre() throws {
        let lens = PromptRailSteadyLens(geometry: Self.geometry, pointerY: Self.restingCentre(of: 28))
        try #require(lens.centre > 25, "precondition: the lens opened on \(lens.centre)")

        let five = PromptRailLensGeometry(layout: PromptRailLayout(count: 5, railHeight: 601), restOffset: 0)
        let shrunk = lens.rebased(to: five)
        #expect(shrunk.centre <= 5, "the centre is \(shrunk.centre)")
        #expect(shrunk.rows.heights.count == 5)
        #expect(shrunk.geometry == five)

        let more = PromptRailLensGeometry(layout: PromptRailLayout(count: 41, railHeight: 601), restOffset: 0)
        let grown = lens.rebased(to: more)
        #expect(abs(grown.centre - lens.centre) <= 0.01, "the centre went from \(lens.centre) to \(grown.centre)")
        #expect(grown.rows.heights.count == 41)
    }
}
