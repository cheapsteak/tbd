import os

/// Hands the PTY IO thread a way to reach the terminal engine without racing
/// teardown.
///
/// With `LocalProcess(delegate:dispatchQueue:directDelivery: true)`,
/// `dataReceived` fires on the IO thread and calls `feed` right there —
/// `TerminalEngine.feed` itself is thread-safe (the parse runs under the
/// engine's own lock), but the *reference* to the engine must be owned
/// separately.
/// This holder is that ownership: written once on the main actor before
/// `startProcess`, cleared by `cleanup()` on the main actor BEFORE the
/// process is terminated or released, so no batch feeds an engine whose
/// session is being torn down.
///
/// It is also the **one seam both transports feed through** — the tmux arm from
/// `Coordinator.dataReceived(slice:)`, the holder arm from the
/// `HolderStreamReader` callback — which is what makes the two arms' latency
/// numbers comparable by construction rather than by argument. See
/// `TerminalLatencyTap` and
/// `docs/specs/2026-09-22-terminal-transport-latency-instrument-design.md`.
final class TerminalViewHolder: @unchecked Sendable {
    /// The engine, the tap and the last-byte stamp are read together, under
    /// one lock, because `feed(_:)` needs a consistent set: a tap that outlived
    /// its engine would stamp a chunk nobody parsed, and a stamp paired with a
    /// cleared engine would report an age for a store that is no longer a
    /// store.
    private struct Contents {
        var engine: (any TerminalEngine)?
        var tap: TerminalLatencyTap?
        var lastByteAt: ContinuousClock.Instant?
    }

    private let lock = OSAllocatedUnfairLock<Contents>(uncheckedState: Contents())
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    /// - Parameter monotonicNow: reads the monotonic clock for `lastByteAt`.
    ///   Injected so a test can drive the age a screen reply reports instead of
    ///   measuring the wall clock and asserting on a window. `Instant`, not
    ///   `Duration`: this is a timestamp two reads subtract, which is the same
    ///   seam `HolderEmulator` takes for the daemon's half of the identical
    ///   measurement.
    init(monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.monotonicNow = monotonicNow
    }

    /// Written once, on the main actor, before `startProcess`.
    ///
    /// Clears `lastByteAt` with it: a new engine is a new store, and carrying a
    /// predecessor's stamp across would date this one by bytes it never parsed.
    func set(_ engine: any TerminalEngine) {
        lock.withLockUnchecked {
            $0.engine = engine
            $0.lastByteAt = nil
        }
    }

    /// Cleared by `cleanup()` on the main actor BEFORE `terminate()` (or the
    /// `LocalProcess` release) so late IO batches read nil and drop.
    func clear() {
        lock.withLockUnchecked {
            $0.engine = nil
            $0.lastByteAt = nil
        }
    }

    /// Whether a feed would reach an engine right now.
    ///
    /// The panel keeps its own `engine` reference for as long as it lives, so
    /// that reference outliving this one is the normal shape of a torn-down
    /// attach rather than an anomaly: an attach that fails after the reader
    /// started clears the holder and leaves the engine in place.
    /// Anything that must know whether bytes can still flow — the latency
    /// probe, which would otherwise report a write into a cleared holder as a
    /// lost token — asks here, not there.
    var hasView: Bool {
        lock.withLockUnchecked { $0.engine != nil }
    }

    /// Whether a feed would reach an engine, and when the last one did — read
    /// together, under one lock.
    ///
    /// What a screen reply's `ageMilliseconds` is measured from. The pair is
    /// atomic on purpose: a reader that asked the two questions separately
    /// could pair a live engine with a stamp from the engine before it, or report
    /// an age for a holder that has since been cleared. `lastByteAt` is nil
    /// until this store has consumed a byte, and the caller then falls back to
    /// its own attach instant — the app-side twin of the daemon emulator's
    /// `lastByteAt ?? adoptedAt` rule, so "a store that has never consumed a
    /// byte reports the age of the store itself" holds on both sides.
    var feedReading: (hasView: Bool, lastByteAt: ContinuousClock.Instant?) {
        lock.withLockUnchecked { ($0.engine != nil, $0.lastByteAt) }
    }

    /// Installs the panel's latency tap. Only ever called when the
    /// default-off `TerminalLatencyDiagnostic` is on; with no tap installed
    /// `feed(_:)` is exactly the bare `feed` it replaced.
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
    /// engine reference, same drop-on-teardown behaviour. With no tap installed
    /// this is one nil-check more than the bare `withEngine { $0.feed(...) }`
    /// it replaced, which is the whole cost of the instrument when it is off.
    ///
    /// **`lastByteAt` is stamped here and nowhere else**, which is the whole
    /// definition of what it measures: bytes the *child* produced, arriving
    /// through the one seam both transports feed. A snapshot the app ingests at
    /// attach does not come through here, so seeding an engine cannot make a
    /// session that has been silent for an hour report an age of zero — the
    /// same rule, and the same trap, as the daemon emulator's `feed`.
    ///
    /// Stamped only on a feed that reaches an engine: a batch that arrives after
    /// teardown drops, and recording its arrival would date a store that no
    /// longer exists.
    func feed(_ bytes: ArraySlice<UInt8>) {
        let contents = lock.withLockUnchecked { contents -> Contents in
            guard contents.engine != nil else { return contents }
            contents.lastByteAt = monotonicNow()
            return contents
        }
        guard let engine = contents.engine else { return }
        guard let tap = contents.tap else {
            engine.feed(bytes)
            return
        }
        let feedAt = tap.now()
        engine.feed(bytes)
        let feedReturnedAt = tap.now()
        tap.noteChunk(bytes, feedAt: feedAt, feedReturnedAt: feedReturnedAt)
    }

    /// Takes a strong local reference under the lock, then runs `body`
    /// against it outside the lock (`feed` is self-locking and a parse batch
    /// can run for milliseconds — the unfair lock only guards the pointer
    /// read). A call racing `clear()` either completes against a live,
    /// retained engine or reads nil and drops; both are safe.
    ///
    /// `body` runs on the caller's thread, which is the IO thread in
    /// production, so it may use only the engine's `nonisolated` members.
    @discardableResult
    func withEngine<T>(_ body: (any TerminalEngine) -> T) -> T? {
        let engine = lock.withLockUnchecked { $0.engine }
        guard let engine else { return nil }
        return body(engine)
    }
}
