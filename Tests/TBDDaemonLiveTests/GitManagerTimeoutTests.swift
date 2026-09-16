import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// Exercises `GitManager`'s subprocess timeout/kill path (`GitTimeoutError`) via
/// the package-internal `runForTimeoutTesting` seam driven against `/bin/sleep`.
/// A real git hang is not reproducible cross-environment (a post-checkout hook
/// did not fire on CI), which is exactly why the deterministic seam exists.
///
/// **Tier 3** — still spawns real children and drives the real SIGTERM→SIGKILL
/// path; two tests deliberately orphan a backgrounded grandchild. Only the
/// *deadline* is virtual.
///
/// The deadline runs on an injected `EventDrivenTestClock`, so no test here
/// races a real timeout on a loaded runner:
///
/// - Happy-path tests never advance the clock, so the deadline **cannot** fire.
///   Previously they asserted success against a real 3–30 s deadline while the
///   completion path's authoritative `ContinuousClock` check reported `.timedOut`
///   for any call the runner delayed past it — a flake that got wider, not
///   rarer, as CI got busier.
/// - Timeout-path tests advance virtual time at the assertion that needs it.
///
/// The production `SubprocessWatchdog` thread still arms the same deadline in
/// parallel; a 600 s timeout is simply unreachable inside the suite's
/// one-minute limit, so the injected clock is the only armer that can fire here.
/// `SubprocessTimeoutStarvationTests` covers the watchdog on a real clock.
///
/// WHY `EventDrivenTestClock` AND NOT `TestClock`. The clock armer in
/// `runBoundedProcess` is an unstructured `Task` that has to be given a thread
/// before it reaches `clock.sleep`. `TestClock`'s `advanceWhenSuspended` could
/// only observe that arming by polling `checkSuspension()`, each probe a
/// background-QoS megaYield storm, and under CPU saturation the probes starved
/// past the 45 s guard while the real `/bin/sleep 30` child finished on its own
/// — the call then returned `""` instead of throwing, and the test sat at the
/// suite limit (1–3 of 10 targeted stress iterations, #503). The event-driven
/// clock signals the waiter from inside the same critical section that registers
/// the sleeper, so there is no probe to starve: the wait ends the instant the
/// deadline task reaches its sleep, however long the scheduler took to get it
/// there.
///
/// The timeout-path tests use the **strict** wait, `requireAdvanceWhenArmed`,
/// rather than the soft `advanceWhenArmed`. The soft form records a missed
/// arming and then advances an empty ledger, after which the next statement
/// awaits the call — which is a real `sleep 30` or `exec sleep 120` child, so a
/// miss would surface as a 30 s stall or a bare suite time limit rather than as
/// the named `NoSleeperArmed` diagnostic. The strict form throws at the miss
/// before virtual time moves, and the `defer` cancels the call so the
/// cancellation relay kills the child instead of leaving it to run out.
///
/// WHY AN EXPLICIT `.timeLimit(.minutes(1))` AND NOT `.clockDriven`. Do not
/// "tidy" this back to the shared trait — the two halves below are why.
///
/// 1. **60 s is this suite's detector, not a hang guard.**
///    `timeoutThrowsPromptlyWhenGrandchildHoldsPipeOpen` and
///    `returnsOutputWithoutWaitingForGrandchildEOF` prove promptness
///    *structurally*: their grandchildren hold the pipe write ends open for 120 s
///    and 30 s of REAL time, and the only thing that distinguishes "returned
///    without waiting for EOF" from "regressed into an EOF-waiting drain" is that
///    the latter blocks past the limit. At 240 s a regressed 120 s drain finishes
///    inside the budget and the test goes green — mutation-verified proof,
///    silently disarmed, with nothing going red to tell you.
/// 2. **It does not need the raised budget.** `.clockDriven` was raised to
///    4 minutes to absorb the arming latency of the fast parallel pass, whose
///    ~4536-test population is what makes a clock handshake take tens of
///    seconds. This is tier 3: CI runs `Tests/TBDDaemonLiveTests` as
///    `--filter '^TBDDaemonLiveTests\.' --no-parallel` on an otherwise-idle
///    machine, so real arming latency here is milliseconds.
///
/// One residual, stated rather than glossed: the arming hang guard is 45 s, so
/// a test that waited **twice** would need 90 s and would trip this 60 s limit.
/// No test here chains two — the suite's two `requireAdvanceWhenArmed` sites
/// are in different `@Test`s, one each — and in the quiet pass a healthy
/// handshake returns in milliseconds, so only a genuine miss ever pays the
/// guard, and it reports as a named diagnostic 15 s before the limit would have
/// cut it off unattributed. The guard deliberately stays at its 45 s default
/// rather than `TestDeadlines.saturatedPass` (90 s), which the fast pass uses for
/// arming behind an unstructured task: here 90 s sits past the suite limit, so
/// the diagnostic could never be reached, and the latency it is sized for does
/// not occur in the quiet pass.
@Suite(.timeLimit(.minutes(1)))
struct GitManagerTimeoutTests {

    /// Far enough out that the real watchdog cannot reach it inside the suite's
    /// one-minute hang limit, so only the injected clock can fire the deadline.
    private static let unreachableTimeout: Duration = .seconds(600)

    private static var tmp: String { FileManager.default.temporaryDirectory.path }

