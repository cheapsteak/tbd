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
/// main queue (`Tests/CLAUDE.md`, "@MainActor tests: suspend to drain"), so the
/// monitor is live rather than merely idle — the child outlives the coordinator
/// precisely because `cleanup()` cancels that live monitor, which is the
/// behavior under test. The consequence is a discipline these tests must keep:
/// **suspend, never block, on the main actor.** The fd close that ends the
/// child is itself a main-queue block, so a synchronous wait here would
/// deadlock against the very work it is waiting for. Every wait below is an
/// `await`.
///
/// Bounded by construction: each test polls against a 5 s cap and force-kills
/// its child in a `defer`, so nothing can park on a `waitpid` that never
/// returns. (`cleanup()` also appends a line to `/tmp/tbd-bridge.log` via the
/// production `debugLog`; no TBD-owned store is touched.)
@MainActor
@Suite("Terminal teardown reaps its PTY child", .timeLimit(.minutes(1)))
struct TerminalTeardownReapTests {

    private struct ChildSurvivedTeardown: Error, CustomStringConvertible {
        let pid: pid_t
        let polls: Int
        let state: String
        var description: String {
            "PTY child \(pid) still existed \(polls) polls after cleanup() — observed \(state). "
                + "Teardown must reap it; an unreaped child is the <defunct> leak this fixes."
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

    /// Polls for the child to disappear entirely. Suspends between checks so
    /// the main queue keeps draining — see the suite comment.
    private func waitForChildToVanish(_ pid: pid_t) async -> Bool {
        var polls = 0
        while processExists(pid), polls < 200 {
            polls += 1
            try? await Task.sleep(for: .milliseconds(25))
        }
        if processExists(pid) {
            Issue.record(ChildSurvivedTeardown(pid: pid, polls: polls, state: describeState(pid)))
            return false
        }
        return true
    }

    /// Starts a child on a real `LocalProcess` owned solely by `assign`, and
    /// returns its pid.
    ///
    /// The `LocalProcess` reference lives and dies inside this call: after it
    /// returns, the coordinator's own property is the only strong reference, so
    /// `deinit` fires exactly when `cleanup()` releases it — as in production,
    /// where the coordinator is likewise the only owner.
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
        // Outlives cleanup(), then exits on its own — see the doc comment.
        let pid = startChild(delegate: coordinator, lifetime: "0.4") { coordinator.localProcess = $0 }
        try #require(pid > 0, "forkpty must have produced a child pid")

        var reaped = false
        defer {
            // Safety net for the failure path only: on success the pid is
            // already freed and signalling it could reach a recycled process.
            if !reaped {
                kill(pid, SIGKILL)
                ChildReaper.reapBlocking(pid: pid)
            }
        }

        coordinator.cleanup()

        reaped = await waitForChildToVanish(pid)
        #expect(reaped)
    }

    /// Drops the coordinator's reference to a probe child's `LocalProcess`
    /// (whose deinit cancels its exit monitor, making us the sole waiter), then
    /// kills and reaps it. Probe children outlive their test by design, so
    /// every test that starts one must call this.
    private func disposeProbe(pid: pid_t, release: () -> Void) {
        release()
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
        let pid = startChild(delegate: coordinator, lifetime: "120") { coordinator.localProcess = $0 }
        try #require(pid > 0, "forkpty must have produced a child pid")

        var reaped = false
        defer {
            if !reaped {
                kill(pid, SIGKILL)
                ChildReaper.reapBlocking(pid: pid)
            }
        }

        coordinator.cleanup()

        reaped = await waitForChildToVanish(pid)
        #expect(reaped)
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
        let firstPid = startChild(delegate: coordinator, lifetime: "0.4") {
            coordinator.localProcess = $0
        }
        try #require(firstPid > 0, "forkpty must have produced a child pid")

        var firstReaped = false
        defer {
            if !firstReaped {
                kill(firstPid, SIGKILL)
                ChildReaper.reapBlocking(pid: firstPid)
            }
        }

        coordinator.cleanup()
        firstReaped = await waitForChildToVanish(firstPid)
        try #require(firstReaped, "the first teardown must reap its child")

        let probePid = startChild(delegate: coordinator, lifetime: "120") {
            coordinator.localProcess = $0
        }
        try #require(probePid > 0, "forkpty must have produced a probe pid")
        defer { disposeProbe(pid: probePid) { coordinator.localProcess = nil } }

        coordinator.cleanup()

        #expect(coordinator.localProcess != nil,
                "a second cleanup() must not release state it never set up")
        #expect(processExists(probePid),
                "a second cleanup() must not reap or signal anything")
    }

    @Test("a second LocalPTYTerminalRepresentable cleanup() tears nothing down")
    func localPTYCleanupIsOneShot() async throws {
        let coordinator = LocalPTYTerminalRepresentable.Coordinator()
        let firstPid = startChild(delegate: coordinator, lifetime: "120") {
            coordinator.localProcess = $0
        }
        try #require(firstPid > 0, "forkpty must have produced a child pid")

        var firstReaped = false
        defer {
            if !firstReaped {
                kill(firstPid, SIGKILL)
                ChildReaper.reapBlocking(pid: firstPid)
            }
        }

        coordinator.cleanup()
        firstReaped = await waitForChildToVanish(firstPid)
        try #require(firstReaped, "the first teardown must kill and reap its child")

        let probePid = startChild(delegate: coordinator, lifetime: "120") {
            coordinator.localProcess = $0
        }
        try #require(probePid > 0, "forkpty must have produced a probe pid")
        defer { disposeProbe(pid: probePid) { coordinator.localProcess = nil } }

        coordinator.cleanup()

        // Sharper here than on the panel path: without the guard this second
        // call reaches `localProcess?.terminate()`, so the probe would be
        // SIGTERMed as well as released.
        #expect(coordinator.localProcess != nil,
                "a second cleanup() must not release state it never set up")
        #expect(processExists(probePid),
                "a second cleanup() must not terminate a process it never started")
    }
}
