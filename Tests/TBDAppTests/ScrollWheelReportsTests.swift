import Testing
import AppKit
@testable import TBDApp

/// Tier 1: `ScrollWheelAccumulator` is pure value logic, driven entirely by
/// the plain values and timestamps passed in.
@Suite("Scroll monitor wheel reports")
struct ScrollWheelReportsTests {
    private typealias Event = ScrollWheelAccumulator.Event

    /// Every test that is not about cell size uses this one, so point deltas
    /// read as tenths of a cell: 9 is 0.9 cells.
    private static let cellHeight: CGFloat = 10

    /// Drives one accumulator with mouse reporting on, one event a second
    /// apart by default — long enough for the token bucket to refill to its
    /// full burst, so the rate bound never decides a count unless a test
    /// spaces events itself.
    private struct Wheel {
        var accumulator = ScrollWheelAccumulator()
        var now: TimeInterval = 0

        mutating func send(
            _ deltaY: CGFloat,
            precise: Bool = true,
            phase: ScrollWheelAccumulator.Phase = .gestureChanged,
            after gap: TimeInterval = 1
        ) -> Int {
            now += gap
            let wheel = accumulator.reports(
                for: Event(deltaY: deltaY, precise: precise, phase: phase, timestamp: now),
                cellHeight: ScrollWheelReportsTests.cellHeight,
                mouseReporting: true, alternateScreen: true)
            #expect(wheel.claim == true)
            return wheel.lines
        }

        mutating func notch(_ deltaY: CGFloat, after gap: TimeInterval = 1) -> Int {
            send(deltaY, precise: false, phase: .unphased, after: gap)
        }
    }

    private static func reports(
        deltaY: CGFloat, precise: Bool, mouseReporting: Bool, alternateScreen: Bool
    ) -> (claim: Bool, lines: Int) {
        var accumulator = ScrollWheelAccumulator()
        return accumulator.reports(
            for: Event(deltaY: deltaY, precise: precise, phase: precise ? .gestureChanged : .unphased, timestamp: 0),
            cellHeight: cellHeight, mouseReporting: mouseReporting, alternateScreen: alternateScreen)
    }

    // MARK: - Claim semantics (carried over unchanged from `wheelReports`)

    /// Regression for the composer-draft-wiping bug (#840): before mouse
    /// reporting is on, a wheel event over the ALTERNATE screen used to be
    /// handed back to AppKit unclaimed, where SwiftTerm's fallback turned it
    /// into Up/Down arrow keys — keystrokes that land on whatever is
    /// attached, wiping an in-progress draft. It must now be claimed (so it
    /// never reaches that fallback) and dropped (there is no reporting
    /// session to forward it to). `claim == false` here would reopen #840.
    @Test("mouse reporting off, alternate screen: claimed and dropped, never handed to the arrow-key fallback", arguments: [false, true])
    func mouseOffAlternateClaimedAndDropped(precise: Bool) {
        let wheel = Self.reports(deltaY: 30, precise: precise, mouseReporting: false, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.lines == 0)
    }

    /// Regression for the opposite failure: an ordinary shell prompt sits on
    /// the NORMAL screen without mouse reporting, and relies on SwiftTerm's
    /// own local scrollback to handle wheel motion. Claiming here would
    /// silently kill scrollback for every plain shell tab. `claim == true`
    /// here would reintroduce that regression.
    @Test("mouse reporting off, normal screen: not claimed, so native scrollback keeps working", arguments: [false, true])
    func mouseOffNormalPassesThrough(precise: Bool) {
        let wheel = Self.reports(deltaY: 30, precise: precise, mouseReporting: false, alternateScreen: false)
        #expect(wheel.claim == false)
        #expect(wheel.lines == 0)
    }

    @Test("zero delta with mouse reporting on is claimed with no reports", arguments: [false, true])
    func zeroDeltaClaimedAndDropped(precise: Bool) {
        let wheel = Self.reports(deltaY: 0, precise: precise, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.lines == 0)
    }

