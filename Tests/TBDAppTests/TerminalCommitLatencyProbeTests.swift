import Foundation
import TestSupport
import QuartzCore
import Testing
@testable import TBDApp

/// Tests for `TerminalCommitLatencyProbe` — the app-draw → render-server-commit
/// instrument — and for the `enableCommitLatencyDiagnostic` gate that keeps it
/// off by default.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is `TBDApp.plist` in the developer's home —
/// the same domain a running production TBDApp reads. Every test below drives
/// the gate through a per-test `UserDefaults(suiteName:)` and tears the domain
/// down afterwards, so `.standard` is never touched.
@MainActor
@Suite("Terminal commit-latency probe")
struct TerminalCommitLatencyProbeTests {
    // MARK: - Harness

    /// Drives the probe with a hand-cranked clock and a fake transaction, so a
    /// display cycle can be replayed deterministically — including the cases
    /// real CoreAnimation will not stage on demand: a transaction whose
    /// completion block someone else replaced, and two transactions arriving
    /// closer together than any timer could separate.
    @MainActor
    private final class Harness {
        var now: Double = 0
        var lines: [String] = []
        /// Completion blocks, in registration order.
        var registered: [@Sendable () -> Void] = []

        /// The mark on the transaction currently in flight, standing in for
        /// `CATransaction`'s per-transaction value store.
        private var mark: UInt64?
        /// Turn-boundary markers, in registration order. Fired by `endTurn()`.
        private var turnEndMarkers: [@MainActor () -> Void] = []
        private(set) var probe: TerminalCommitLatencyProbe!

        init() {
            probe = TerminalCommitLatencyProbe(
                now: { [unowned self] in self.now },
                transaction: TerminalCommitLatencyProbe.TransactionSeam(
                    mark: { [unowned self] in self.mark },
                    begin: { [unowned self] id, onCommitted in
                        self.mark = id
                        self.registered.append(onCommitted)
                    }
                ),
                afterCurrentTurn: { [unowned self] body in self.turnEndMarkers.append(body) },
                emit: { [unowned self] line in self.lines.append(line) }
            )
        }

        /// Drain the runloop turn without the completion block having fired —
        /// what CoreAnimation does when an animation in the transaction is
        /// still running.
        func endTurn() {
            let markers = turnEndMarkers
            turnEndMarkers.removeAll()
            for marker in markers { marker() }
        }

        /// Fire only the OLDEST pending turn marker, leaving later ones armed:
        /// an earlier turn's marker draining after a new cycle has begun.
        func fireOldestTurnMarker() {
            guard !turnEndMarkers.isEmpty else { return }
            turnEndMarkers.removeFirst()()
        }

        /// End the transaction currently in flight without committing it —
        /// the next draw will find no mark and so belongs to a new one.
        func beginNewTransaction() {
            mark = nil
        }

        /// One terminal view about to draw, then that draw finishing `costMs`
        /// later — the `viewWillDraw` / `onFramePresented` pair.
        func draw(costMs: Double, isOnScreen: Bool = true) {
            probe.recordDrawWillBegin(at: now, isOnScreen: isOnScreen)
            now += costMs / 1000
            probe.recordFramePresented(at: now)
        }

        /// A view asked to draw that bails before painting — SwiftTerm's
        /// `draw` has early returns before its frame-presented hook.
        func drawWithoutPainting(isOnScreen: Bool = true) {
            probe.recordDrawWillBegin(at: now, isOnScreen: isOnScreen)
        }

        /// Fire the most recently registered completion block, as CoreAnimation
        /// would once the render server has committed, and end the transaction.
        func commit(afterMs: Double) {
            now += afterMs / 1000
            let block = registered.last
            mark = nil
            block?()
        }
    }

    private func withIsolatedDefaults(
        seed: Bool?,
        _ body: (UserDefaults) -> Void
    ) {
        let defaultsSuite = TestDefaultsSuite("CommitLatency")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        if let seed {
            defaults.set(seed, forKey: AppState.enableCommitLatencyDiagnosticKey)
        }
        body(defaults)
    }

    // MARK: - The gate, both branches

    @Test("flag off: no probe exists, so the draw path registers and logs nothing")
    func gateOffYieldsNoProbe() {
        withIsolatedDefaults(seed: false) { defaults in
            #expect(AppState.commitLatencyDiagnosticEnabled(defaults: defaults) == false)
            #expect(TerminalCommitLatencyProbe.make(defaults: defaults) == nil)
        }
    }

