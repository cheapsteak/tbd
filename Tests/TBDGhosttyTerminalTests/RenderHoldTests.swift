import GhosttyVt
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// DEC 2026 holds as libghostty reports them, through its `RENDER_HOLD` callback, and the
/// watchdog that reads them. Every case runs on a real terminal, so it checks libghostty's half of
/// the contract too: `GhosttyTerminalRenderHoldFn` in `terminal.h` at `vt-1.0.0`.
///
/// This file imports `GhosttyVt` to change mode 2026 through `GHOSTTY_TERMINAL_OPT_MODE`, as the
/// force-off does. Its C terminal type is also named `GhosttyTerminal`, so the Swift class is
/// spelled with its module name.
@Suite(.fastPassBounded)
struct RenderHoldTests {
    private typealias Terminal = TBDGhosttyTerminal.GhosttyTerminal
    private typealias ForceOff = SyncOutputWatchdog.ForceOff

    private static let begin = "\u{1b}[?2026h"
    private static let end = "\u{1b}[?2026l"
    private static let idle = RenderHold(isOpen: false, ended: false)
    private static let holding = RenderHold(isOpen: true, ended: false)
    private static let released = RenderHold(isOpen: false, ended: true)

    private static func makeTerminal() throws -> Terminal {
        try Terminal(cols: 20, rows: 5, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
    }

    /// Sets mode 2026 the way the force-off clears it: through `OPT_MODE`, which raises no edge.
    private static func setModeWithoutAnEdge(_ terminal: Terminal, _ on: Bool) throws {
        let result: GhosttyResult = terminal.withRaw { raw -> GhosttyResult in
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: on)
            return ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_MODE, &config)
        } ?? GHOSTTY_INVALID_VALUE
        let succeeded = result == GHOSTTY_SUCCESS
        try #require(succeeded, "setting mode 2026 through OPT_MODE failed: \(String(describing: result))")
        let mode = terminal.withLocked { $0.mode(2026) }
        try #require(mode == on, "mode 2026 reads \(mode) after OPT_MODE set it to \(on)")
    }

    // MARK: Edges

    @Test func settingTheModeOpensAHoldAndResettingItEndsIt() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        let fresh = terminal.renderHold
        #expect(fresh == Self.idle, "a new terminal reads \(fresh)")

        terminal.feed(text: Self.begin + "frame")
        let held = terminal.renderHold
        #expect(held == Self.holding, "after ?2026h the hold reads \(held)")

        terminal.feed(text: Self.end)
        let released = terminal.renderHold
        #expect(released == Self.released, "after ?2026l the hold reads \(released)")
    }

    /// libghostty pairs its edges. A second set during a hold is no new begin, so it is no end of
    /// the first either, and one reset closes both sets: holds do not nest.
    @Test func aSecondSetDuringAHoldRaisesNothing() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin + "A")
        terminal.feed(text: Self.begin + "B")
        let afterSecondSet = terminal.renderHold
        #expect(afterSecondSet == Self.holding, "a second ?2026h left the hold reading \(afterSecondSet)")

        terminal.feed(text: Self.end)
        let afterOneReset = terminal.renderHold
        #expect(afterOneReset == Self.released, "one ?2026l after two sets left the hold reading \(afterOneReset)")
    }

    @Test func aResetWithNoHoldRaisesNothing() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.end)
        terminal.feed(text: "\u{1b}c")
        terminal.reset()
        terminal.resize(cols: 30, rows: 6)
        let hold = terminal.renderHold
        #expect(hold == Self.idle, "ending a hold that was never open raised an edge: \(hold)")
    }

    @Test func anInBandRISEndsAHold() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        terminal.feed(text: "\u{1b}c")
        let hold = terminal.renderHold
        #expect(hold == Self.released, "after ESC c the hold reads \(hold)")
    }

    @Test func aResetEndsAHold() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        terminal.reset()
        let hold = terminal.renderHold
        #expect(hold == Self.released, "after reset() the hold reads \(hold)")
    }

    @Test func aResizeEndsAHold() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        terminal.resize(cols: 30, rows: 6)
        let hold = terminal.renderHold
        #expect(hold == Self.released, "after a resize the hold reads \(hold)")
    }

    /// The mute drops effects meant for the owner. A hold is the terminal's own state, so a muted
    /// preamble that replays `?2026h` opens one, and a muted reset ends one.
    @Test func aMutedFeedStillRecordsEdges() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.isMuted = true
        terminal.feed(text: Self.begin)
        let held = terminal.renderHold
        terminal.feed(text: Self.end)
        let released = terminal.renderHold
        terminal.isMuted = false
        #expect(held == Self.holding, "a muted ?2026h left the hold reading \(held)")
        #expect(released == Self.released, "a muted ?2026l left the hold reading \(released)")
    }

    /// `GhosttyEngine.prepareForPreamble()` resets the terminal while it is muted. The end edge
    /// that reset raises must not be lost, or the tick would go on skipping frames.
    @Test func aMutedResetStillEndsTheHold() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        terminal.isMuted = true
        terminal.reset()
        terminal.isMuted = false
        let hold = terminal.renderHold
        #expect(hold == Self.released, "after a muted reset the hold reads \(hold)")
        let decision = terminal.syncOutputDecision(now: .seconds(100))
        #expect(decision == .render, "the tick after a muted reset answered \(decision)")
    }

    // MARK: The tick

    /// The tick reads the hold, not the mode. A mode set without an edge opens no hold, and a
    /// mode cleared without an edge closes none.
    @Test func theTickReadsTheHoldRatherThanTheMode() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        try Self.setModeWithoutAnEdge(terminal, true)
        let noHold = terminal.syncOutputDecision(now: .seconds(100))
        #expect(noHold == .render, "mode 2026 set with no hold open: the tick answered \(noHold)")

        try Self.setModeWithoutAnEdge(terminal, false)
        terminal.feed(text: Self.begin)
        try Self.setModeWithoutAnEdge(terminal, false)
        let holdOpen = terminal.syncOutputDecision(now: .seconds(101))
        #expect(holdOpen == .skipFrame, "a hold open with the mode cleared: the tick answered \(holdOpen)")
    }

    /// The force-off turns the mode off through `OPT_MODE`, which raises no edge, so it closes the
    /// hold itself. Left open, the tick after a force-off would skip again. Below the timeout the
    /// hold stays open and nothing is reported.
    @Test func aForceOffClosesTheHoldRaisesNoEdgeAndReportsOnce() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        var reports: [ForceOff] = []

        let first = terminal.syncOutputDecision(now: .seconds(100)) { reports.append($0) }
        let second = terminal.syncOutputDecision(now: .seconds(100.5)) { reports.append($0) }
        let stillHeld = terminal.renderHold
        #expect(first == .skipFrame)
        #expect(second == .skipFrame)
        #expect(stillHeld == Self.holding, "below the timeout the hold reads \(stillHeld)")
        #expect(reports.isEmpty, "a tick below the timeout reported a force-off: \(reports)")

        let forced = terminal.syncOutputDecision(now: .seconds(101)) { reports.append($0) }
        let afterForceOff = terminal.renderHold
        let mode = terminal.withLocked { $0.mode(2026) }
        #expect(forced == .forceOffAndRender)
        #expect(afterForceOff == Self.idle, "after the force-off the hold reads \(afterForceOff)")
        #expect(!mode, "the force-off left mode 2026 set")
        let expected = [ForceOff(heldFor: .seconds(1), skippedTicks: 2)]
        #expect(reports == expected, "the force-off reported \(reports)")

        let next = terminal.syncOutputDecision(now: .seconds(101.01)) { reports.append($0) }
        #expect(next == .render, "the tick after a force-off answered \(next)")
        #expect(reports.count == 1, "one force-off was reported \(reports.count) times")
    }

    /// A program forced off still sends `?2026h` with its next frame. The force-off cleared the
    /// mode bit, and libghostty's begin edge compares against that bit, so the set opens a new
    /// hold and the next tick hides the half-drawn frame again.
    @Test func aSetAfterAForceOffOpensANewHold() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        _ = terminal.syncOutputDecision(now: .seconds(100)) { _ in }
        let forced = terminal.syncOutputDecision(now: .seconds(101)) { _ in }
        try #require(forced == .forceOffAndRender, "the hold was not forced off: \(forced)")

        terminal.feed(text: Self.begin + "next frame")
        let hold = terminal.renderHold
        let next = terminal.syncOutputDecision(now: .seconds(101.01)) { _ in }
        #expect(hold == Self.holding, "a set after the force-off left the hold reading \(hold)")
        #expect(next == .skipFrame, "the tick after a new set answered \(next)")
    }

    /// A program that ends one hold and starts the next between every two ticks never lets a tick
    /// see the screen free of a hold. The watchdog times the run of ticks that saw a hold, so it
    /// still forces the mode off after a second; a restart per hold would hide every frame for good.
    @Test func backToBackHoldsSpanningEveryTickAreForcedOffAfterOneSecond() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        var reports: [ForceOff] = []
        terminal.feed(text: Self.begin + "frame 1")
        let first = terminal.syncOutputDecision(now: .seconds(100)) { reports.append($0) }
        terminal.feed(text: Self.end + Self.begin + "frame 2")
        let second = terminal.syncOutputDecision(now: .seconds(100.5)) { reports.append($0) }
        terminal.feed(text: Self.end + Self.begin + "frame 3")
        let third = terminal.syncOutputDecision(now: .seconds(101)) { reports.append($0) }

        #expect(first == .skipFrame)
        #expect(second == .skipFrame)
        #expect(third == .forceOffAndRender, "back-to-back holds over a second answered \(third)")
        let expected = [ForceOff(heldFor: .seconds(1), skippedTicks: 2)]
        #expect(reports == expected, "the force-off reported \(reports)")
    }

    /// A tick that sees no hold breaks the run, so the next hold is timed from its own first tick.
    @Test func aTickWithNoHoldRestartsTheTimeout() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        var reports: [ForceOff] = []
        terminal.feed(text: Self.begin)
        _ = terminal.syncOutputDecision(now: .seconds(100)) { reports.append($0) }
        terminal.feed(text: Self.end)
        let between = terminal.syncOutputDecision(now: .seconds(100.5)) { reports.append($0) }
        terminal.feed(text: Self.begin)
        let restarted = terminal.syncOutputDecision(now: .seconds(101)) { reports.append($0) }
        let late = terminal.syncOutputDecision(now: .seconds(101.75)) { reports.append($0) }
        let forced = terminal.syncOutputDecision(now: .seconds(102)) { reports.append($0) }

        #expect(between == .render)
        #expect(restarted == .skipFrame, "a hold timed from the first one's tick answered \(restarted)")
        #expect(late == .skipFrame)
        #expect(forced == .forceOffAndRender)
        let expected = [ForceOff(heldFor: .seconds(1), skippedTicks: 2)]
        #expect(reports == expected, "the force-off reported \(reports)")
    }

    // MARK: Attach

    /// An attach sets the hold from one read of the mode, so a mode set without an edge is a hold
    /// from then on, and the watchdog starts timing at the next tick.
    @Test func attachingOverASetModeStartsWithTheHoldOpen() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        try Self.setModeWithoutAnEdge(terminal, true)
        let beforeAttach = terminal.renderHold
        #expect(beforeAttach == Self.idle, "OPT_MODE raised an edge: \(beforeAttach)")

        terminal.resetSyncOutputWatchdog()
        let afterAttach = terminal.renderHold
        let decision = terminal.syncOutputDecision(now: .seconds(100))
        #expect(afterAttach == Self.holding, "attaching over mode 2026 left the hold reading \(afterAttach)")
        #expect(decision == .skipFrame, "the first tick after the attach answered \(decision)")
    }

    /// The other branch of the attach read: a mode cleared without an edge closes the hold, and
    /// the read is not an edge, so it raises no end.
    @Test func attachingOverAClearedModeClosesTheHoldWithoutAnEnd() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        try Self.setModeWithoutAnEdge(terminal, false)

        terminal.resetSyncOutputWatchdog()
        let afterAttach = terminal.renderHold
        let decision = terminal.syncOutputDecision(now: .seconds(100))
        #expect(afterAttach == Self.idle, "attaching over a cleared mode left the hold reading \(afterAttach)")
        #expect(decision == .render, "the first tick after the attach answered \(decision)")
    }

    /// An attach also forgets the watchdog's run: the ticks before it are stale.
    @Test func attachingRestartsTheTimeout() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        _ = terminal.syncOutputDecision(now: .seconds(100))
        terminal.resetSyncOutputWatchdog()
        let afterAttach = terminal.syncOutputDecision(now: .seconds(110))
        let forced = terminal.syncOutputDecision(now: .seconds(111))
        #expect(afterAttach == .skipFrame, "the first tick after an attach answered \(afterAttach)")
        #expect(forced == .forceOffAndRender)
    }

    @Test func aClosedTerminalRendersAndReportsNothing() throws {
        let terminal = try Self.makeTerminal()
        terminal.feed(text: Self.begin)
        terminal.close()
        var reports: [ForceOff] = []
        let decision = terminal.syncOutputDecision(now: .seconds(100)) { reports.append($0) }
        #expect(decision == .render)
        #expect(reports.isEmpty)
    }
}

