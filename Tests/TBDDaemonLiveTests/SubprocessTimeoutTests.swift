import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// Covers the wake-hang fix's core mechanism: an external subprocess that never
/// returns must be killed and the call must throw a timeout error, rather than
/// hanging the RPC to the app's 300s ceiling. Drives the package-internal
/// `runExternalCommand` seam against `/bin/sleep` so no tmux server is needed.
///
/// **Tier 3** — still spawns real children and drives the real SIGTERM→SIGKILL
/// path; two tests deliberately orphan a backgrounded grandchild. Only the
/// *deadline* is virtual. See `GitManagerTimeoutTests` for the full rationale;
/// both suites map the same `runBoundedProcess` machinery to different error
/// types, and `SubprocessTimeoutStarvationTests` covers the production
/// `SubprocessWatchdog` on a real clock.
///
/// WHY AN EXPLICIT `.timeLimit(.minutes(1))` AND NOT `.clockDriven`. Do not
/// "tidy" this back to the shared trait — the two halves below are why.
///
/// 1. **60 s is this suite's detector, not a hang guard.**
///    `runExternalCommandTimesOutPromptlyWhenGrandchildHoldsPipeOpen` and
///    `runExternalCommandReturnsWithoutWaitingForGrandchildEOF` prove promptness
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
@Suite("Subprocess timeout / kill path", .timeLimit(.minutes(1)))
struct SubprocessTimeoutTests {

    /// Far enough out that the real watchdog cannot reach it inside the suite's
    /// one-minute hang limit, so only the `TestClock` can fire the deadline.
    private static let unreachableTimeout: Duration = .seconds(600)

    @Test func runExternalCommandThrowsTimedOutOnSlowBinary() async {
        // Assert the OUTCOME (throws .timedOut), never wall-clock timing. The
        // `sleep 30` guarantees the child never finishes on its own, so a thrown
        // error can only mean the deadline fired — and the deadline now fires
        // because this test advanced virtual time, not because the runner
        // happened to be fast enough.
        let clock = TestClock()
        let call = Task {
            try await TmuxManager.runExternalCommand(
                executable: "/bin/sleep",
                arguments: ["30"],
                label: "timeout-test",
                timeout: Self.unreachableTimeout,
                clock: clock
            )
        }
        await clock.advanceWhenSuspended(by: Self.unreachableTimeout)
        do {
            _ = try await call.value
            Issue.record("expected runExternalCommand to time out, but it returned")
        } catch let error as TmuxError {
            guard case .timedOut = error else {
                Issue.record("expected TmuxError.timedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("expected TmuxError.timedOut, got \(error)")
        }
    }

    @Test func runExternalCommandDrainsOutputLargerThanPipeBuffer() async throws {
        // A macOS pipe buffer is 64KB. Before stdout was drained concurrently
        // with the child, a command emitting more (e.g. `ps -Ao` with ~900+
        // processes) blocked writing to the full pipe while the caller waited
        // for exit — mutual deadlock, resolved only by the timeout (or, at the
        // original detectOrphanedClaudeProcesses call site, never). Lock down
        // that a 100KB emitter completes and returns its FULL output. With the
        // deadline virtual and never advanced, a regression presents as a hang
        // caught by the suite's limit instead of being masked as a timeout.
        let bytes = 102_400
        let out = try await TmuxManager.runExternalCommand(
            executable: "/bin/sh",
            arguments: ["-c", "yes x | head -c \(bytes)"],
            label: "big-output-test",
            timeout: Self.unreachableTimeout,
            clock: TestClock()
        )
        #expect(out.utf8.count == bytes)
    }

    @Test func runExternalCommandTimesOutPromptlyWhenGrandchildHoldsPipeOpen() async {
        // Real call sites run `[shell, "-ic", cmd]`, and rc files can fork
        // background children that inherit the pipe write ends. The deadline
        // kills only the DIRECT child, so EOF never arrives on the pipes. The
        // old blocking `readDataToEndOfFile` drain leaked two parked
        // global-queue threads + two pipe FDs (+ retained closures) per
        // timed-out call.
        //
        // The promptness proof is structural rather than a tolerance: the call
        // resolves after 600 VIRTUAL seconds while the grandchild holds the pipe
        // for 120 REAL ones, so returning at all proves nothing waited for EOF.
        // A regressed EOF-waiting drain would block ~120 real seconds and trip
        // the suite's 60 s limit. This replaces a wall-clock upper bound
        // RAISED TWICE after measured breaches (4s → 15s → 60s, the last at
        // 19.2s on a 2-core runner) — the tolerance-widening shape hygiene rule
        // 2 forbids.
        //
        // The plain `sleep 120 &` grandchild is NOT killed and may linger up to
        // 120s after the suite — harmless orphanage locally, irrelevant on
        // ephemeral CI runners.
        let clock = TestClock()
        let call = Task {
            try await TmuxManager.runExternalCommand(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 120 & echo hi; exec sleep 120"],
                label: "grandchild-pipe-timeout-test",
                timeout: Self.unreachableTimeout,
                clock: clock
            )
        }
        await clock.advanceWhenSuspended(by: Self.unreachableTimeout)
        do {
            _ = try await call.value
            Issue.record("expected runExternalCommand to time out, but it returned")
        } catch let error as TmuxError {
            guard case .timedOut = error else {
                Issue.record("expected TmuxError.timedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("expected TmuxError.timedOut, got \(error)")
        }
    }

    @Test func runExternalCommandReturnsWithoutWaitingForGrandchildEOF() async throws {
        // Termination-path variant: the direct child exits IMMEDIATELY (and
        // successfully) while its backgrounded grandchild holds the pipe write
        // end for 30s. The call must return the child's output right away — a
        // drain that waits for pipe EOF stalls until the grandchild exits, which
        // with the old shape surfaced as a spurious .timedOut (timeout 3s <<
        // grandchild 30s). That 3 s margin was the thinnest in the suite and the
        // likeliest to be blown by a loaded runner; with the deadline virtual and
        // never advanced there is no margin left to blow. The `sleep 30 &`
        // grandchild may linger up to 30s — tolerable orphanage.
        let out = try await TmuxManager.runExternalCommand(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo hi"],
            label: "grandchild-pipe-eof-test",
            timeout: Self.unreachableTimeout,
            clock: TestClock()
        )
        #expect(out == "hi\n")
    }

    @Test func runExternalCommandSucceedsWellWithinTimeout() async throws {
        // A fast binary returns normally — the timeout wrapper must not break the
        // happy path (regression guard for the kill/continuation plumbing).
        let out = try await TmuxManager.runExternalCommand(
            executable: "/bin/echo",
            arguments: ["ok"],
            label: "fast",
            timeout: Self.unreachableTimeout,
            clock: TestClock()
        )
        #expect(out.contains("ok"))
    }
}
