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
}
