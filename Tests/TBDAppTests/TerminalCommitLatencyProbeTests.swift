import Foundation
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

    /// Drives the probe with a hand-cranked clock and a captured completion
    /// block, so a display cycle can be replayed deterministically.
    @MainActor
    private final class Harness {
        var now: Double = 0
        var lines: [String] = []
        /// Blocks handed to `registerCommitCompletion`, in registration order.
        var registered: [@Sendable () -> Void] = []
        private(set) var probe: TerminalCommitLatencyProbe!

        init() {
            probe = TerminalCommitLatencyProbe(
                now: { [unowned self] in self.now },
                registerCommitCompletion: { [unowned self] block in self.registered.append(block) },
                emit: { [unowned self] line in self.lines.append(line) }
            )
        }

        /// One terminal view about to draw, then that draw finishing `costMs`
        /// later — the `viewWillDraw` / `onFramePresented` pair.
        func draw(costMs: Double, isOnScreen: Bool = true) {
            probe.recordDrawWillBegin(at: now, isOnScreen: isOnScreen)
            now += costMs / 1000
            probe.recordFramePresented(at: now)
        }

        /// Fire the most recently registered completion block, as CoreAnimation
        /// would once the render server has committed.
        func commit(afterMs: Double) {
            now += afterMs / 1000
            registered.last?()
        }
    }

    private func withIsolatedDefaults(
        seed: Bool?,
        _ body: (UserDefaults) -> Void
    ) {
        let suiteName = "TBDAppTests.CommitLatency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        #expect(harness.lines == ["commit draws=1 drawms=2.000 commitms=10.000 vis=1"])
    }

    @Test("several views drawing in one cycle produce ONE line, not one per view")
    func multipleDrawsInOneCycle() {
        let harness = Harness()
        harness.draw(costMs: 1)
        harness.draw(costMs: 2)
        harness.draw(costMs: 3)
        #expect(harness.registered.count == 1, "exactly one completion block per transaction")
        harness.commit(afterMs: 4)
        #expect(harness.lines == ["commit draws=3 drawms=6.000 commitms=10.000 vis=1"])
    }

    @Test("vis=0 only when every view in the cycle was off screen")
    func visibilityIsPerCycle() {
        let offscreen = Harness()
        offscreen.draw(costMs: 1, isOnScreen: false)
        offscreen.commit(afterMs: 1)
        #expect(offscreen.lines.first?.hasSuffix("vis=0") == true)

        let mixed = Harness()
        mixed.draw(costMs: 1, isOnScreen: false)
        mixed.draw(costMs: 1, isOnScreen: true)
        mixed.commit(afterMs: 1)
        #expect(mixed.lines.first?.hasSuffix("vis=1") == true)
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
            "commit draws=1 drawms=1.000 commitms=5.000 vis=1",
            "commit draws=1 drawms=2.000 commitms=22.000 vis=1",
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
        #expect(harness.lines == ["commit draws=1 drawms=1.000 commitms=2.000 vis=1"])
    }

    @Test("a swallowed completion block is dropped, not wedged forever")
    func staleCycleIsAbandoned() {
        let harness = Harness()
        harness.draw(costMs: 1)
        // Someone else set their own completion block on that transaction, so
        // ours never fires. The next draw arrives well past the stale window.
        harness.now += TerminalCommitLatencyProbe.staleCycleSeconds + 0.1
        harness.draw(costMs: 1)
        #expect(harness.lines == ["commitdrop cycles=1"])
        harness.commit(afterMs: 3)
        #expect(harness.lines == [
            "commitdrop cycles=1",
            "commit draws=1 drawms=1.000 commitms=4.000 vis=1",
        ])
    }

    @Test("a late block from an abandoned cycle cannot close the current one")
    func staleBlockIsInert() {
        let harness = Harness()
        harness.draw(costMs: 1)
        let abandoned = harness.registered[0]
        harness.now += TerminalCommitLatencyProbe.staleCycleSeconds + 0.1
        harness.draw(costMs: 1)
        harness.lines.removeAll()

        abandoned()
        #expect(harness.lines.isEmpty, "the stale block must not report the new cycle")

        harness.commit(afterMs: 2)
        #expect(harness.lines == ["commit draws=1 drawms=1.000 commitms=3.000 vis=1"])
    }
}