/// The watchdog as a pure value.
@Suite(.fastPassBounded)
struct SyncOutputWatchdogTests {
    @Test func noHoldRendersAndStartsNothing() {
        var watchdog = SyncOutputWatchdog()
        let decision = watchdog.evaluate(holdOpen: false, now: .seconds(5))
        let report = watchdog.lastForceOff
        #expect(decision == .render)
        #expect(!watchdog.isTracking)
        #expect(report == nil)
    }

    @Test func aHoldIsSkippedUntilTheTimeoutAndThenForcedOff() {
        var watchdog = SyncOutputWatchdog(timeout: .seconds(1))
        let decisions = [
            watchdog.evaluate(holdOpen: true, now: .seconds(10)),
            watchdog.evaluate(holdOpen: true, now: .seconds(10.25)),
            watchdog.evaluate(holdOpen: true, now: .seconds(10.5)),
        ]
        let skipped: [SyncOutputWatchdog.Decision] = [.skipFrame, .skipFrame, .skipFrame]
        let reportBeforeTimeout = watchdog.lastForceOff
        #expect(decisions == skipped)
        #expect(watchdog.isTracking)
        #expect(reportBeforeTimeout == nil)

        let forced = watchdog.evaluate(holdOpen: true, now: .seconds(11.5))
        let report = watchdog.lastForceOff
        let expected: SyncOutputWatchdog.ForceOff? = SyncOutputWatchdog.ForceOff(heldFor: .seconds(1.5), skippedTicks: 3)
        #expect(forced == .forceOffAndRender)
        #expect(report == expected, "the force-off reported \(String(describing: report))")
        #expect(!watchdog.isTracking)
    }

