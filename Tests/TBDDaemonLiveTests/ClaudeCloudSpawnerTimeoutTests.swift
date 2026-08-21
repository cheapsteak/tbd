import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// **Tier 3** — both tests spawn a real child. `Tests/CLAUDE.md`'s test-tier
/// taxonomy names this case verbatim: a suite belongs here if it "spawns a
/// child racing a deadline," and that holds even when the *deadline itself*
/// is virtual — `GitManagerTimeoutTests` is the precedent for a `TestClock`
/// still living in this tier.
///
/// `BoundedProcessClaudeSpawner` now threads an injected `clock:` through to
/// `runBoundedProcess`, matching `GitManager`/`TmuxManager.runExternalCommand`.
/// `spawnTimesOutOnInjectedClockDeadline` below is the discriminating proof of
/// that wiring: it advances only a `TestClock` the spawner was constructed
/// with, never sleeps for real, and the deadline still fires — which is only
/// possible if `spawn(_:)` actually forwards `clock` to `runBoundedProcess`
/// rather than dropping it on the floor. Delete the `clock:` argument from
/// that call and this test hangs on the real (600s-unreachable) deadline
/// instead of observing `.timedOut`, tripping the suite's one-minute limit.
///
/// `spawnMapsATimeoutToTimedOut` is kept alongside it as the simpler
/// real-deadline regression guard for the outcome mapping itself (that
/// `.timedOut` passes through the `switch` in `spawn(_:)` untouched) —
/// matching `ProviderRunnerTimeoutTests`' shape, on the default `ContinuousClock()`
/// a caller gets when it does not inject one, same as production.
///
/// WHY AN EXPLICIT `.timeLimit(.minutes(1))` AND NOT `.clockDriven`: this is
/// tier 3, so CI runs it serially (`--filter '^TBDDaemonLiveTests\.'
/// --no-parallel`) on an otherwise-idle machine — the raised 4-minute
/// `.clockDriven` limit exists to absorb the fast parallel pass's arming
/// latency, which does not apply here, and a hang in this suite should be
/// caught promptly rather than tolerated for minutes.
@Suite(.timeLimit(.minutes(1)))
struct ClaudeCloudSpawnerTimeoutTests {
    private static var tmp: String { FileManager.default.temporaryDirectory.path }

    /// Far enough out that the real watchdog cannot reach it inside the
    /// suite's one-minute hang limit, so only the injected `TestClock` can
    /// fire this deadline.
    private static let unreachableTimeout: TimeInterval = 600

    /// `.timedOut` must pass through the outcome mapping untouched — the
    /// other branch of the `switch` in `spawn(_:)`. `/bin/sh -c "sleep 5"`
    /// against a far shorter deadline exercises the real bounded-process
    /// watchdog rather than asserting the mapping in isolation.
    @Test func spawnMapsATimeoutToTimedOut() async throws {
        let spawner = BoundedProcessClaudeSpawner(executable: "/bin/sh")
        let outcome = try await spawner.spawn(
            ClaudeCloudSpawnRequest(
                arguments: ["-c", "sleep 5"],
                workingDirectory: Self.tmp,
                usesPseudoTerminal: false,
                timeout: 0.2))
        #expect(outcome == .timedOut)
    }

    /// Proves `spawn(_:)` actually forwards its injected `clock` to
    /// `runBoundedProcess` rather than always taking the `ContinuousClock()`
    /// default. The clock never sees a real 600s wait — `advanceWhenSuspended`
    /// only returns once the spawner has armed a sleeper on `clock`, and the
    /// deadline fires the instant virtual time crosses it, so a passing run
    /// proves the wiring rather than a generous real timeout.
    @Test func spawnTimesOutOnInjectedClockDeadline() async throws {
        let clock = TestClock()
        let spawner = BoundedProcessClaudeSpawner(executable: "/bin/sh", clock: clock)
        let call = Task {
            try await spawner.spawn(
                ClaudeCloudSpawnRequest(
                    arguments: ["-c", "exec sleep 120"],
                    workingDirectory: Self.tmp,
                    usesPseudoTerminal: false,
                    timeout: Self.unreachableTimeout))
        }
        await clock.advanceWhenSuspended(by: .seconds(Self.unreachableTimeout))
        let outcome = try await call.value
        #expect(outcome == .timedOut)
    }
}
