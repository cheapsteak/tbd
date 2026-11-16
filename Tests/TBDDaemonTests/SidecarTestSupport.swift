import Foundation
import TestSupport
import TBDShared

/// Thread-safe event counter for callbacks that fire off the test's task —
/// a receive thread, a test hook, a task's `defer`. Tests poll `count` until
/// the expected events land.
final class SidecarEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0

    func record() {
        lock.lock(); events += 1; lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return events }
}

/// Thread-safe ordered recorder of `kind:pane` tags from sidecar sinks, which
/// fire on one receive thread. Lets a test assert wire ordering.
final class TaggedFrameSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [String] = []

    func record(kind: String, pane: String) {
        lock.lock(); tags.append("\(kind):\(pane)"); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return tags.count }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return tags }
}

/// Poll `condition` until it holds or `timeout` elapses. Returns its final value.
///
/// The default is the shared saturated-pass budget, not a literal. This helper
/// is the most-used bounded wait in the daemon target and almost every call
/// site waits for a gate to be entered from work the production code hands to
/// an unstructured task — SE-0417 carries no executor preference across that
/// hop (`gateHoldingTask` in `Tests/TestSupport/BoundedGateSupport.swift`), so
/// the wait queues behind the whole fast pass and only the bound is the test's
/// to get right. Two seconds was orders of magnitude below that pass's healthy
/// per-test latency; the call sites that already spelled out `ciSafeDeadline`
/// were compensating for it one at a time.
func waitUntil(
    _ condition: @Sendable () -> Bool,
    timeout: Duration = TestDeadlines.saturatedPass
) async -> Bool {
    // A cancelled wait reports `false` rather than spinning: this returns a
    // Bool, so there is nothing to throw and nothing to record.
    return await pollUntilTrue(
        timeout: timeout, pollInterval: .milliseconds(10), condition
    ) == .satisfied
}
