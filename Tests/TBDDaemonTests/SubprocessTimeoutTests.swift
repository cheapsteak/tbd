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
