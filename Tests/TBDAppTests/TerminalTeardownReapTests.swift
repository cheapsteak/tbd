import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp

/// Tier 2: drives the two terminal coordinators' real `cleanup()` against a
/// real SwiftTerm `LocalProcess` and a real forked child. No tmux server, no
/// daemon, no `~/tbd` — a bare `Coordinator()` with only `localProcess` set
/// takes every other branch of `cleanup()` as a nil no-op.
///
/// **This is the suite that pins the bug.** `ChildReaperTests` proves the
/// helper reaps, but it would stay green if someone deleted the
/// `ChildReaper.reap` call from `cleanup()`. These two tests reproduce the
/// production sequence end to end — spawn a child that will not exit on its
/// own, tear the coordinator down, and require the child to be gone — so they
/// go red if either half of the fix is removed: the reap call itself, or the
/// `localProcess = nil` that makes `LocalProcess.deinit` (and thus the
/// monitor cancellation and fd close) happen at a known moment.
///
/// **Why the default `dispatchQueue` (main) and not an injected background
/// queue.** Production passes none, so `LocalProcess` defaults to
/// `DispatchQueue.main` for both `childMonitor` and the `DispatchIO` cleanup
/// handler; passing a background queue here would test a configuration TBD
/// never uses. That is only sound because this process genuinely drains the
/// main queue (`Tests/CLAUDE.md`), so the monitor is live rather than merely
/// idle — the child outlives the coordinator precisely because `cleanup()`
/// cancels that live monitor, which is the behavior under test.
///
/// **These tests are deliberately NOT `@MainActor`, and each takes exactly one
/// main-actor hop.** They need main only for the steps that are main-isolated
/// — `startProcess` (whose delegate callback asserts main isolation) and
/// `cleanup()` — so each test batches all of those into a single
/// `MainActor.run`, and everything else (every poll, every `waitpid`) happens
/// off it. Both halves were measured under full-suite load: the `@MainActor`
/// version re-acquired main at each of ~200 poll resumptions and blew the 60 s
/// limit on four tests, and a version that merely moved the polls off main but
/// still took four separate hops blew it on two. Main is contended by hundreds
/// of other main-isolated tests in that pass, so the count of hops is the
/// thing to keep small — and never wait for main-queue work while occupying
/// the main queue.
///
/// **How these tests wait: an event, not a window.** `cleanup()` enqueues its
/// reap synchronously onto `ChildReaper`'s concurrent queue, so a barrier
/// submitted after `cleanup()` returns is ordered behind it —
/// `ChildReaper.drainPendingReaps` is that barrier. When it fires, the reap
/// block has *run to completion*, so "the child still exists" means the reap
/// did not reap, full stop. There is no poll anywhere in this suite and
/// therefore no scheduling window to mistake for a bug (nor a bug to mistake
/// for scheduling: a polling test can only report "still there after N tries").
/// The barrier's own cost is bounded by the longest-lived child in the
/// process — see `ChildReaper.drainPendingReaps` for the process-wide caveat.
///
/// **The barrier wait is itself bounded, and by its own guard rather than by
/// the suite limit.** It is ordered behind `waitpid` calls `ChildReaper`
/// documents as unbounded, and neither a parked `waitpid` nor a
/// `withCheckedContinuation` awaiting a callback that never runs can be
/// cancelled by Swift Testing — so an unguarded wait would wedge the run
/// instead of reddening one test, and (a barrier on a concurrent queue blocking
/// everything submitted after it) would take the sibling tests down with it.
/// `drainPendingReaps(within:)` in `ChildReapDrainSupport.swift` races the
/// barrier against a 30 s guard, reports a stuck reap with its observed state,
/// and each call site SIGKILLs and reaps its own child on that path.
///
/// **Why `.timeLimit(.minutes(1))`.** A coarse outer backstop for the ordinary
/// case of a merely slow test — not the guard that catches a stuck reap, which
/// it cannot do (above). Nothing here waits on wall time otherwise, and the
/// honest path completes in well under a second, so a minute leaves the 30 s
/// hang guard room to fire with its diagnostic rather than be truncated, and
/// still spends less than four minutes of a shared box.
///
/// **Probe children are disposed of before anything can fail.** Assertions run
/// last, after every child this suite spawned has been ended and reaped,
/// because a `defer` registered *after* a throwing `#require` never runs at
/// all — and the probes are `sleep 120` that no production path under test
/// ends. Be precise about what that costs, since the sloppy version of this
/// claim is "they orphan to launchd" and they measurably do not: every child
/// here is on a PTY this process owns, and closing the master fd SIGHUPs it
/// (measured directly — the child goes to `Z` within half a second), so
/// process exit collects them all. What a mis-ordered disposal actually leaves
/// is a live `sleep 120` and an unreaped pid for the *rest of the run*, on
/// every failing iteration, in a process that already runs ~4500 tests. That
/// is worth ordering correctly on its own; it is not the launchd-orphan story.
/// (`cleanup()` also appends a line to `/tmp/tbd-bridge.log` via the
/// production `debugLog`; no TBD-owned store is touched.)
@Suite("Terminal teardown reaps its PTY child", .timeLimit(.minutes(1)))
struct TerminalTeardownReapTests {

