import Foundation

/// Bounds the number of RPC handlers running concurrently.
///
/// Each in-flight handler can fan out into git / gh subprocesses (e.g.
/// `pr.list` enumerates `git config` for every worktree and then issues a gh
/// GraphQL call). The socket server spawns one `Task` per received line with no
/// bound, so a burst of client connections — or a client that opens a fresh
/// socket per poll — could spawn an unbounded number of concurrent
/// subprocesses that never drain, pegging the daemon. This limiter gates the
/// normal-request path so at most `maxConcurrentRPCs` handlers run at once;
/// additional requests suspend FIFO until a slot frees.
///
/// The long-lived `state.subscribe` stream deliberately BYPASSES the limiter —
/// it holds its socket open indefinitely and must never occupy a slot.
actor RPCConcurrencyLimiter {
    /// Maximum number of RPC handlers allowed to run concurrently.
    ///
    /// Caps the concurrent git/gh subprocess fan-out from a connection burst.
    /// Sized comfortably above the steady-state RPC rate (a handful of polls)
    /// while still bounding the worst case to a few simultaneous subprocesses.
    static let maxConcurrentRPCs = 8

    private let limit: Int

    /// Number of slots currently held (acquired and not yet released). Serves
    /// as the in-flight gauge — it never exceeds `limit`.
    private(set) var inFlight = 0

    /// Highest `inFlight` value observed since construction.
    private(set) var highWaterMark = 0

    /// FIFO queue of callers suspended waiting for a slot.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = RPCConcurrencyLimiter.maxConcurrentRPCs) {
        precondition(limit > 0, "RPCConcurrencyLimiter requires a positive limit")
        self.limit = limit
    }

    /// Acquire a slot, suspending FIFO when the limiter is at capacity.
    ///
    /// Returns the in-flight count *after* acquiring, so the caller can cheaply
    /// check a high-water threshold without a second actor hop.
    ///
    /// NOT cancellation-safe: a task cancelled while suspended in `acquire()`
    /// would leak its continuation (the `withCheckedContinuation` never resumes)
    /// and permanently consume a slot, since the slot is only ever reclaimed by a
    /// matching `release()`. Callers therefore MUST NOT cancel a task parked in
    /// `acquire()`, and MUST pair every successful `acquire()` with exactly one
    /// `release()`. The sole caller — SocketServer's fire-and-forget, non-cancelled
    /// per-line `Task` driving a non-throwing `handleRaw` — satisfies this.
    @discardableResult
    func acquire() async -> Int {
        if inFlight < limit {
            inFlight += 1
            if inFlight > highWaterMark { highWaterMark = inFlight }
            return inFlight
        }
        // At capacity: suspend until release() hands us the slot. The releaser
        // does NOT decrement inFlight when it resumes a waiter — the slot is
        // transferred directly, so inFlight stays pinned at `limit`.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        return inFlight
    }

    /// Release a slot, waking the oldest waiter (if any).
    func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            // Transfer the slot to the oldest waiter; inFlight is unchanged.
            let cont = waiters.removeFirst()
            cont.resume()
        }
    }
}
