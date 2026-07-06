import Foundation
import Testing
@testable import TBDDaemonLib

/// Exercises `GitManager`'s subprocess timeout/kill path (`GitTimeoutError`) via
/// the package-internal `runForTimeoutTesting` seam driven against `/bin/sleep`.
/// Asserts the OUTCOME (an error is thrown), never tight timing — CI runners
/// can be pathologically slow, so wall-clock bounds appear only where the
/// bound itself is the regression signal, and generously. A real git hang is
/// not reproducible cross-environment (a post-checkout hook did not fire on CI),
/// which is exactly why the deterministic seam exists.
struct GitManagerTimeoutTests {
    @Test func subprocessTimeoutThrowsGitTimeoutError() async {
        let git = GitManager(subprocessTimeout: .milliseconds(100))
        await #expect(throws: GitTimeoutError.self) {
            _ = try await git.runForTimeoutTesting(
                executable: "/bin/sleep",
                arguments: ["30"],
                at: FileManager.default.temporaryDirectory.path
            )
        }
    }

    @Test func fastCommandSucceedsWithinTimeout() async throws {
        // The timeout wrapper must not break the happy path.
        let git = GitManager(subprocessTimeout: .seconds(30))
        let out = try await git.runForTimeoutTesting(
            executable: "/bin/echo",
            arguments: ["ok"],
            at: FileManager.default.temporaryDirectory.path
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
        // that a 100KB emitter completes well within the timeout and returns
        // its FULL output (no dropped trailing chunk).
        let bytes = 102_400
        let git = GitManager(subprocessTimeout: .seconds(10))
        let out = try await git.runForTimeoutTesting(
            executable: "/bin/sh",
            arguments: ["-c", "yes x | head -c \(bytes)"],
            at: FileManager.default.temporaryDirectory.path
        )
        #expect(out.utf8.count == bytes)
    }

    @Test func runDrainsStderrLargerThanPipeBuffer() async throws {
        // Same deadlock class, stderr side: a failing command emitting >64KB of
        // diagnostics must exit and surface as GitError (with the full stderr),
        // not wedge on a full pipe until the watchdog fires.
        let bytes = 102_400
        let git = GitManager(subprocessTimeout: .seconds(10))
        do {
            _ = try await git.runForTimeoutTesting(
                executable: "/bin/sh",
                arguments: ["-c", "yes e | head -c \(bytes) >&2; exit 3"],
                at: FileManager.default.temporaryDirectory.path
            )
            Issue.record("expected GitError for non-zero exit")
        } catch let error as GitError {
            #expect(error.exitCode == 3)
            #expect(error.stderr.utf8.count == bytes)
        }
    }

    @Test func timeoutThrowsPromptlyWhenGrandchildHoldsPipeOpen() async {
        // Mirrors SubprocessTimeoutTests: the watchdog kills only the DIRECT
        // child (SIGTERM→SIGKILL); a backgrounded grandchild inherits the pipe
        // write ends and keeps them open for 120s, so EOF never arrives before
        // it exits. The timer path must nil the readability handlers AND
        // finish() both accumulators (closing the parent read ends) so nothing
        // waits for — or stays open until — the grandchild's EOF. Shape:
        // parent execs into a sleep the 1s timeout kills (the SIGKILLed direct
        // child dies at ~timeout+500ms); grandchild sleeps 120s. The plain
        // `sleep 120 &` grandchild is NOT killed and may linger up to 120s
        // after the suite — harmless orphanage locally, irrelevant on
        // ephemeral CI runners.
        let git = GitManager(subprocessTimeout: .seconds(1))
        let start = ContinuousClock.now
        do {
            _ = try await git.runForTimeoutTesting(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 120 & exec sleep 120"],
                at: FileManager.default.temporaryDirectory.path
            )
            Issue.record("expected runForTimeoutTesting to time out, but it returned")
        } catch is GitTimeoutError {
            // expected
        } catch {
            Issue.record("expected GitTimeoutError, got \(error)")
        }
        // Generous bound (1s timeout vs 120s grandchild): finishing under 60s
        // proves nothing waited for the grandchild to release the write end.
        // Sized from measured breaches under contention: 4.676s locally (old
        // 4s bound), then 19.446s on a 2-core CI runner under full-suite
        // parallel load (old 15s bound). 60s gives ~3x headroom over the CI
        // worst case, while a regressed EOF-waiting implementation would take
        // the full 120s and fail unambiguously.
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    @Test func returnsOutputWithoutWaitingForGrandchildEOF() async throws {
        // Termination-path variant: the direct child exits immediately and
        // successfully while its backgrounded grandchild holds the pipe write
        // end for 30s. The call must return the child's output right away — a
        // drain that waits for pipe EOF stalls until the grandchild exits,
        // which would surface as a spurious GitTimeoutError here (timeout 3s
        // << grandchild 30s). Outcome-based: success discriminates old from
        // new without asserting wall-clock timing. The `sleep 30 &` grandchild
        // may linger up to 30s after the suite — tolerable orphanage.
        let git = GitManager(subprocessTimeout: .seconds(3))
        let out = try await git.runForTimeoutTesting(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo hi"],
            at: FileManager.default.temporaryDirectory.path
        )
        #expect(out == "hi\n")
    }
}
