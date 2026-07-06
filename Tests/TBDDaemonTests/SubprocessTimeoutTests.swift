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