    /// Everything a one-shot test needs out of its single main-actor hop.
    private struct OneShotRun {
        let first: pid_t
        let probe: pid_t
        let stillHeld: Bool
    }

    private struct ChildSurvivedTeardown: Error, CustomStringConvertible {
        let pid: pid_t
        let state: String
        var description: String {
            "PTY child \(pid) still existed after cleanup() and after ChildReaper's queue "
                + "drained — observed \(state). The barrier means the reap block already ran to "
                + "completion, so teardown either enqueued no reap or reaped nothing; an "
                + "unreaped child is the <defunct> leak this fixes."
        }
    }

    /// `true` while the pid still names a process — running OR an unreaped
    /// zombie. Both are failures after teardown; the message distinguishes them.
    private func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Distinguishes "still running" from "leaked as a zombie" for the
    /// diagnostic, using `WNOWAIT` so the probe does not itself reap.
    private func describeState(_ pid: pid_t) -> String {
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0, info.si_pid == pid {
            return "an unreaped zombie (exited, still waitable)"
        }
        return processExists(pid) ? "a live process (never exited)" : "gone"
    }

    /// Ends and reaps a child that outlived teardown, given the state that was
    /// just observed for it. Only ever called on a failure path: on success the
    /// pid is already freed and signalling it could reach a recycled process.
    ///
    /// **Call only after a `drainPendingReaps` that returned `.drained`** —
    /// committing a `waitpid` while one of `ChildReaper`'s blocks may still be
    /// parked on the same pid is the two-waiter recycling hazard
    /// `ChildReaper`'s doc comment forbids. The stalled-barrier path is the one
    /// exception and is disposed of anyway: the `SIGKILL` keeps this `waitpid`
    /// bounded (an exiting child is either reaped here or returns `ECHILD` at
    /// once), and leaving a live `sleep` plus an unreaped pid behind for the
    /// rest of the run is the worse outcome.
    private func disposeSurvivor(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
        ChildReaper.reapBlocking(pid: pid)
    }

    /// Starts a child on a real `LocalProcess` owned solely by `assign`, and
    /// returns its pid.
    ///
    /// The `LocalProcess` reference lives and dies inside this call: after it
    /// returns, the coordinator's own property is the only strong reference, so
    /// `deinit` fires exactly when `cleanup()` releases it — as in production,
    /// where the coordinator is likewise the only owner.
    /// `@MainActor` because `startProcess` asks the delegate for the window
    /// size, and both coordinators answer inside `MainActor.assumeIsolated` —
    /// which traps off main. Production starts every PTY from a main-isolated
    /// context, so this matches it; only the waiting below happens off main.
    @MainActor
    private func startChild(
        delegate: LocalProcessDelegate, lifetime: String, assign: (LocalProcess) -> Void
    ) -> pid_t {
        let process = LocalProcess(delegate: delegate)
        process.startProcess(
            executable: "/bin/sleep", args: [lifetime], environment: nil, execName: nil)
        assign(process)
        return process.shellPid
    }

