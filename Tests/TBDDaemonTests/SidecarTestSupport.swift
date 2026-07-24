import Foundation
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
func waitUntil(_ condition: @Sendable () -> Bool, timeout: Duration = .seconds(2)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
