import TBDShared

/// Collapses concurrent `pr.list` RPCs into a single computation.
///
/// The app polls `pr.list` on a timer with no in-flight guard, so overlapping
/// polls would each start a fresh git enumeration (a `git config` subprocess
/// per worktree) plus a gh GraphQL fetch. This coordinator ensures that while
/// one computation is in flight, every other caller awaits it and receives the
/// SAME snapshot instead of launching a second enumeration. Once the in-flight
/// computation resolves, the next call starts a fresh one.
///
/// Errors propagate: the computation is `throws`, so a DB enumeration failure
/// surfaces to the app as an RPC error rather than a silently-stale snapshot.
/// A thrown error reaches every caller awaiting the in-flight task (they share
/// the same failure), and `defer` clears the in-flight slot even on throw — so a
/// transient failure does not poison subsequent polls.
actor PRListCoordinator {
    private var inFlight: Task<PRListResult, Error>?

    /// Run `compute`, or — if a computation is already in flight — await the
    /// existing one and return its result. Rethrows whatever `compute` throws.
    func run(_ compute: @Sendable @escaping () async throws -> PRListResult) async throws -> PRListResult {
        if let existing = inFlight {
            return try await existing.value
        }
        let task = Task { try await compute() }
        inFlight = task
        // The creator clears the slot so the next wave starts fresh — even when
        // `compute` throws. Callers that piled onto `task` while it ran already
        // observed the same result or error.
        defer { inFlight = nil }
        return try await task.value
    }
}
