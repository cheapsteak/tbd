import Clocks
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
/// The deadline runs on an injected `TestClock`, so no test here races a real
/// timeout on a loaded runner:
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
///    ~4536-test population is what makes a `TestClock` handshake take tens of
///    seconds. This is tier 3: CI runs `Tests/TBDDaemonLiveTests` as
///    `--filter '^TBDDaemonLiveTests\.' --no-parallel` on an otherwise-idle
///    machine, so real arming latency here is milliseconds.
///
/// One residual, stated rather than glossed: `waitForSuspension`'s default is
/// now 45 s, so a test that waited **twice** would need 90 s and would trip this
/// 60 s limit, where at the old 15 s default two waits cost only 30 s. No test
/// here chains two — the suite's two `advanceWhenSuspended` sites are in
/// different `@Test`s, one each — and in the quiet pass a healthy handshake
/// returns in milliseconds, so only a genuine hang ever pays the timeout, which
/// is exactly what this limit is here to catch.
@Suite(.timeLimit(.minutes(1)))
struct GitManagerTimeoutTests {

    /// Far enough out that the real watchdog cannot reach it inside the suite's
    /// one-minute hang limit, so only the `TestClock` can fire the deadline.
    private static let unreachableTimeout: Duration = .seconds(600)

    private static var tmp: String { FileManager.default.temporaryDirectory.path }

    @Test func subprocessTimeoutThrowsGitTimeoutError() async {
        let clock = TestClock()
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: clock)
        let call = Task {
            try await git.runForTimeoutTesting(
                executable: "/bin/sleep",
                arguments: ["30"],
                at: Self.tmp
            )
        }
        await clock.advanceWhenSuspended(by: Self.unreachableTimeout)
        await #expect(throws: GitTimeoutError.self) { try await call.value }
    }

    @Test func fastCommandSucceedsWithinTimeout() async throws {
        // The timeout wrapper must not break the happy path (regression guard
        // for the kill/continuation plumbing). Clock never advances, so the
        // deadline is unreachable no matter how slow the runner is.
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: TestClock())
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
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: TestClock())
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
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: TestClock())
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

    @Test func timeoutThrowsPromptlyWhenGrandchildHoldsPipeOpen() async {
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
        let clock = TestClock()
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: clock)
        let call = Task {
            try await git.runForTimeoutTesting(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 120 & exec sleep 120"],
                at: Self.tmp
            )
        }
        await clock.advanceWhenSuspended(by: Self.unreachableTimeout)
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
        let git = GitManager(subprocessTimeout: Self.unreachableTimeout, clock: TestClock())
        let out = try await git.runForTimeoutTesting(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo hi"],
            at: Self.tmp
        )
        #expect(out == "hi\n")
    }
}
