import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "outgoingInputQueue")

/// The single serialization point for everything one terminal panel writes to
/// its session: the person at the keyboard, and — once the daemon injects
/// through the app while a holder-backed session is attached (the "typing"
/// task that follows this one) — the daemon.
///
/// **Why it must know about bracketed paste.** A paste is `ESC[200~`, the
/// payload, then `ESC[201~`; every byte the child reads between the markers
/// is delivered to it as pasted text. A daemon injection that lands there is
/// silently absorbed into the paste rather than delivered as itself. This
/// queue is the only place that ever sees both the user's keystrokes and a
/// daemon's injected bytes, so it is the only place that can hold an
/// injection open across that window — the strongest form of the guarantee;
/// see `docs/specs/2026-08-30-pty-holder-session-transport-design.md`
/// "Input is not arbitrated, but it is serialized".
///
/// ## Ordering, and why the producer side is `nonisolated`
///
/// `enqueueUserBytes`, `beginUserPaste` and `endUserPaste` are `nonisolated`
/// and synchronous: they `yield` into an internal `AsyncStream` rather than
/// `await`-hopping onto the actor. That is deliberate, not a shortcut. A
/// bracketed paste reaches `TerminalPanelView.Coordinator.send(source:data:)`
/// as THREE separate, synchronous SwiftTerm delegate calls in the same stack
/// frame — start marker, payload, end marker — and Swift gives no ordering
/// guarantee between two `Task { await … }` blocks created back-to-back on
/// the same thread: an actor processes jobs in the order they actually reach
/// its mailbox, not the order the `Task`s were created. A plain synchronous
/// `yield`, by contrast, IS ordered by the call itself — three yields made
/// one after another from a single thread land in the stream in that order,
/// full stop — and exactly one consumer (`pump()`) ever touches `isPasteOpen`
/// or `pendingInjections`, so there is nowhere for those three calls to
/// reorder relative to each other or to a concurrently-arriving injection.
///
/// `enqueueInjection` does not get to be synchronous — it has to report
/// whether the byte actually reached the wire — so it stays genuinely
/// `async`, but it is likewise routed through the same event stream rather
/// than touching actor state directly, so it can never observe `isPasteOpen`
/// out of order relative to a `beginUserPaste`/`endUserPaste` pair that raced
/// it in.
actor OutgoingInputQueue {
    private enum Event: Sendable {
        case userBytes(Data)
        case beginPaste
        case endPaste
        case injection(Data, CheckedContinuation<Bool, Never>)
    }

    /// Performs the actual write once the queue has decided a chunk may go
    /// out now. This queue only decides ORDER; a transport failure inside
    /// `write` is the caller's problem, exactly as it was before this queue
    /// existed (`localProcess?.send` / `fdSidecar.sendInput` were already
    /// fire-and-forget).
    private let write: @Sendable (Data) async -> Void
    private let clock: any Clock<Duration>
    /// How long a held injection waits for `endUserPaste()` before the queue
    /// stops trusting the paste to ever close and writes it anyway. An
    /// unclosed paste is a bug somewhere else in the stack; losing the
    /// injection on top of it would compound the failure instead of
    /// surfacing it, so this bound exists to fail SAFE, not to be tuned for
    /// latency. Two seconds is far longer than any real paste takes to
    /// complete (SwiftTerm sends all three chunks back-to-back, synchronously)
    /// and far shorter than a person would wait before assuming an agent is
    /// stuck.
    private let pasteHoldBound: Duration

    private var isPasteOpen = false
    private struct PendingInjection {
        let id: UUID
        let data: Data
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }
    private var pendingInjections: [PendingInjection] = []

    /// `nonisolated`: `AsyncStream.Continuation.yield` is thread-safe by
    /// design (it is meant to be called from any producer), and the
    /// producer-side methods below rely on reaching it WITHOUT an actor hop —
    /// see the type doc's "Ordering" section for why that matters.
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    init(
        pasteHoldBound: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock(),
        write: @escaping @Sendable (Data) async -> Void
    ) {
        self.write = write
        self.clock = clock
        self.pasteHoldBound = pasteHoldBound
        var escapedContinuation: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { escapedContinuation = $0 }
        self.continuation = escapedContinuation
        // Started last, after every other stored property is set: its
        // closure captures `self` weakly, which is only well-formed once
        // `self` is fully formed. Not retained anywhere — an unstructured
        // `Task` keeps running once started regardless of whether its handle
        // is kept, and `deinit` ending the stream is what stops this loop, so
        // there is nothing a stored handle would let us do that `deinit`
        // doesn't already do.
        Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Ends the stream and releases any injection still waiting on a paste
    /// that never closed — each resolves `false`, since nothing was ever
    /// written for it. Idempotent. Call from teardown (`Coordinator.cleanup`)
    /// so a torn-down panel doesn't leave its timeout tasks running.
    func shutdown() {
        for pending in pendingInjections {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: false)
        }
        pendingInjections.removeAll()
        continuation.finish()
    }

    /// Test-only: how many injections are currently held behind an open
    /// paste. A test uses this to wait (bounded, polling) for an
    /// `enqueueInjection` call's `yield` to have actually reached the single
    /// consumer and been recognized as held, before it proceeds to close the
    /// paste — without this, "close the paste" and "the injection's event
    /// landed in the stream" would race, since creating the `Task` that calls
    /// `enqueueInjection` only schedules its body; it does not run it.
    var pendingInjectionCountForTesting: Int {
        pendingInjections.count
    }

    // MARK: - Producer side (nonisolated, synchronous — see type docs)

    /// Enqueue a chunk of user-originated bytes (a keystroke, or one of the
    /// three chunks of a bracketed paste). Fire-and-forget by design: the
    /// caller is a synchronous SwiftTerm delegate callback with nothing
    /// meaningful to await.
    nonisolated func enqueueUserBytes(_ data: Data) {
        continuation.yield(.userBytes(data))
    }

    /// Marks a user paste as open. Any injection enqueued before the matching
    /// `endUserPaste()` (or before `pasteHoldBound` elapses) is held rather
    /// than written.
    nonisolated func beginUserPaste() {
        continuation.yield(.beginPaste)
    }

    /// Closes the open paste and releases every injection that was held for
    /// it, in the order they were enqueued.
    nonisolated func endUserPaste() {
        continuation.yield(.endPaste)
    }

    /// Enqueues a daemon-originated injection. Returns whether it was
    /// actually written — the caller (the injection-ack path) reports this
    /// truthfully to the daemon, so ownership transfers on the write, not on
    /// the call: the continuation resumes only AFTER `write` returns, never
    /// before.
    func enqueueInjection(_ data: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation.yield(.injection(data, continuation))
        }
    }

    // MARK: - Single consumer

    private func handle(_ event: Event) async {
        switch event {
        case .userBytes(let data):
            await write(data)
        case .beginPaste:
            isPasteOpen = true
        case .endPaste:
            isPasteOpen = false
            await flushPending()
        case .injection(let data, let continuation):
            if isPasteOpen {
                hold(data: data, continuation: continuation)
            } else {
                await write(data)
                continuation.resume(returning: true)
            }
        }
    }

    private func hold(data: Data, continuation: CheckedContinuation<Bool, Never>) {
        let id = UUID()
        let timeoutTask = Task { [weak self, pasteHoldBound, clock] in
            // Non-throwing on cancellation: `try?` swallows the
            // `CancellationError` `endUserPaste`'s flush produces by
            // cancelling this task, and the guard below then no-ops because
            // `forceDeliver` finds nothing left under `id` — the flush
            // already removed and resolved it.
            try? await clock.sleep(for: pasteHoldBound)
            guard !Task.isCancelled else { return }
            await self?.forceDeliver(id: id)
        }
        pendingInjections.append(
            PendingInjection(id: id, data: data, continuation: continuation, timeoutTask: timeoutTask))
    }

    /// Fired by a held injection's own timeout. A no-op if `endUserPaste()`
    /// (or `shutdown()`) already resolved this injection — `id` looked up by
    /// value, so whichever side gets there first wins and the other finds
    /// nothing.
    private func forceDeliver(id: UUID) async {
        guard let index = pendingInjections.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingInjections.remove(at: index)
        logger.info(
            "outgoingInputQueue: injection held past the paste-hold bound with the paste still open; writing it anyway")
        await write(pending.data)
        pending.continuation.resume(returning: true)
    }

    private func flushPending() async {
        guard !pendingInjections.isEmpty else { return }
        let toFlush = pendingInjections
        pendingInjections.removeAll()
        for pending in toFlush {
            pending.timeoutTask.cancel()
            await write(pending.data)
            pending.continuation.resume(returning: true)
        }
    }
}
