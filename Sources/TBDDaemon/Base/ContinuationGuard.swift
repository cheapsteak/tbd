import os

/// One-shot claim used to enforce the single-resume contract of a
/// `CheckedContinuation` shared across a termination handler, a timeout timer,
/// and a spawn-failure path. `claim()` returns `true` exactly once.
/// Package-internal so the git runner reuses it for the same purpose.
final class ContinuationGuard: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    /// Returns true the first time it is called, false thereafter.
    func claim() -> Bool {
        lock.withLock { resumed in
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// Whether the continuation has already been resumed by someone. Read by the
    /// spawn path to detect a deadline that fired *during* `Process.run()`.
    var isClaimed: Bool { lock.withLock { $0 } }
}