    /// The panel path does not itself kill the child, so this test asserts what
    /// the fix actually claims: **a child that exits after teardown is reaped,
    /// not left `<defunct>`.** The child outlives `cleanup()` and then exits on
    /// its own, which is the exact sequence that leaked in the field — by the
    /// time it exits, `cleanup()` has released the `LocalProcess`, and that
    /// deinit cancelled the only monitor that would have `waitpid`ed it.
    ///
    /// Two things this deliberately does NOT assert, both measured here rather
    /// than assumed. Teardown on this path does not reliably *end* the child:
    /// `deinit`'s `io?.close()` is a graceful close, and `startProcess` leaves a
    /// read outstanding, so the cleanup handler that actually closes the master
    /// fd does not run while that read is pending — a silent child never sees
    /// the SIGHUP at all (a `sleep 120` child was still running 5 s after
    /// `cleanup()`). What ends the attach client in production is
    /// `tmuxBridge.cleanupSession`'s `tmux kill-session`, which needs a real
    /// server and belongs to tier 3. Reaping is the part that is ours, and it
    /// is the part under test.
    @Test("an exiting PTY child is reaped by TerminalPanelView teardown, not left <defunct>")
    func panelCleanupReapsChild() async throws {
        let coordinator = TerminalPanelRepresentable.Coordinator()
        // Every main-isolated step in one hop — see the suite comment.
        let pid = await MainActor.run { () -> pid_t in
            // Outlives cleanup(), then exits on its own — see the doc comment.
            let pid = startChild(delegate: coordinator, lifetime: "0.4") {
                coordinator.localProcess = $0
            }
            coordinator.cleanup()
            return pid
        }
        try #require(pid > 0, "forkpty must have produced a child pid")

        try await requireDrainedAndReaped(pid)
    }

    /// Awaits the barrier, then asserts the child is gone. A barrier that did
    /// not fire is its own named failure — reported instead of the reap
    /// assertion, which it would make unsound: with a reap still parked, "the
    /// child is gone" has not been decided yet either way.
    private func requireDrainedAndReaped(_ pid: pid_t) async throws {
        try requireDrained(await drainPendingReaps(), teardownChild: pid)
        try requireReaped(pid)
    }

    /// Throws when the barrier did not fire, disposing of the teardown child
    /// first. Reported ahead of every other assertion in the test, because with
    /// a reap still parked "the child is gone" has not been decided either way
    /// — and a stalled barrier is a harness fact, not a verdict on `cleanup()`.
    private func requireDrained(_ drain: ReapDrainOutcome, teardownChild pid: pid_t) throws {
        guard let diagnostic = drain.diagnostic(pid: pid, observedState: { describeState(pid) })
        else { return }
        // End our own child even though the barrier is wedged: whatever is
        // stuck may never reap it, and a live `sleep` plus an unreaped pid
        // would outlive this test. See `disposeSurvivor`.
        if processExists(pid) { disposeSurvivor(pid) }
        throw diagnostic
    }

    /// Asserts the child is gone, disposing of it first if it is not. Disposal
    /// precedes the throw for the reason the suite comment gives: on a failure
    /// path there is a live child to account for, and nothing that can throw
    /// may sit between observing it and ending it.
    private func requireReaped(_ pid: pid_t) throws {
        guard processExists(pid) else { return }
        let state = describeState(pid)
        disposeSurvivor(pid)
        throw ChildSurvivedTeardown(pid: pid, state: state)
    }

    /// Drops the coordinator's reference to a probe child's `LocalProcess`
    /// (whose deinit cancels its exit monitor, making us the sole waiter), then
    /// kills and reaps it. Probe children are `sleep 120` and nothing in the
    /// production path under test ends them, so every test that starts one must
    /// call this — before any assertion that could throw first.
    ///
    /// The `pid > 0` guard is load-bearing, not defensive: `kill(0, SIGKILL)`
    /// signals the caller's entire process group, i.e. the whole test process.
    private func disposeProbe(pid: pid_t, release: () -> Void) {
        release()
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
        ChildReaper.reapBlocking(pid: pid)
    }

    /// The remote path *does* end its child — `cleanup()` calls
    /// `LocalProcess.terminate()`, which sends SIGTERM — so a long-lived child
    /// is production-faithful here. `terminate()` cancels the exit monitor
    /// (via `childStopped()`) before that signal can land, so the reap is the
    /// only thing standing between this teardown and a permanent zombie.
    @Test("LocalPTYTerminalRepresentable teardown kills AND reaps its child")
    func localPTYCleanupReapsChild() async throws {
        let coordinator = LocalPTYTerminalRepresentable.Coordinator()
        let pid = await MainActor.run { () -> pid_t in
            let pid = startChild(delegate: coordinator, lifetime: "120") {
                coordinator.localProcess = $0
            }
            coordinator.cleanup()
            return pid
        }
        try #require(pid > 0, "forkpty must have produced a child pid")

        try await requireDrainedAndReaped(pid)
    }

