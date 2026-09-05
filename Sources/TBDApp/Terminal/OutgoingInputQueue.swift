import Foundation
import TBDShared
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
/// ## Why `@MainActor`, and not an actor
///
/// Every producer is already main-actor-confined, and enforceably so:
/// `TerminalPanelView.Coordinator` gets `@MainActor` by inference through its
/// `TerminalViewDelegate` conformance, which SwiftTerm declares `@MainActor`.
/// So an `actor` here would buy no exclusion that the compiler does not
/// already guarantee, and would cost two scheduling transitions per keystroke
/// — off the main actor into the actor's executor, and straight back onto the
/// main actor to reach the write. The output direction of this same file
/// carries an explicit warning against acquiring exactly that hop
/// (`TerminalPanelView.swift:750`, on the paint-starvation investigation);
/// the input direction must not acquire one either. `enqueueUserBytes`,
/// `beginUserPaste` and `endUserPaste` are therefore plain synchronous
/// main-actor methods that act inline, and a keystroke reaches the pty in the
/// same turn it arrived in.
///
/// One serial executor also makes ordering free rather than argued: the three
/// synchronous SwiftTerm delegate calls that make up a bracketed paste — start
/// marker, payload, end marker — run to completion in the order they are
/// called, and nothing can interleave between them, because there is no
/// suspension point for anything to interleave at.
///
/// ## What is guaranteed, and what is not
///
/// The guarantee is a **safety** guarantee, not an ordering one: **an
/// injection is never written between a paste's markers.** Whether an
/// injection that genuinely races the start marker is held or written first is
/// **unspecified**, and both outcomes are correct — an injection reaches this
/// queue through an `await` (`enqueueInjection` is `async`, because it must
/// report whether the byte reached the wire), while the paste markers arrive
/// synchronously, so the relative order of a true race is not determined and
/// no caller may depend on it. What matters is that whichever order the two
/// land in, the injection is written wholly outside the marker span.
///
/// That span is airtight because of the call order in
/// `Coordinator.send(source:data:)`: `beginUserPaste()` runs **before** the
/// start marker is enqueued, and `endUserPaste()` **after** the end marker is
/// enqueued. The paste is thus already open when its own first byte goes out,
/// and still open when its last byte goes out.
///
/// That call order is **comment-enforced only**: no test can discriminate it,
/// because the observable state a test can reach (`isPasteOpenForTesting`,
/// the recorded writes) is identical whether the marker is enqueued just
/// before or just after the flag flips, so reordering the two lines reddens
/// nothing. Reorder them only with this paragraph in hand.
@MainActor
final class OutgoingInputQueue {
    /// Performs the actual write once the queue has decided a chunk may go
    /// out now, and reports whether anything took the bytes: `false` means
    /// the panel had no live transport to hand them to (no `localProcess`, or
    /// a control-mode panel with no attach), so nothing was written and
    /// nothing ever will be for this chunk.
    ///
    /// **That return value is the ack.** A holder-backed panel takes the
    /// `.localPTY` arm with a nil `localProcess` today, so a seam that could
    /// not say "not written" would have this queue ack `written: true` for a
    /// byte that reached nothing — the daemon would then not fall back and the
    /// prompt would be lost invisibly, which the plan's Global Constraints
    /// forbid. The injection path must treat `false` as "fall back and write
    /// directly", not as an ack to log.
    private let write: @MainActor (Data) -> Bool
    private let clock: any Clock<Duration>
    /// How long a held injection waits for `endUserPaste()` before the queue
    /// stops trusting the paste to ever close and writes it anyway. An
    /// unclosed paste is a bug somewhere else in the stack; losing the
    /// injection on top of it would compound the failure instead of
    /// surfacing it, so this bound exists to fail SAFE, not to be tuned for
    /// latency.
    ///
    /// **The invariant that actually binds this value: it must be strictly
    /// SHORTER than the daemon's injection-ack deadline** — otherwise every
    /// injection this queue holds would be written directly by the daemon
    /// while the paste is still open, landing between the markers, which is
    /// the precise harm this queue exists to prevent. Both halves of that
    /// ordering therefore live together in `HolderInputTiming` (TBDShared),
    /// which carries the full statement of the invariant and names the tests
    /// that enforce it; the default below is that constant, and neither value
    /// is a literal in a module the other cannot see.
    ///
    /// Still a parameter, and still injectable: the pinning test drives the
    /// *default*, and every other test in the suite supplies a bound of its
    /// own to isolate the behaviour it is after.
    private let pasteHoldBound: Duration

