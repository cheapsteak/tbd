import Foundation
import Testing

/// The outcome of a bounded poll, kept as three cases because the caller has to
/// treat two of them alike and the third differently — and collapsing them to a
/// `Bool` is what let the same bug be written six times.
public enum PollOutcome: Sendable, Equatable {
    /// The condition held. The only case a caller may proceed from.
    case satisfied
    /// The enclosing task was cancelled. The wait ends, and the caller must
    /// report **nothing**: attribution belongs to whatever did the cancelling,
    /// not to a call site that was about to succeed.
    case cancelled
    /// The budget expired with the condition still false, on a fresh read.
    case timedOut
}

/// Polls `condition` until it holds, the task is cancelled, or `timeout`
/// elapses — the one place this repo implements that loop.
///
/// ## Why this exists rather than a loop per call site
///
/// The loop everybody writes tests the deadline before the condition and then
/// takes its verdict from the loop's exit:
///
/// ```swift
/// while ContinuousClock.now < deadline {
///     if condition() { return }
///     try? await Task.sleep(for: .milliseconds(5))
/// }
/// Issue.record(Timeout(...))          // a sample up to `timeout` old
/// ```
///
/// `Task.sleep` is a floor, not a ceiling. When the poller's resumption lands
/// past the deadline the loop exits **without evaluating the condition again**,
/// so the verdict is whatever the last sample said — possibly taken before the
/// task being waited on had run at all. Under the fast parallel pass that is the
/// expected path, not an exotic one: Swift Testing starts every non-serialized
/// test in one process with no concurrency cap, and mined CI xUnit puts p50
/// per-test latency at 56-70 s against a 123-158 s pass, so a 5 ms step aside
/// routinely returns its turn tens of seconds later.
///
/// The second half is cancellation. `try?` around the poll sleep cannot tell
/// expiry from cancellation, and a cancelled `Task.sleep` throws *instantly*, so
/// an unguarded loop stops suspending and busy-spins its whole remaining budget
/// on a cooperative thread — measured at 33,754,162 condition evaluations in
/// 30 s — in a process where every other test is queued behind that thread. It
/// then blames the call site for a cancellation the harness caused.
///
/// Six helpers carried one or both of those defects independently. Raising their
/// deadlines does not fix either: a larger budget cannot repair a verdict that is
/// not derived from an observation. So the loop lives here once, with the tests
/// that pin its contract, and the helpers keep only their own diagnostics.
///
/// The evaluation order inside is load-bearing: the condition is read **before**
/// cancellation is consulted, so a condition that becomes true at the same moment
/// the task is cancelled is still honoured rather than discarded.
///
/// - Parameters:
///   - timeout: total real-time budget. A hang guard, not a synchronization
///     step — size it with `TestDeadlines.saturatedPass` unless the wait is one
///     scheduling hop.
///   - pollInterval: how long to step aside between reads. Lazier is better; a
///     tight poll floods the pool with exactly the work that is starving the
///     task being waited for.
///   - condition: read at least once, and always once more after the budget
///     expires.
/// - Returns: which of the three things happened. Callers that report a
///   diagnostic must report it for `.timedOut` only.
public func pollUntilTrue(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(5),
    _ condition: () async -> Bool
) async -> PollOutcome {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return .satisfied }
        if Task.isCancelled { break }
        try? await Task.sleep(for: pollInterval)
    }
    // The verdict comes from a fresh read, never from the loop's exit.
    if await condition() { return .satisfied }
    if Task.isCancelled { return .cancelled }
    return .timedOut
}
