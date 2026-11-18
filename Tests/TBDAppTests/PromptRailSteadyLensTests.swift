import CoreGraphics
import Foundation
import Testing
@testable import TBDApp

/// The open lens's motion (lens spec, "Steady motion"): 40 prompts in a 601pt
/// rail, opened with the pointer on notch 20, the pointer's moves noted with
/// their times and frames stepped by hand. Tier 1: pure values, no clock.
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
        lens.notePointer(y: lens.rows.y(ofFraction: start + 2), time: 0)
        var moves = 0
        for _ in 0..<60 {
            if lens.step(dt: Self.frame) { moves += 1 }
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
        lens.notePointer(y: pointer, time: 0)
        var previous = start
        var backwards: [String] = []
        for frame in 0..<60 {
            _ = lens.step(dt: Self.frame)
            if lens.centre < previous { backwards.append("frame \(frame): \(previous) → \(lens.centre)") }
            previous = lens.centre
        }
        #expect(backwards.isEmpty, "the centre went back: \(backwards.prefix(5))")
        #expect(lens.centre > start + 1, "the lens stayed at \(lens.centre)")
        let gap = abs(lens.rows.fraction(atY: pointer) - lens.centre)
        #expect(gap <= 2.7 + 0.05, "the pointer ended \(gap) rows from the centre")
    }

    /// The same moves at 60Hz and at 120Hz leave the centre in the same place
    /// after the same time. The pointer rests just inside the dead zone, then
    /// moves 15pt past its edge in six moves 1/120s apart, slowly enough that
    /// it is no flick, so the time-based ease alone moves the lens. Time runs
    /// in ticks of 1/120s; the moves land on the ticks they land on at either
    /// rate, and each frame steps after the moves of its tick.
    @Test func frameRateIndependent() {
        func move(hz: Int) -> (start: CGFloat, end: CGFloat) {
            var lens = Self.opened()
            let start = lens.centre
            let inside = lens.rows.y(ofFraction: start + 2.6)
            let tick = 1.0 / 120
            let ticksPerFrame = 120 / hz
            lens.notePointer(y: inside, time: 0)
            for index in 1...120 {
                if (61...66).contains(index) {
                    lens.notePointer(y: inside + 2.5 * CGFloat(index - 60), time: Double(index) * tick)
                }
                if index.isMultiple(of: ticksPerFrame) { _ = lens.step(dt: Double(ticksPerFrame) * tick) }
            }
            return (start, lens.centre)
        }
        let at60 = move(hz: 60)
        let at120 = move(hz: 120)
        #expect(at60.end - at60.start > 1, "at 60Hz the lens moved only \(at60.start) → \(at60.end)")
        #expect(at120.end - at120.start > 1, "at 120Hz the lens moved only \(at120.start) → \(at120.end)")
        #expect(abs(at60.end - at120.end) <= 0.01, "60Hz ended at \(at60.end), 120Hz at \(at120.end)")
    }

    /// The speed smoothing is time-based and counts each stretch of time
    /// once: a pointer moving a steady 0.12pt/ms reads `0.12 × (1 − 0.6^15)`
    /// after 0.25s, with its moves and the frames both at 60Hz, both at
    /// 120Hz, or with moves at 60Hz and frames at 120Hz, where every other
    /// frame sees no move and decays the speed until the next move. Time runs
    /// in ticks of 1/120s.
    @Test func speedSmoothingIsTimeBased() {
        func speedAfterSweep(moveTicks: Int, frameTicks: Int) -> CGFloat {
            var lens = Self.opened()
            let start = Self.restingCentre(of: 20)
            let tick = 1.0 / 120
            lens.notePointer(y: start, time: 0)
            for index in 1...30 {
                let time = Double(index) * tick
                if index.isMultiple(of: moveTicks) {
                    lens.notePointer(y: start + 0.12 * CGFloat(time * 1000), time: time)
                }
                if index.isMultiple(of: frameTicks) { _ = lens.step(dt: Double(frameTicks) * tick) }
            }
            return lens.speed
        }
        let kept: Double = pow(0.6, 15)
        let expected = 0.12 * (1 - CGFloat(kept))
        let at60 = speedAfterSweep(moveTicks: 2, frameTicks: 2)
        let at120 = speedAfterSweep(moveTicks: 1, frameTicks: 1)
        let mixed = speedAfterSweep(moveTicks: 2, frameTicks: 1)
        #expect(abs(at60 - expected) <= 1e-9, "at 60Hz the smoothed speed is \(at60), not \(expected)")
        #expect(abs(at120 - expected) <= 1e-9, "at 120Hz the smoothed speed is \(at120), not \(expected)")
        #expect(abs(mixed - expected) <= 1e-9,
                "with moves at 60Hz and frames at 120Hz the smoothed speed is \(mixed), not \(expected)")
    }

    /// A 200pt move in one frame's time is a flick: the lens holds still,
    /// and follows once the smoothed speed has decayed.
    @Test func flickFreezes() {
        var lens = Self.opened()
        let start = lens.centre
        let far = Self.restingCentre(of: 20) + 200
        lens.notePointer(y: Self.restingCentre(of: 20), time: 0)
        lens.notePointer(y: far, time: Self.frame)
        let moved = lens.step(dt: Self.frame)
        #expect(!moved)
        #expect(lens.centre == start, "the centre moved from \(start) to \(lens.centre)")
        #expect(lens.speed > PromptRailSteadyLens.flickSpeed)

        var frames = 0
        while frames < 10, !lens.step(dt: Self.frame) { frames += 1 }
        #expect(frames < 10, "the lens never followed once the flick ended")
    }

    /// A late frame that spans the end of a flick moves the lens as far as
    /// the frames it stands for: it eases only for the part of its time after
    /// the speed fell to `flickSpeed`. A 90pt move in 10ms reads about
    /// 2.4pt/ms, which decays to the flick speed some 54ms later; one 150ms
    /// frame and nine 1/60s frames then leave the centre in the same place.
    @Test func lateFrameAfterFlickEasesFromItsEnd() throws {
        var lens = Self.opened()
        let start = lens.centre
        let pushed = lens.rows.y(ofFraction: start + 6)
        lens.notePointer(y: pushed - 90, time: 1)
        lens.notePointer(y: pushed, time: 1.010)
        _ = lens.step(dt: 1.0 / 120)
        try #require(lens.speed > PromptRailSteadyLens.flickSpeed,
                     "precondition: a 90pt move in 10ms is a flick, read as \(lens.speed)pt/ms")
        try #require(lens.centre == start, "precondition: the flick held the lens still")

        var late = lens
        _ = late.step(dt: 0.150)
        var paced = lens
        for _ in 0..<9 { _ = paced.step(dt: Self.frame) }
        let lateMoved = late.centre - start
        let pacedMoved = paced.centre - start
        try #require(pacedMoved > 0.5, "precondition: nine frames moved the lens only \(pacedMoved) rows")
        #expect(abs(lateMoved - pacedMoved) <= 0.01 * pacedMoved,
                "one 150ms frame moved the lens \(lateMoved) rows, nine 1/60s frames \(pacedMoved)")
    }

    /// A flick that starts while the frames are paused freezes the lens on
    /// the first step: its speed comes from the moves' own times, not from
    /// frames. The pointer rests inside the dead zone and the frames stop; a
    /// second later it moves 1pt, and 10ms after that 40pt on, past the dead
    /// zone. The same 40pt move made a second after the 1pt one is slow, and
    /// the first step follows it.
    @Test func flickWhileFramesPausedFreezes() {
        func pushed(after gap: TimeInterval) -> (start: CGFloat, moved: Bool, lens: PromptRailSteadyLens) {
            var lens = Self.opened()
            let start = lens.centre
            let inside = lens.rows.y(ofFraction: start + 2.6)
            lens.notePointer(y: inside, time: 0)
            for _ in 0..<30 { _ = lens.step(dt: Self.frame) }
            lens.notePointer(y: inside + 1, time: 1.5)
            lens.notePointer(y: inside + 41, time: 1.5 + gap)
            let moved = lens.step(dt: Self.frame)
            return (start, moved, lens)
        }
        let flick = pushed(after: 0.010)
        #expect(!flick.moved, "the first step after a flick moved the lens to \(flick.lens.centre)")
        #expect(flick.lens.centre == flick.start)
        #expect(flick.lens.speed > PromptRailSteadyLens.flickSpeed,
                "a 40pt move in 10ms read as \(flick.lens.speed)pt/ms")

        let slow = pushed(after: 1)
        #expect(slow.moved, "precondition: the same move, made slowly, is past the dead zone")
        #expect(slow.lens.speed <= PromptRailSteadyLens.flickSpeed,
                "a 40pt move in 1s read as \(slow.lens.speed)pt/ms")
    }

    /// A pointer that comes back after leaving the rail and the box is no
    /// flick: it leaves, and 300ms later comes back 150pt lower, and the
    /// first step follows it. Where it went meanwhile was no move over the
    /// rail. Read as one move over the 300ms, the same return is 0.5pt/ms, a
    /// flick, which is what a pointer that never left reads.
    @Test func returnAfterLeavingIsNoFlick() {
        func returned(leaving: Bool) -> (start: CGFloat, moved: Bool, lens: PromptRailSteadyLens) {
            var lens = Self.opened()
            let start = lens.centre
            let resting = Self.restingCentre(of: 20)
            lens.notePointer(y: resting, time: 0)
            _ = lens.step(dt: Self.frame)
            if leaving { lens.pointerLeft() }
            lens.notePointer(y: resting + 150, time: 0.3)
            let moved = lens.step(dt: Self.frame)
            return (start, moved, lens)
        }
        let back = returned(leaving: true)
        #expect(back.moved, "the first step after the pointer came back froze, at \(back.lens.speed)pt/ms")
        #expect(back.lens.centre > back.start, "the lens moved from \(back.start) to \(back.lens.centre)")
        #expect(back.lens.speed <= PromptRailSteadyLens.flickSpeed)

        let stayed = returned(leaving: false)
        #expect(!stayed.moved, "precondition: the same move by a pointer that never left is a flick")
        #expect(stayed.lens.speed > PromptRailSteadyLens.flickSpeed)
    }

    /// Once the pointer stops, the lens stops within 2 seconds and stays put.
    @Test func settles() throws {
        var lens = Self.opened()
        lens.notePointer(y: lens.rows.y(ofFraction: 30.5), time: 0)
        var frozen = 0
        while frozen < 10, !lens.step(dt: Self.frame) { frozen += 1 }
        try #require(frozen < 10, "the lens never started following")

        var moving = 0
        while moving < 120, lens.step(dt: Self.frame) { moving += 1 }
        #expect(moving < 120, "the lens still moved 120 frames after the pointer stopped")
        let settled = lens.centre
        var movedAgain = false
        for _ in 0..<10 { movedAgain = lens.step(dt: Self.frame) || movedAgain }
        #expect(!movedAgain)
        #expect(lens.centre == settled)
    }

    /// The same push settles on the same centre at 60Hz and at 120Hz: once
    /// within 0.002 rows of its target, the lens moves onto it and stops,
    /// rather than stopping wherever its last step left it.
    @Test func settlesOnTheSameCentreAtAnyRate() throws {
        func settled(hz: Int) throws -> CGFloat {
            var lens = Self.opened()
            lens.notePointer(y: lens.rows.y(ofFraction: 30.5), time: 0)
            let dt = 1.0 / Double(hz)
            var frames = 0
            while frames < 10 * hz, lens.step(dt: dt) { frames += 1 }
            try #require(frames > 0 && frames < 10 * hz, "at \(hz)Hz the lens moved for \(frames) frames")
            let centre = lens.centre
            for _ in 0..<10 { _ = lens.step(dt: dt) }
            try #require(lens.centre == centre, "at \(hz)Hz the lens moved on after settling")
            return centre
        }
        let at60 = try settled(hz: 60)
        let at120 = try settled(hz: 120)
        #expect(abs(at60 - at120) <= 1e-9, "60Hz settled at \(at60), 120Hz at \(at120)")
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
        var time: TimeInterval = 0
        lens.notePointer(y: pointer, time: time)
        while pointer > 150 {
            pointer = max(150, pointer - 2)
            time += Self.frame
            lens.notePointer(y: pointer, time: time)
            _ = lens.step(dt: Self.frame)
        }
        var frames = 0
        while frames < 600, lens.step(dt: Self.frame) { frames += 1 }
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
        var time: TimeInterval = 0
        lens.notePointer(y: pointer, time: time)
        while pointer < target {
            pointer = min(target, pointer + 2)
            time += Self.frame
            lens.notePointer(y: pointer, time: time)
            if lens.step(dt: Self.frame) { moves += 1 }
        }
        #expect(lens.speed > 0.05, "the lens stopped tracking the pointer's speed: \(lens.speed)")
        for _ in 0..<60 {
            if lens.step(dt: Self.frame) { moves += 1 }
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