    private var isPasteOpen = false
    /// The last outcome `enqueueUserBytes` saw. Exists only to make
    /// `noteUserWriteOutcome` edge-triggered.
    ///
    /// Starts optimistic so a healthy panel logs **nothing**: were the
    /// initial value `nil` or `false`, the first keystroke of every panel
    /// that works fine would announce a recovery from a failure that never
    /// happened.
    private var lastUserWriteReachedTransport = true
    private struct PendingInjection {
        let id: UUID
        let data: Data
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }
    /// Injections parked behind an open paste.
    ///
    /// No `deinit` resolves these, and none is needed: a parked continuation
    /// belongs to a suspended `enqueueInjection` frame, and that frame holds a
    /// strong reference to `self`, so this object cannot be deallocated while
    /// any entry remains. It reads like a leaked-continuation hazard and is
    /// not one — do not "fix" it by adding a `deinit` that resumes them, which
    /// would be unreachable code.
    private var pendingInjections: [PendingInjection] = []

    init(
        pasteHoldBound: Duration = HolderInputTiming.pasteHoldBound,
        clock: any Clock<Duration> = ContinuousClock(),
        write: @escaping @MainActor (Data) -> Bool
    ) {
        self.write = write
        self.clock = clock
        self.pasteHoldBound = pasteHoldBound
    }