    @Test func subprocessTimeoutThrowsGitTimeoutError() async throws {
        let clock = EventDrivenTestClock()
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: clock)
        let call = Task {
            try await git.runForTimeoutTesting(
                executable: "/bin/sleep",
                arguments: ["30"],
                at: Self.tmp
            )
        }
        // A no-op once the call has resolved; on a thrown arming miss it fires
        // the cancellation relay, which kills the child rather than orphaning it.
        defer { call.cancel() }
        try await clock.requireAdvanceWhenArmed(by: Self.unreachableTimeout)
        await #expect(throws: GitTimeoutError.self) { try await call.value }
    }

    @Test func fastCommandSucceedsWithinTimeout() async throws {
        // The timeout wrapper must not break the happy path (regression guard
        // for the kill/continuation plumbing). Clock never advances, so the
        // deadline is unreachable no matter how slow the runner is.
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: EventDrivenTestClock())
        let out = try await git.runForTimeoutTesting(
            executable: "/bin/echo",
            arguments: ["ok"],
            at: Self.tmp
        )
        #expect(out.contains("ok"))
    }

    @Test func runDrainsStdoutLargerThanPipeBuffer() async throws {
        // A macOS pipe buffer is 64KB. If stdout were read only after the child
        // exited (the naive waitUntilExit-then-read shape that deadlocked the
        // hibernate-path `ps` call, fixed for TmuxManager in f1d67f44), a child
        // emitting more would block writing to the full pipe, never exit, and
        // surface as a spurious GitTimeoutError. `GitManager.run` drains
        // incrementally via readabilityHandler + PipeDataAccumulator; lock down
        // that a 100KB emitter completes and returns its FULL output (no dropped
        // trailing chunk). A deadlocked drain now hangs into the suite's time
        // limit rather than being masked as a timeout.
        let bytes = 102_400
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: EventDrivenTestClock())
        let out = try await git.runForTimeoutTesting(
            executable: "/bin/sh",
            arguments: ["-c", "yes x | head -c \(bytes)"],
            at: Self.tmp
        )
        #expect(out.utf8.count == bytes)
    }

    @Test func runDrainsStderrLargerThanPipeBuffer() async throws {
        // Same deadlock class, stderr side: a failing command emitting >64KB of
        // diagnostics must exit and surface as GitError (with the full stderr),
        // not wedge on a full pipe until the deadline fires.
        let bytes = 102_400
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: EventDrivenTestClock())
        do {
            _ = try await git.runForTimeoutTesting(
                executable: "/bin/sh",
                arguments: ["-c", "yes e | head -c \(bytes) >&2; exit 3"],
                at: Self.tmp
            )
            Issue.record("expected GitError for non-zero exit")
        } catch let error as GitError {
            #expect(error.exitCode == 3)
            #expect(error.stderr.utf8.count == bytes)
        }
    }

    @Test func timeoutThrowsPromptlyWhenGrandchildHoldsPipeOpen() async throws {
        // The deadline kills only the DIRECT child (SIGTERM→SIGKILL); a
        // backgrounded grandchild inherits the pipe write ends and keeps them
        // open for 120s, so EOF never arrives before it exits. The timeout path
        // must nil the readability handlers AND finish() both accumulators
        // (closing the parent read ends) so nothing waits for — or stays open
        // until — the grandchild's EOF.
        //
        // The promptness proof is now structural rather than a tolerance: the
        // call resolves after 600 VIRTUAL seconds while the grandchild holds the
        // pipe for 120 REAL ones, so returning at all proves nothing waited for
        // EOF. A regressed EOF-waiting drain would block ~120 real seconds and
        // trip the suite's 60 s limit. This replaces a wall-clock upper
        // bound that had been RAISED TWICE after measured breaches
        // (4s → 15s → 60s, the last at 19.4s on a 2-core runner) — tolerance
        // widening is the flake shape hygiene rule 2 exists to forbid.
        //
        // The plain `sleep 120 &` grandchild is NOT killed and may linger up to
        // 120s after the suite — harmless orphanage locally, irrelevant on
        // ephemeral CI runners.
        let clock = EventDrivenTestClock()
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: clock)
        let call = Task {
            try await git.runForTimeoutTesting(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 120 & exec sleep 120"],
                at: Self.tmp
            )
        }
        // Same as above: inert after the call resolves, and on an arming miss it
        // kills the direct child so a thrown diagnostic does not leave a 120 s
        // `exec sleep` running under the test process.
        defer { call.cancel() }
        try await clock.requireAdvanceWhenArmed(by: Self.unreachableTimeout)
        await #expect(throws: GitTimeoutError.self) { try await call.value }
    }

    @Test func returnsOutputWithoutWaitingForGrandchildEOF() async throws {
        // Termination-path variant: the direct child exits immediately and
        // successfully while its backgrounded grandchild holds the pipe write
        // end for 30s. The call must return the child's output right away — a
        // drain that waits for pipe EOF stalls until the grandchild exits.
        // Previously that surfaced as a spurious GitTimeoutError (timeout 3s <<
        // grandchild 30s); with the deadline virtual and never advanced, a
        // regression can only present as a hang caught by the suite's limit, and
        // the 3 s margin that a loaded runner could blow is gone. The
        // `sleep 30 &` grandchild may linger up to 30s — tolerable orphanage.
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: EventDrivenTestClock())
        let out = try await git.runForTimeoutTesting(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo hi"],
            at: Self.tmp
        )
        #expect(out == "hi\n")
    }
}