    @Test("unset defaults to off — a diagnostic nobody asked for stays silent")
    func gateDefaultsOff() {
        withIsolatedDefaults(seed: nil) { defaults in
            #expect(AppState.commitLatencyDiagnosticEnabled(defaults: defaults) == false)
            #expect(TerminalCommitLatencyProbe.make(defaults: defaults) == nil)
        }
    }

    @Test("flag on: a probe is built")
    func gateOnYieldsProbe() {
        withIsolatedDefaults(seed: true) { defaults in
            #expect(AppState.commitLatencyDiagnosticEnabled(defaults: defaults) == true)
            #expect(TerminalCommitLatencyProbe.make(defaults: defaults) != nil)
        }
    }

    // MARK: - The instrument

    @Test("one draw, one commit: logs draw cost and draw→commit latency")
    func singleDrawCycle() {
        let harness = Harness()
        harness.draw(costMs: 2)
        #expect(harness.lines.isEmpty, "nothing is reported until the render server commits")
        harness.commit(afterMs: 8)
        #expect(harness.lines == ["commit draws=1 paints=1 drawms=2.000 commitms=10.000 vis=1 sync=1"])
    }

    @Test("several views drawing in one cycle produce ONE line, not one per view")
    func multipleDrawsInOneCycle() {
        let harness = Harness()
        harness.draw(costMs: 1)
        harness.draw(costMs: 2)
        harness.draw(costMs: 3)
        #expect(harness.registered.count == 1, "exactly one completion block per transaction")
        harness.commit(afterMs: 4)
        #expect(harness.lines == ["commit draws=3 paints=3 drawms=6.000 commitms=10.000 vis=1 sync=1"])
    }

    @Test("vis=0 only when every view in the cycle was off screen")
    func visibilityIsPerCycle() {
        let offscreen = Harness()
        offscreen.draw(costMs: 1, isOnScreen: false)
        offscreen.commit(afterMs: 1)
        #expect(offscreen.lines.first?.contains(" vis=0 ") == true)

        let mixed = Harness()
        mixed.draw(costMs: 1, isOnScreen: false)
        mixed.draw(costMs: 1, isOnScreen: true)
        mixed.commit(afterMs: 1)
        #expect(mixed.lines.first?.contains(" vis=1 ") == true)
    }