    /// Releases any injection still waiting on a paste that never closed —
    /// each resolves `false`, since nothing was ever written for it.
    /// Idempotent. Call from teardown (`Coordinator.cleanup`) so a torn-down
    /// panel doesn't leave its timeout tasks running.
    ///
    /// The paste is closed as part of this, so the queue is left inert rather
    /// than half-torn-down: an injection arriving after teardown resolves
    /// promptly on whatever `write` reports (`false`, for a panel whose
    /// transport is gone) instead of being parked behind a paste nobody will
    /// ever close.
    func shutdown() {
        for pending in pendingInjections {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: false)
        }
        pendingInjections.removeAll()
        isPasteOpen = false
    }

    /// Test-only: how many injections are currently held behind an open
    /// paste. A test uses this to wait (bounded, polling) for an
    /// `enqueueInjection` call to have actually reached the queue and been
    /// recognized as held, before it proceeds. The wait is unavoidable for
    /// injections specifically: `enqueueInjection` is `async`, so a test that
    /// wants to park one without blocking has to start a `Task`, and creating
    /// that `Task` only schedules its body — it does not run it.
    var pendingInjectionCountForTesting: Int {
        pendingInjections.count
    }

    /// Test-only: how many times `enqueueUserBytes` has seen the transport's
    /// answer *change* — which is exactly the number of lines
    /// `noteUserWriteOutcome` has logged. Counting the edges rather than
    /// reading the current bit is what discriminates the mutation that
    /// matters: a diagnostic that logged unconditionally would leave the bit
    /// identical and this count climbing per keystroke. Zero means the panel
    /// has been in one state throughout — which for a working panel is the
    /// expected reading.
    private(set) var userWriteOutcomeTransitionsForTesting = 0

    /// Test-only: whether a user paste is currently open. Lets a test drive
    /// the *production* marker-detection path (`Coordinator.send`) and observe
    /// what it decided, instead of calling `beginUserPaste()` directly and
    /// bypassing the classification entirely.
    var isPasteOpenForTesting: Bool {
        isPasteOpen
    }

    // MARK: - User input

    /// Write a chunk of user-originated bytes (a keystroke, or one of the
    /// three chunks of a bracketed paste). Goes out immediately, in this same
    /// main-actor turn. Fire-and-forget by design: the caller is a
    /// synchronous SwiftTerm delegate callback with nobody to report a
    /// transport failure to, exactly as it was before this queue existed
    /// (`localProcess?.send` / `fdSidecar.sendInput` were already
    /// fire-and-forget).
    ///
    /// Nobody to report to is not the same as nothing to say: `write` now
    /// *knows* the bytes reached no transport, and on a holder-backed panel
    /// that is true of every keystroke, so a human types and the only
    /// diagnostic is absence. `noteUserWriteOutcome` turns that into one log
    /// line per episode.
    func enqueueUserBytes(_ data: Data) {
        noteUserWriteOutcome(write(data))
    }

    /// Edge-triggered diagnostic for the user's stream: one line when
    /// keystrokes stop reaching a transport, one when they start again, and
    /// nothing at all on the happy path.
    ///
    /// Edge-triggered rather than per-event because this is the hot path the
    /// output direction of this subsystem carries an explicit warning about
    /// (`TerminalPanelView.swift:750`, the paint-starvation investigation),
    /// and `docs/diagnostics-strategy.md` reserves per-event `.debug` for
    /// paths that are not genuinely hot. `.info` per that taxonomy: a
    /// lifecycle transition inside a subsystem, invisible in the default
    /// stream, retrievable with `log stream --level info`.
    ///
    /// The injection side deliberately does not call this: it reports its
    /// outcome to the daemon as a return value, which is a stronger channel
    /// than a log.
    private func noteUserWriteOutcome(_ reachedTransport: Bool) {
        guard lastUserWriteReachedTransport != reachedTransport else { return }
        lastUserWriteReachedTransport = reachedTransport
        userWriteOutcomeTransitionsForTesting += 1
        if reachedTransport {
            logger.info("outgoingInputQueue: user input is reaching a transport again")
        } else {
            logger.info(
                "outgoingInputQueue: user input reached no transport (no live pty and no connected sidecar attach); keystrokes are being dropped until this recovers")
        }
    }

    /// Marks a user paste as open. Any injection enqueued before the matching
    /// `endUserPaste()` (or before `pasteHoldBound` elapses) is held rather
    /// than written.
    func beginUserPaste() {
        isPasteOpen = true
    }

    /// Closes the open paste and releases every injection that was held for
    /// it, in the order they were enqueued.
    func endUserPaste() {
        isPasteOpen = false
        flushPending()
    }

    // MARK: - Daemon injection

    /// Enqueues a daemon-originated injection. Returns whether it was
    /// actually written — the caller (the injection-ack path) reports this
    /// truthfully to the daemon, so ownership transfers on the write, not on
    /// the call: the value is whatever `write` reported, and it is produced
    /// only after `write` has run.
    ///
    /// `async` because it may have to wait for a paste to close. When no
    /// paste is open it returns without ever suspending.
    func enqueueInjection(_ data: Data) async -> Bool {
        guard isPasteOpen else { return write(data) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            hold(data: data, continuation: continuation)
        }
    }

    private func hold(data: Data, continuation: CheckedContinuation<Bool, Never>) {
        let id = UUID()
        let timeoutTask = Task { [weak self, pasteHoldBound, clock] in
            // Inherits this main-actor context, so the wake-up lands back on
            // the same serial executor every other mutation here runs on.
            //
            // Non-throwing on cancellation: `try?` swallows the
            // `CancellationError` `endUserPaste`'s flush produces by
            // cancelling this task, and the guard below then no-ops because
            // `forceDeliver` finds nothing left under `id` — the flush
            // already removed and resolved it.
            try? await clock.sleep(for: pasteHoldBound)
            guard !Task.isCancelled else { return }
            self?.forceDeliver(id: id)
        }
        pendingInjections.append(
            PendingInjection(id: id, data: data, continuation: continuation, timeoutTask: timeoutTask))
    }

    /// Fired by a held injection's own timeout. A no-op if `endUserPaste()`
    /// (or `shutdown()`) already resolved this injection — `id` looked up by
    /// value, so whichever side gets there first wins and the other finds
    /// nothing.
    private func forceDeliver(id: UUID) {
        guard let index = pendingInjections.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingInjections.remove(at: index)
        logger.info(
            "outgoingInputQueue: injection held past the paste-hold bound with the paste still open; writing it anyway")
        pending.continuation.resume(returning: write(pending.data))
    }

    private func flushPending() {
        guard !pendingInjections.isEmpty else { return }
        let toFlush = pendingInjections
        pendingInjections.removeAll()
        for pending in toFlush {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: write(pending.data))
        }
    }
}
