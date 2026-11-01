import Testing
import TestSupport

/// Waits until `condition` holds on the main actor, through `pollUntilTrue`
/// (Tests/CLAUDE.md, "Assertion hygiene"), suspending between reads so
/// main-queue work and run-loop layout get to run (Tests/CLAUDE.md,
/// "`@MainActor` tests: suspend to drain, never pump").
///
/// Returns true once it holds, within `TestDeadlines.saturatedPass`. A
/// timeout is recorded as an error naming what was awaited and how long the
/// wait took, so the text reaches the CI summary, and returns false.
/// Cancellation throws: the harness ended the test, and no timeout is
/// invented for it.
@MainActor
func waitForMainActorCondition(
    _ what: String, _ condition: @escaping @MainActor @Sendable () -> Bool
) async throws -> Bool {
    let start = ContinuousClock.now
    let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
        await MainActor.run { condition() }
    }
    switch outcome {
    case .satisfied:
        return true
    case .cancelled:
        throw CancellationError()
    case .timedOut:
        Issue.record(MainActorWaitTimedOut(what: what, elapsed: ContinuousClock.now - start))
        return false
    }
}

/// A `waitForMainActorCondition` timeout, as the error its issue records.
private struct MainActorWaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let elapsed: Duration

    var description: String {
        "Timed out waiting for \(what) after \(elapsed)"
    }
}
