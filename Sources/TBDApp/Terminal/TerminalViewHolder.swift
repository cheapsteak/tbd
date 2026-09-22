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
///
/// It is also the **one seam both transports feed through** — the tmux arm from
/// `Coordinator.dataReceived(slice:)`, the holder arm from the
/// `HolderStreamReader` callback — which is what makes the two arms' latency
/// numbers comparable by construction rather than by argument. See
/// `TerminalLatencyTap` and
/// `docs/specs/2026-09-22-terminal-transport-latency-instrument-design.md`.
final class TerminalViewHolder: @unchecked Sendable {
    /// The view and the tap are read together, under one lock, because
    /// `feed(_:)` needs a consistent pair: a tap that outlived its view would
    /// stamp a chunk nobody parsed.
    private struct Contents {
        var view: TerminalView?
        var tap: TerminalLatencyTap?
    }

    private let lock = OSAllocatedUnfairLock<Contents>(uncheckedState: Contents())

    /// Written once, on the main actor, before `startProcess`.
    func set(_ view: TerminalView) {
        lock.withLockUnchecked { $0.view = view }
    }

    /// Cleared by `cleanup()` on the main actor BEFORE `terminate()` (or the
    /// `LocalProcess` release) so late IO batches read nil and drop.
    func clear() {
        lock.withLockUnchecked { $0.view = nil }
    }

    /// Whether a feed would reach a view right now.
    ///
    /// The panel keeps its own `terminalView` reference for as long as SwiftUI
    /// holds the NSView, so that reference outliving this one is the normal
    /// shape of a torn-down attach rather than an anomaly: an attach that fails
    /// after the reader started clears the holder and leaves the view in place.
    /// Anything that must know whether bytes can still flow — the latency
    /// probe, which would otherwise report a write into a cleared holder as a
    /// lost token — asks here, not there.
    var hasView: Bool {
        lock.withLockUnchecked { $0.view != nil }
    }

    /// Installs the panel's latency tap. Only ever called when the
    /// default-off `TerminalLatencyDiagnostic` is on; with no tap installed
    /// `feed(_:)` is exactly the `withView` call it replaced.
    func setTap(_ tap: TerminalLatencyTap) {
        lock.withLockUnchecked { $0.tap = tap }
    }

    /// Withdraws the tap at teardown, so a panel on its way out stops emitting.
    func clearTap() {
        lock.withLockUnchecked { $0.tap = nil }
    }

    /// The one entry point both transports feed through: stamp, feed, stamp.
    ///
    /// Nothing about the feed itself changes — same thread, same lock, same
    /// view reference, same drop-on-teardown behaviour. With no tap installed
    /// this is one nil-check more than the bare `withView { $0.feed(...) }` it
    /// replaced, which is the whole cost of the instrument when it is off.
    func feed(_ bytes: ArraySlice<UInt8>) {
        let contents = lock.withLockUnchecked { $0 }
        guard let view = contents.view else { return }
        guard let tap = contents.tap else {
            view.feed(byteArray: bytes)
            return
        }
        let feedAt = tap.now()
        view.feed(byteArray: bytes)
        let feedReturnedAt = tap.now()
        tap.noteChunk(bytes, feedAt: feedAt, feedReturnedAt: feedReturnedAt)
    }

    /// Takes a strong local reference under the lock, then runs `body`
    /// against it outside the lock (`feed` is self-locking and a parse batch
    /// can run for milliseconds — the unfair lock only guards the pointer
    /// read). A call racing `clear()` either completes against a live,
    /// retained view or reads nil and drops; both are safe.
    @discardableResult
    func withView<T>(_ body: (TerminalView) -> T) -> T? {
        let view = lock.withLockUnchecked { $0.view }
        guard let view else { return nil }
        return body(view)
    }
}