    /// Holds for a classic notch only. The same fraction from a precise
    /// device now sends nothing until a whole cell accumulates — that is the
    /// #719 fix, pinned by `subCellDeltasBankUntilAWholeCell`.
    @Test("a fractional classic notch still sends one report")
    func fractionalLineSendsOne() {
        let wheel = Self.reports(deltaY: 0.8, precise: false, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.lines == 1)
    }

    /// Holds for precise motion, which is counted in cells. A classic notch
    /// of the same magnitude now sends one report — pinned by
    /// `classicNotchIsOneReport`.
    @Test("whole cells of precise motion truncate to the cell count")
    func wholeLinesTruncate() {
        let wheel = Self.reports(deltaY: 24, precise: true, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.lines == 2)
    }

    @Test("a negative fractional classic notch still sends one report, downward")
    func negativeFractionalSendsOne() {
        let wheel = Self.reports(deltaY: -0.5, precise: false, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.lines == -1)
    }

    /// Mouse reporting wins regardless of buffer: a normal-screen program
    /// that has turned mouse reporting on (rare, but xterm-legal) still gets
    /// its reports, exactly as an alternate-screen one does.
    @Test("mouse reporting on, normal screen: still claimed and forwarded")
    func mouseOnNormalStillForwards() {
        let wheel = Self.reports(deltaY: 1.0, precise: false, mouseReporting: true, alternateScreen: false)
        #expect(wheel.claim == true)
        #expect(wheel.lines == 1)
    }

