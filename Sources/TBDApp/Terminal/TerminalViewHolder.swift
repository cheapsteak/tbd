import os
import SwiftTerm

/// Hands the PTY IO thread a way to reach the terminal view without racing
/// teardown.
///
/// With `LocalProcess(delegate:dispatchQueue:directDelivery: true)`,
/// `dataReceived` fires on the IO thread and calls `feed` right there —
/// `feed` itself is thread-safe (the parse runs under SwiftTerm's
/// `terminalLock`), but the *reference* to the view must be owned separately.
/// This holder is that ownership: written once on the main actor before
/// `startProcess`, cleared by `cleanup()` on the main actor BEFORE the
/// process is terminated or released, so no batch feeds a view whose session
/// is being torn down.
final class TerminalViewHolder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<TerminalView?>(uncheckedState: nil)

    /// Written once, on the main actor, before `startProcess`.
    func set(_ view: TerminalView) {
        lock.withLockUnchecked { $0 = view }
    }

    /// Cleared by `cleanup()` on the main actor BEFORE `terminate()` (or the
    /// `LocalProcess` release) so late IO batches read nil and drop.
    func clear() {
        lock.withLockUnchecked { $0 = nil }
    }

    /// Takes a strong local reference under the lock, then runs `body`
    /// against it outside the lock (`feed` is self-locking and a parse batch
    /// can run for milliseconds — the unfair lock only guards the pointer
    /// read). A call racing `clear()` either completes against a live,
    /// retained view or reads nil and drops; both are safe.
    @discardableResult
    func withView<T>(_ body: (TerminalView) -> T) -> T? {
        let view = lock.withLockUnchecked { $0 }
        guard let view else { return nil }
        return body(view)
    }
}
