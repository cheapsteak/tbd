import Foundation
import Testing
@testable import TBDDaemonLib

/// Exercises `GitManager`'s subprocess timeout/kill path (`GitTimeoutError`) via
/// the package-internal `runForTimeoutTesting` seam driven against `/bin/sleep`.
/// Asserts the OUTCOME (an error is thrown), never timing — CI runners can be
/// pathologically slow, so a wall-clock bound would be flaky. A real git hang is
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
}