    /// The report belongs to the answer that forced the mode off, and the next answer clears it.
    @Test func theNextAnswerClearsTheReport() {
        var watchdog = SyncOutputWatchdog(timeout: .seconds(1))
        _ = watchdog.evaluate(holdOpen: true, now: .seconds(0))
        _ = watchdog.evaluate(holdOpen: true, now: .seconds(1))
        let report = watchdog.lastForceOff
        #expect(report != nil)

        let next = watchdog.evaluate(holdOpen: true, now: .seconds(1.01))
        let reportAfterNext = watchdog.lastForceOff
        #expect(next == .skipFrame, "a hold still seen after the force-off answered \(next)")
        #expect(reportAfterNext == nil)
    }

    @Test func resetForgetsTheRun() {
        var watchdog = SyncOutputWatchdog(timeout: .seconds(1))
        _ = watchdog.evaluate(holdOpen: true, now: .seconds(0))
        _ = watchdog.evaluate(holdOpen: true, now: .seconds(0.5))
        watchdog.reset()
        #expect(!watchdog.isTracking)
        let restarted = watchdog.evaluate(holdOpen: true, now: .seconds(1.25))
        let forced = watchdog.evaluate(holdOpen: true, now: .seconds(2.25))
        let report = watchdog.lastForceOff
        let expected: SyncOutputWatchdog.ForceOff? = SyncOutputWatchdog.ForceOff(heldFor: .seconds(1), skippedTicks: 1)
        #expect(restarted == .skipFrame)
        #expect(forced == .forceOffAndRender)
        #expect(report == expected, "the force-off reported \(String(describing: report))")
    }

    @Test func theNoticeSaysHowLongTheHoldWasSeenAndHowManyTicksItSkipped() {
        let notice = SyncOutputWatchdog.ForceOff(heldFor: .milliseconds(1250), skippedTicks: 150).notice
        #expect(notice.contains("1250 ms"), "the notice reads \(notice.debugDescription)")
        #expect(notice.contains("150 ticks"), "the notice reads \(notice.debugDescription)")
    }
}