    // MARK: - cleanup() is one-shot
    //
    // The `guard !isTornDown` / `guard !tornDown` guards make `cleanup()`
    // idempotent. **What these tests can and cannot pin, stated plainly:** with
    // the current code a second call is *already* harmless without the guard —
    // the first call nils `localProcess`, so the pid capture yields 0 and
    // `shouldReap` rejects it, and every other branch of `cleanup()` is a nil
    // no-op. A test that merely called `cleanup()` twice would therefore stay
    // green with the guard deleted, i.e. pin nothing at all.
    //
    // So these drive the guard's actual semantics — "once torn down, this
    // coordinator does no further teardown work" — by handing it fresh state
    // and requiring the second call to leave that state completely alone.
    // Production never re-assigns a coordinator after dismantle; the fresh
    // `LocalProcess` is a probe for the guard, not an endorsement of reuse.
    // Deleting either guard reds these: the second `cleanup()` releases the
    // probe, and on the remote path SIGTERMs its child as well.

    @Test("a second TerminalPanelView cleanup() tears nothing down")
    func panelCleanupIsOneShot() async throws {
        let coordinator = TerminalPanelRepresentable.Coordinator()
        let run = await MainActor.run { () -> OneShotRun in
            let first = startChild(delegate: coordinator, lifetime: "0.4") {
                coordinator.localProcess = $0
            }
            coordinator.cleanup()
            // Fresh state for the second call to (not) act on.
            let probe = startChild(delegate: coordinator, lifetime: "120") {
                coordinator.localProcess = $0
            }
            coordinator.cleanup()
            return OneShotRun(first: first, probe: probe, stillHeld: coordinator.localProcess != nil)
        }
        // Observe, then dispose, then assert — in that order, with nothing that
        // can throw in between. See the suite comment: a `defer` registered
        // after a throwing `#require` never runs, and the probe is a `sleep 120`.
        let drain = await drainPendingReaps()
        let probeAlive = processExists(run.probe)
        disposeProbe(pid: run.probe) { coordinator.localProcess = nil }
        try requireDrained(drain, teardownChild: run.first)

        try #require(run.first > 0 && run.probe > 0, "forkpty must have produced both pids")
        #expect(run.stillHeld,
                "a second cleanup() must not release state it never set up")
        #expect(probeAlive,
                "a second cleanup() must not reap or signal anything")

        // The real teardown must still have reaped its own child.
        try requireReaped(run.first)
    }

    @Test("a second LocalPTYTerminalRepresentable cleanup() tears nothing down")
    func localPTYCleanupIsOneShot() async throws {
        let coordinator = LocalPTYTerminalRepresentable.Coordinator()
        let run = await MainActor.run { () -> OneShotRun in
            let first = startChild(delegate: coordinator, lifetime: "120") {
                coordinator.localProcess = $0
            }
            coordinator.cleanup()
            let probe = startChild(delegate: coordinator, lifetime: "120") {
                coordinator.localProcess = $0
            }
            coordinator.cleanup()
            return OneShotRun(first: first, probe: probe, stillHeld: coordinator.localProcess != nil)
        }
        // Observe, then dispose, then assert — see the sibling test above.
        let drain = await drainPendingReaps()
        let probeAlive = processExists(run.probe)
        disposeProbe(pid: run.probe) { coordinator.localProcess = nil }
        try requireDrained(drain, teardownChild: run.first)

        try #require(run.first > 0 && run.probe > 0, "forkpty must have produced both pids")
        // Sharper here than on the panel path: without the guard this second
        // call reaches `localProcess?.terminate()`, so the probe would be
        // SIGTERMed as well as released.
        #expect(run.stillHeld,
                "a second cleanup() must not release state it never set up")
        #expect(probeAlive,
                "a second cleanup() must not terminate a process it never started")

        // The real teardown must still have killed and reaped its own child.
        try requireReaped(run.first)
    }
}
