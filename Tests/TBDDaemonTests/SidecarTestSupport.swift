import Foundation
import TestSupport
import TBDShared

/// Thread-safe collector for `onInput` callbacks, which fire on the receive
/// thread. Tests poll `count` until the expected frames land.
final class SidecarInputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(header: SidecarInputHeader, bytes: Data)] = []

    func record(_ header: SidecarInputHeader, _ bytes: Data) {
        lock.lock(); items.append((header, bytes)); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var all: [(header: SidecarInputHeader, bytes: Data)] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Thread-safe ordered recorder of `kind:pane` tags across the two sidecar
/// sinks (`onInput`/`onPaste`), which fire on one receive thread. Lets a test
/// assert wire ordering ACROSS both callbacks.
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
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