    @Test("consecutive cycles are measured independently")
    func consecutiveCycles() {
        let harness = Harness()
        harness.draw(costMs: 1)
        harness.commit(afterMs: 4)
        harness.draw(costMs: 2)
        harness.commit(afterMs: 20)
        #expect(harness.registered.count == 2)
        #expect(harness.lines == [
            "commit draws=1 paints=1 drawms=1.000 commitms=5.000 vis=1 sync=1",
            "commit draws=1 paints=1 drawms=2.000 commitms=22.000 vis=1 sync=1",
        ])
    }

    @Test("a frame presented with no terminal draw of ours open is ignored")
    func framePresentedOutsideACycle() {
        let harness = Harness()
        harness.probe.recordFramePresented(at: 5)
        #expect(harness.registered.isEmpty)
        #expect(harness.lines.isEmpty)

        harness.now = 10
        harness.draw(costMs: 1)
        harness.commit(afterMs: 1)
        #expect(harness.lines == ["commit draws=1 paints=1 drawms=1.000 commitms=2.000 vis=1 sync=1"])
    }

    /// Back-to-back committed cycles stay separate. This does NOT discriminate
    /// the transaction mark from the elapsed-time boundary it replaced — the
    /// first cycle is already closed by its commit, so both designs agree. The
    /// tests that actually fail under the old design are
    /// `lostCycleIsReportedPromptly`, `eachLostCycleIsItsOwnLine` and
    /// `staleBlockIsInert`, which all leave a cycle open across a transaction
    /// boundary.
    @Test("back-to-back committed cycles are reported separately")
    func backToBackCyclesStaySeparate() {
        let harness = Harness()
        harness.draw(costMs: 1)
        harness.commit(afterMs: 4)

        harness.now += 0.01667
        harness.draw(costMs: 1)
        harness.commit(afterMs: 4)

        #expect(harness.registered.count == 2, "each transaction gets its own completion block")
        #expect(harness.lines == [
            "commit draws=1 paints=1 drawms=1.000 commitms=5.000 vis=1 sync=1",
            "commit draws=1 paints=1 drawms=1.000 commitms=5.000 vis=1 sync=1",
        ])
    }

    @Test("a swallowed completion block is reported lost at the next transaction")
    func lostCycleIsReportedPromptly() {
        let harness = Harness()
        harness.draw(costMs: 1)
        harness.draw(costMs: 1)
        // Someone else replaced our completion block on that transaction, so
        // it never fires. The transaction ends anyway.
        harness.beginNewTransaction()

        harness.draw(costMs: 1)
        #expect(harness.lines == ["commitdrop draws=2 vis=1"], "the lost cycle's draw count is reported")

        harness.commit(afterMs: 3)
        #expect(harness.lines == [
            "commitdrop draws=2 vis=1",
            "commit draws=1 paints=1 drawms=1.000 commitms=4.000 vis=1 sync=1",
        ])
    }

    @Test("each lost cycle gets its own line, so a windowed reader counts only its window")
    func eachLostCycleIsItsOwnLine() {
        let harness = Harness()
        for _ in 0..<3 {
            harness.draw(costMs: 1)
            harness.beginNewTransaction()
        }
        harness.draw(costMs: 1)
        #expect(harness.lines == ["commitdrop draws=1 vis=1", "commitdrop draws=1 vis=1", "commitdrop draws=1 vis=1"])
    }

    @Test("a late block from an abandoned cycle cannot close the current one")
    func staleBlockIsInert() {
        let harness = Harness()
        harness.draw(costMs: 1)
        let abandoned = harness.registered[0]
        harness.beginNewTransaction()
        harness.draw(costMs: 1)
        harness.lines.removeAll()

        abandoned()
        #expect(harness.lines.isEmpty, "the stale block must not report the new cycle")

        harness.commit(afterMs: 2)
        #expect(harness.lines == ["commit draws=1 paints=1 drawms=1.000 commitms=3.000 vis=1 sync=1"])
    }

    @Test("sync=0 when the completion block missed its runloop turn — the animation case")
    func deferredCompletionIsMarkedUnsynchronized() {
        let harness = Harness()
        harness.draw(costMs: 1)
        // CoreAnimation holds the block while an animation in the transaction
        // runs, so the turn drains first.
        harness.endTurn()
        harness.commit(afterMs: 674)
        #expect(harness.lines == ["commit draws=1 paints=1 drawms=1.000 commitms=675.000 vis=1 sync=0"])
    }

    @Test("a turn-end marker from an already-closed cycle cannot mark a later one")
    func turnEndMarkerIsScopedToItsCycle() {
        let harness = Harness()
        harness.draw(costMs: 1)
        harness.commit(afterMs: 1)
        harness.draw(costMs: 1)
        // The first cycle's marker drains now; it must not touch cycle two.
        harness.fireOldestTurnMarker()
        harness.commit(afterMs: 1)
        #expect(harness.lines.allSatisfy { $0.hasSuffix("sync=1") })
    }

    // MARK: - The real CoreAnimation seam
    //
    // Every other test drives the injected fake, so without these the whole
    // point of the mark/getter mechanism is unpinned: a typo in `markKey` or a
    // change to the NSNumber cast would stay green.

    @Test("the real transaction seam round-trips its mark")
    func coreAnimationSeamRoundTrips() {
        let seam = TerminalCommitLatencyProbe.TransactionSeam.coreAnimation
        CATransaction.begin()
        defer { CATransaction.commit() }
        #expect(seam.mark() == nil, "a fresh transaction carries no mark")
        seam.begin(4242) {}
        #expect(seam.mark() == 4242)
    }

    @Test("the real transaction seam's mark does not survive its transaction")
    func coreAnimationSeamMarkDiesWithTheTransaction() {
        CATransaction.begin()
        TerminalCommitLatencyProbe.TransactionSeam.coreAnimation.begin(7) {}
        CATransaction.commit()
        CATransaction.flush()
        #expect(
            TerminalCommitLatencyProbe.TransactionSeam.coreAnimation.mark() == nil,
            "no mark is exactly how a new transaction is detected"
        )
    }

    @Test("paints=0 distinguishes a draw that painted nothing from an instant paint")
    func drawWithoutPaintIsDistinguishable() {
        let harness = Harness()
        harness.drawWithoutPainting()
        harness.commit(afterMs: 7)
        #expect(harness.lines == ["commit draws=1 paints=0 drawms=0.000 commitms=7.000 vis=1 sync=1"])
    }
}