    /// The claim depends on the modes alone — never on the delta, the
    /// device, the banked remainder or the token bucket. One accumulator
    /// takes every combination at a single timestamp, so the bucket is
    /// empty for most of them and the claim still has to hold.
    @Test("claim is mouse reporting OR alternate screen, whatever the delta, device or bucket")
    func claimMatrix() {
        var accumulator = ScrollWheelAccumulator()
        for mouseReporting in [false, true] {
            for alternateScreen in [false, true] {
                for precise in [false, true] {
                    for deltaY: CGFloat in [0, 0.3, 3, 9, 30, -0.3, -3, -30] {
                        let wheel = accumulator.reports(
                            for: Event(deltaY: deltaY, precise: precise, phase: precise ? .gestureChanged : .unphased, timestamp: 0),
                            cellHeight: Self.cellHeight,
                            mouseReporting: mouseReporting, alternateScreen: alternateScreen)
                        let context: Comment = "reporting=\(mouseReporting) alternate=\(alternateScreen) precise=\(precise) deltaY=\(deltaY)"
                        #expect(wheel.claim == (mouseReporting || alternateScreen), context)
                        if !mouseReporting {
                            #expect(wheel.lines == 0, context)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Precise accumulation

    @Test("sub-cell precise deltas send nothing until a whole cell accumulates, and the remainder carries")
    func subCellDeltasBankUntilAWholeCell() {
        var wheel = Wheel()
        #expect(wheel.send(4) == 0)
        #expect(wheel.send(4) == 0)
        // 12 points: one cell crossed, 2 banked.
        #expect(wheel.send(4) == 1)
        // 2 banked + 8 is the next whole cell. Discarding the remainder
        // after a report would send nothing here.
        #expect(wheel.send(8) == 1)
    }

    @Test("a large precise delta sends one report per whole cell and banks the rest", arguments: [CGFloat(1), -1])
    func largeDeltaSendsWholeCells(sign: CGFloat) {
        var wheel = Wheel()
        // 4.5 cells: four reports, half a cell banked.
        #expect(wheel.send(45 * sign) == 4 * Int(sign))
        // The banked half plus another half is one more.
        #expect(wheel.send(5 * sign) == Int(sign))
    }

    @Test("reversing direction discards the banked remainder")
    func reversalDiscardsRemainder() {
        var wheel = Wheel()
        #expect(wheel.send(9) == 0)
        // Accumulating magnitudes instead of signed points would make this
        // 1.1 cells and send a report.
        #expect(wheel.send(-2) == 0)
        // 1.1 cells downward since the reversal. Netting the reversal against
        // the old remainder instead would leave -0.2 cells and send nothing.
        #expect(wheel.send(-9) == -1)
    }

    @Test("a new gesture discards the banked remainder, then banks its own delta")
    func newGestureDiscardsRemainder() {
        var wheel = Wheel()
        #expect(wheel.send(9) == 0)
        // With the stale 0.9 cells this would be 1.1 and send a report.
        #expect(wheel.send(2, phase: .gestureBegan) == 0)
        // The began event's own 0.2 cells were banked after the reset.
        #expect(wheel.send(8) == 1)
    }

    /// A `.mayBegin` or `.began` event usually carries no delta at all; the
    /// reset still has to happen on it.
    @Test("a zero-delta gesture start still discards the banked remainder")
    func zeroDeltaGestureStartDiscardsRemainder() {
        var wheel = Wheel()
        #expect(wheel.send(9) == 0)
        #expect(wheel.send(0, phase: .gestureBegan) == 0)
        #expect(wheel.send(2) == 0)
    }

    @Test("momentum continues the gesture it follows, remainder included")
    func momentumKeepsRemainder() {
        var wheel = Wheel()
        #expect(wheel.send(9) == 0)
        #expect(wheel.send(2, phase: .momentum) == 1)
    }

    /// The amplification #719 measured: a momentum tail is many events, each
    /// a fraction of a cell, and every one of them used to become a report.
    /// 60 events of 0.3 cells at 64 Hz is 18 cells of motion — 18 reports,
    /// not 60, and not zero either, since momentum is not dropped.
    @Test("a momentum tail of tiny deltas sends one report per cell of motion, not per event")
    func momentumTailAccumulates() {
        for phase in [ScrollWheelAccumulator.Phase.momentum, .gestureChanged] {
            var wheel = Wheel()
            var total = 0
            for _ in 0..<60 {
                total += wheel.send(3, phase: phase, after: 1.0 / 64)
            }
            #expect(total == 18, "phase=\(phase)")
        }
    }

    @Test("with no cell height there is nothing to accumulate against: claimed, nothing sent, nothing banked")
    func zeroCellHeightSendsNothing() {
        var accumulator = ScrollWheelAccumulator()
        let wheel = accumulator.reports(
            for: Event(deltaY: 50, precise: true, phase: .gestureChanged, timestamp: 1),
            cellHeight: 0, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.lines == 0)
        let next = accumulator.reports(
            for: Event(deltaY: 5, precise: true, phase: .gestureChanged, timestamp: 2),
            cellHeight: Self.cellHeight, mouseReporting: true, alternateScreen: true)
        #expect(next.lines == 0)
    }

    /// Mirrors SwiftTerm's handler: motion that arrives while there is no
    /// reporting session is not banked and handed to the first event after
    /// reporting comes back.
    @Test("an event with mouse reporting off discards the banked remainder")
    func reportingOffDiscardsRemainder() {
        var wheel = Wheel()
        #expect(wheel.send(9) == 0)
        let off = wheel.accumulator.reports(
            for: Event(deltaY: 1, precise: true, phase: .gestureChanged, timestamp: wheel.now + 1),
            cellHeight: Self.cellHeight, mouseReporting: false, alternateScreen: true)
        #expect(off.claim == true)
        #expect(off.lines == 0)
        #expect(wheel.send(2, after: 2) == 0)
    }

    // MARK: - Classic wheels

    @Test("a classic notch is one report whatever its magnitude, and its sign is the direction")
    func classicNotchIsOneReport() {
        var wheel = Wheel()
        for deltaY: CGFloat in [0.1, 1, 3, 12] {
            #expect(wheel.notch(deltaY) == 1, "deltaY=\(deltaY)")
        }
        for deltaY: CGFloat in [-0.1, -1, -5] {
            #expect(wheel.notch(deltaY) == -1, "deltaY=\(deltaY)")
        }
    }

    @Test("a classic notch discards a precise remainder")
    func classicNotchDiscardsPreciseRemainder() {
        var wheel = Wheel()
        #expect(wheel.send(9) == 0)
        #expect(wheel.notch(1) == 1)
        // With the stale 0.9 cells this would be 1.1 and send a report.
        #expect(wheel.send(2) == 0)
    }

    // MARK: - Rate bound

    @Test("a burst of six reports passes at once, and the seventh is dropped")
    func burstOfSixPasses() {
        var wheel = Wheel()
        var sent: [Int] = []
        for deltaY: CGFloat in [1, 1, 1, 1, -1, -1, -1, 1, 1, 1] {
            sent.append(wheel.notch(deltaY, after: 0))
        }
        #expect(sent == [1, 1, 1, 1, -1, -1, 0, 0, 0, 0])
    }

    /// The bucket bounds a single event too: 20 cells of motion in one
    /// event sends the burst, not 20 reports.
    @Test("one large precise event is capped at the burst, in either direction", arguments: [CGFloat(1), -1])
    func largeEventCappedAtBurst(sign: CGFloat) {
        var wheel = Wheel()
        #expect(wheel.send(200 * sign) == 6 * Int(sign))
    }

    /// 256 notches/s for one second, against 100 reports/s. Every interval is
    /// an exact binary fraction, so the arithmetic is exact: the full burst
    /// of 6, plus 255 intervals × 100/256 = 99.6 tokens refilled, is 105.6
    /// reports' worth — 105 sent, and the other 151 dropped.
    @Test("events faster than 100 per second are capped at the sustained rate")
    func sustainedRateIsCapped() {
        var wheel = Wheel()
        var total = wheel.notch(1, after: 0)
        for _ in 1..<256 {
            total += wheel.notch(1, after: 1.0 / 256)
        }
        #expect(total == 105)
    }

    @Test("tokens refill with timestamp progress, up to the burst and no further")
    func tokensRefillWithTimestamps() {
        var wheel = Wheel()
        var drained = 0
        for _ in 0..<7 {
            drained += wheel.notch(1, after: 0)
        }
        #expect(drained == 6)

        // 1/32 s at 100/s is 3.125 tokens: three reports.
        var refilled = wheel.notch(1, after: 1.0 / 32)
        for _ in 0..<5 {
            refilled += wheel.notch(1, after: 0)
        }
        #expect(refilled == 3)

        // A full second's pause refills 100 tokens' worth, but the bucket
        // holds six.
        var afterPause = wheel.notch(1, after: 1)
        for _ in 0..<9 {
            afterPause += wheel.notch(1, after: 0)
        }
        #expect(afterPause == 6)
    }

    // MARK: - Phase mapping

    @Test("NSEvent phases collapse to the accumulator's phase")
    func phaseMapping() {
        typealias Phase = ScrollWheelAccumulator.Phase
        #expect(Phase(phase: [], momentumPhase: []) == .unphased)
        #expect(Phase(phase: .mayBegin, momentumPhase: []) == .gestureBegan)
        #expect(Phase(phase: .began, momentumPhase: []) == .gestureBegan)
        for phase: NSEvent.Phase in [.changed, .stationary, .ended, .cancelled] {
            #expect(Phase(phase: phase, momentumPhase: []) == .gestureChanged, "phase=\(phase.rawValue)")
        }
        for momentumPhase: NSEvent.Phase in [.began, .changed, .ended] {
            #expect(Phase(phase: [], momentumPhase: momentumPhase) == .momentum, "momentumPhase=\(momentumPhase.rawValue)")
        }
    }
}
