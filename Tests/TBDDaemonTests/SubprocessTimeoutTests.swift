import Foundation
import Testing
@testable import TBDDaemonLib

/// Covers the wake-hang fix's core mechanism: an external subprocess that never
/// returns must be killed and the call must throw a timeout error FAST, rather
/// than hanging the RPC to the app's 300s ceiling. Drives the package-internal
/// `runExternalCommand` seam against `/bin/sleep` so no tmux server is needed.
@Suite("Subprocess timeout / kill path")
struct SubprocessTimeoutTests {
    @Test func runExternalCommandThrowsTimedOutOnSlowBinary() async {
        // Assert the OUTCOME (throws .timedOut), never wall-clock timing — a
        // loaded CI runner can be arbitrarily slow to schedule the kill, and a
        // timing bound would flake. The `sleep 30` guarantees the child never
        // finishes on its own, so a thrown error can only mean the timeout fired.
        do {
            _ = try await TmuxManager.runExternalCommand(
                executable: "/bin/sleep",
                arguments: ["30"],
                label: "timeout-test",
                timeout: .milliseconds(100)
            )
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
        // that a 100KB emitter completes and returns its FULL output.
        let bytes = 102_400
        let out = try await TmuxManager.runExternalCommand(
            executable: "/bin/sh",
            arguments: ["-c", "yes x | head -c \(bytes)"],
            label: "big-output-test",
            timeout: .seconds(10)
        )
        #expect(out.utf8.count == bytes)
    }

    @Test func runExternalCommandTimesOutPromptlyWhenGrandchildHoldsPipeOpen() async {
        // Real call sites run `[shell, "-ic", cmd]`, and rc files can fork
        // background children that inherit the pipe write ends. The watchdog
        // kills only the DIRECT child, so EOF never arrives on the pipes. The
        // old blocking `readDataToEndOfFile` drain leaked two parked
        // global-queue threads + two pipe FDs (+ retained closures) per
        // timed-out call. Shape: the parent execs into a sleep that the 1s
        // timeout kills (SIGTERM→SIGKILL; the SIGKILLed direct child dies at
        // ~timeout+500ms), while a backgrounded grandchild keeps the write end
        // open for 120s. The call must throw .timedOut around the timeout, not
        // wait anywhere near the grandchild's EOF.
        //
        // The plain `sleep 120 &` grandchild is NOT killed by the watchdog and
        // may linger up to 120s after the suite — harmless orphanage locally
        // (it holds no resources beyond a PID), irrelevant on ephemeral CI
        // runners.
        let start = ContinuousClock.now
        do {
            _ = try await TmuxManager.runExternalCommand(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 120 & echo hi; exec sleep 120"],
                label: "grandchild-pipe-timeout-test",
                timeout: .seconds(1)
            )
            Issue.record("expected runExternalCommand to time out, but it returned")
        } catch let error as TmuxError {
            guard case .timedOut = error else {
                Issue.record("expected TmuxError.timedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("expected TmuxError.timedOut, got \(error)")
        }
        // Generous bound (1s timeout vs 120s grandchild): finishing under 60s
        // proves nothing waited for the grandchild to release the write end.
        // Sized from measured breaches under contention: 4.676s locally (old
        // 4s bound), then 19.249s on a 2-core CI runner under full-suite
        // parallel load (old 15s bound). 60s gives ~3x headroom over the CI
        // worst case, while a regressed EOF-waiting implementation would take
        // the full 120s and fail unambiguously.
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    @Test func runExternalCommandReturnsWithoutWaitingForGrandchildEOF() async throws {
        // Termination-path variant: the direct child exits IMMEDIATELY (and
        // successfully) while its backgrounded grandchild holds the pipe write
        // end for 30s. The call must return the child's output right away — a
        // drain that waits for pipe EOF stalls until the grandchild exits,
        // which with the old shape surfaced as a spurious .timedOut here
        // (timeout 3s << grandchild 30s). Outcome-based: success discriminates
        // old from new without asserting wall-clock timing. The `sleep 30 &`
        // grandchild may linger up to 30s after the suite — tolerable orphanage.
        let out = try await TmuxManager.runExternalCommand(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo hi"],
            label: "grandchild-pipe-eof-test",
            timeout: .seconds(3)
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
            timeout: .seconds(5)
        )
        #expect(out.contains("ok"))
    }
}
