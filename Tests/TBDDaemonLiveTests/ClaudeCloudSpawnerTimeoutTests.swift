import Foundation
import Testing
@testable import TBDDaemonLib

/// **Tier 3** — spawns a real child (`/bin/sh -c "sleep 5"`) racing a real
/// deadline (`Tests/CLAUDE.md`'s test-tier taxonomy names this case verbatim:
/// a suite belongs here if it "spawns a child racing a deadline"). Runs
/// serially with the rest of `Tests/TBDDaemonLiveTests` on an otherwise-idle
/// machine, so 0.2s is a real margin rather than a tolerance liable to flake
/// under the fast pass's unbounded suite parallelism.
///
/// `BoundedProcessClaudeSpawner` has no injected clock — its `spawn(_:)` is
/// fixed by `ClaudeCloudSpawning`'s brief-specified shape, and unlike
/// `GitManager`/`TmuxManager.runExternalCommand` it forwards no `clock:`
/// parameter of its own to `runBoundedProcess`, so this suite races a real
/// deadline rather than following `SubprocessTimeoutTests`'/
/// `GitManagerTimeoutTests`' `TestClock` idiom. That is acceptable here
/// because the property under test is narrow — that `spawn(_:)`'s outcome
/// mapping passes `.timedOut` through untouched, not a structural promptness
/// or kill-path proof — matching `ProviderRunnerTimeoutTests`' simpler
/// real-deadline shape rather than the heavier virtual-time suites.
@Suite("ClaudeCloudSpawner timeout (live)")
struct ClaudeCloudSpawnerTimeoutTests {
    /// `.timedOut` must pass through the outcome mapping untouched — the
    /// other branch of the `switch` in `spawn(_:)`. `/bin/sh -c "sleep 5"`
    /// against a far shorter deadline exercises the real bounded-process
    /// watchdog rather than asserting the mapping in isolation.
    @Test func spawnMapsATimeoutToTimedOut() async throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let spawner = BoundedProcessClaudeSpawner(executable: "/bin/sh")
        let outcome = try await spawner.spawn(
            ClaudeCloudSpawnRequest(
                arguments: ["-c", "sleep 5"],
                workingDirectory: tmp,
                usesPseudoTerminal: false,
                timeout: 0.2))
        #expect(outcome == .timedOut)
    }
}
