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
/// ## The outbox, and what it holds behind it
///
/// A pty master takes 1,022 bytes in raw mode and then refuses, so a paste
/// above a kilobyte into a child that is not reading is written short. Nothing
/// can un-write the prefix and nothing can ask the pty how much room it has,
/// so the only repair is to finish the write: **whoever committed the prefix
/// owns the remainder, and nothing else may reach that pty until it has
/// landed.**
///
/// The remainder goes in `outbox`, and every later chunk — the rest of the
/// paste, the keystrokes after it, an injection released from the paste hold —
/// is appended behind it, whole, in arrival order. `drain()` finishes it when
/// the transport says it can take more. Two consequences worth stating
/// outright:
///
/// - **Ordering is FIFO across both streams.** A keystroke typed after a short
///   paste lands after the paste's end marker. That is what keeps a child from
///   being left in bracketed-paste mode with the person's typing absorbed into
///   the paste.
/// - **Held, never dropped, and never bypassed.** Nothing the person typed is
///   discarded while the panel owns the pty, and no byte jumps the queue —
///   including `0x03`, which could not be written any sooner anyway, since the
///   queue that refused everything else will refuse it too.
///
/// The outbox has no size cap: the paste that filled it was already accepted at
/// the view, and the bytes are a copy in this process's memory. Its bound is
/// the descriptor — `EIO` or `EBADF` — never a clock.
///
/// ## What is guaranteed, and what is not
///
/// The guarantee is a **safety** guarantee, not an ordering one: **while a
/// paste is open, an injection is held rather than written — for up to
/// `pasteHoldBound`.** A paste that closes within that bound therefore never
/// has an injection written between its markers, and that is every paste a
/// working viewer produces, because the markers are enqueued from three
/// synchronous delegate calls in one main-actor turn.
///
/// The bound is not a weakening of that; it is what the guarantee is traded
/// against. A paste that never closes — a wedged panel, a torn-down transport,
/// a `beginUserPaste` whose `endUserPaste` never runs — would otherwise hold
/// an injection forever, and `forceDeliver` writes it instead, logging that it
/// did. An injection absorbed into a person's paste is visible and
/// recoverable; one nobody can ever get out is not. `HolderInputTiming` keeps
/// this bound strictly shorter than the daemon's ack deadline for the same
/// reason in the other direction: a hold that outlasted the deadline would
/// have the daemon write every held injection into the open paste itself, so
/// the rare bad outcome would become the systematic one.
///
/// Whether an injection that genuinely races the start marker is held or
/// written first is **unspecified**, and both outcomes are correct — an
/// injection reaches this queue through an `await` (`enqueueInjection` is
/// `async`, because it must report whether the byte reached the wire), while
/// the paste markers arrive synchronously, so the relative order of a true
/// race is not determined and no caller may depend on it. What matters is that
/// whichever order the two land in, the injection is written wholly outside
/// the marker span.
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
    /// What one attempt at the transport achieved.
    ///
    /// Three cases, because the middle one is neither of the other two: a pty
    /// master takes a prefix and refuses the rest while remaining perfectly
    /// alive, and calling that a failure is what made a truncated paste look
    /// like a dead transport.
    enum WriteAttempt: Equatable {
        /// Every byte was taken.
        case accepted
        /// The transport took `written` bytes (possibly zero) and refused the
        /// rest. It is alive and will take more later; the remainder is this
        /// queue's to keep and finish.
        case refused(written: Int)
        /// Nothing will ever land through this transport: no descriptor, a
        /// dead child (`EIO`), a torn-down panel. `written` may be non-zero —
        /// a prefix can be committed and the descriptor die before the rest.
        case unwritable(written: Int)
    }

    /// Hands one chunk to the panel's transport and reports what it took.
    ///
    /// **This is the ack.** `.accepted` and `.refused` both mean the bytes are
    /// with a writer that will complete or report — for `.refused` this queue
    /// is that writer — and both are reported to the daemon as
    /// `written: true`. Only `.unwritable` is `false`, and it means what it
    /// says: nothing was written and nothing will be, so the daemon must fall
    /// back rather than log an ack.
    private let attempt: @MainActor (Data) -> WriteAttempt
    /// Asks the host to start telling this queue when the transport can take
    /// more (`drain()`), and to stop. Called on the edges only: armed when the
    /// outbox becomes non-empty, disarmed when it empties. A drain notifier
    /// left armed over an empty outbox is a main-queue spin, not a leak — see
    /// `drain()`.
    private let armDrain: @MainActor () -> Void
    private let disarmDrain: @MainActor () -> Void
    /// Publishes the panel-level backpressure indicator: a byte count while a
    /// stall has lasted longer than `backpressureThreshold`, `nil` when it has
    /// cleared. Never called per accepted chunk — a multi-MiB paste would
    /// otherwise redraw the panel a few thousand times.
    private let onBackpressureChange: @MainActor (Int?) -> Void
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
    /// How long an episode has to last before the panel says anything about it
    /// to the person. A paste into a child that is reading normally drains in
    /// a handful of main-actor turns, and a banner that flickered on every one
    /// of those would be noise about a system working correctly.
    private let backpressureThreshold: Duration

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

    /// The remainder of a short write, followed by every chunk that arrived
    /// while it was outstanding — from both streams, whole, in arrival order.
    ///
    /// `[Data]` rather than one concatenated buffer: the FIFO already makes the
    /// byte stream contiguous, and concatenating would copy megabytes of a
    /// large paste on every append. Chunk boundaries are not delivery
    /// boundaries — the kernel cuts wherever it runs out of room, including
    /// inside a chunk — they are only how the queue stores what it owes.
    private var outbox: [Data] = []
    /// Maintained incrementally. Summing `outbox` per keystroke would make an
    /// O(n) walk out of the one operation that must stay O(1).
    private var pendingBytes = 0
    private var isDrainArmed = false
    /// The largest `pendingBytes` reached during the current episode, for the
    /// one `.info` line an episode logs when it ends.
    private var episodePeakBytes = 0
    private var backpressureTask: Task<Void, Never>?
    private var isBackpressureVisible = false

    /// Test-only: bytes the queue owes the session right now.
    var pendingByteCountForTesting: Int { pendingBytes }
    /// Test-only: how many chunks are waiting, which is what discriminates a
    /// FIFO that appends from one that coalesces.
    var outboxChunkCountForTesting: Int { outbox.count }
    /// Test-only: how many times a dropped outbox has been logged. The count,
    /// not a bit, for the reason `userWriteOutcomeTransitionsForTesting`
    /// documents: an unconditional log leaves the bit identical.
    private(set) var outboxDropLogsForTesting = 0

    init(
        pasteHoldBound: Duration = HolderInputTiming.pasteHoldBound,
        backpressureThreshold: Duration = .seconds(1),
        clock: any Clock<Duration> = ContinuousClock(),
        armDrain: @escaping @MainActor () -> Void = {},
        disarmDrain: @escaping @MainActor () -> Void = {},
        onBackpressureChange: @escaping @MainActor (Int?) -> Void = { _ in },
        attempt: @escaping @MainActor (Data) -> WriteAttempt
    ) {
        self.attempt = attempt
        self.armDrain = armDrain
        self.disarmDrain = disarmDrain
        self.onBackpressureChange = onBackpressureChange
        self.clock = clock
        self.pasteHoldBound = pasteHoldBound
        self.backpressureThreshold = backpressureThreshold
    }

    /// Releases any injection still waiting on a paste that never closed —
    /// each resolves `false`, since nothing was ever written for it.
    /// Idempotent. Call from teardown (`Coordinator.cleanup`) so a torn-down
    /// panel doesn't leave its timeout tasks running.
    ///
    /// The paste is closed as part of this, so the queue is left inert rather
    /// than half-torn-down: an injection arriving after teardown resolves
    /// promptly on whatever the transport reports (`false`, for a panel whose
    /// transport is gone) instead of being parked behind a paste nobody will
    /// ever close.
    func shutdown() {
        for pending in pendingInjections {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: false)
        }
        pendingInjections.removeAll()
        isPasteOpen = false
        // The descriptor is about to close, so the remainder can never land.
        // Dropping it here rather than in the panel keeps the byte count — the
        // only thing worth logging — where it is known, and `transportDied`
        // carries the disarm this teardown owes the notifier.
        transportDied()
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
    /// expected reading, **and a short write must leave it there**: a held
    /// remainder is not a panel whose keystrokes are going nowhere.
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
    /// main-actor turn — or, if the transport is still owed bytes from an
    /// earlier short write, joins the back of the outbox, which is an O(1)
    /// append with no hop. Fire-and-forget by design: the caller is a
    /// synchronous SwiftTerm delegate callback with nobody to report a
    /// transport failure to, exactly as it was before this queue existed
    /// (`localProcess?.send` / `fdSidecar.sendInput` were already
    /// fire-and-forget).
    ///
    /// Nobody to report to is not the same as nothing to say: the transport
    /// now *knows* when the bytes reached nothing, and on a panel whose child
    /// has exited that is true of every keystroke, so a human types and the
    /// only diagnostic is absence. `noteUserWriteOutcome` turns that into one
    /// log line per episode.
    func enqueueUserBytes(_ data: Data) {
        noteUserWriteOutcome(submit(data))
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

    // MARK: - The outbox

    /// The one place a chunk is either written or queued. Returns whether a
    /// writer that will complete or report has it.
    ///
    /// **The order of the two branches is the ordering guarantee.** A non-empty
    /// outbox means somebody is owed bytes, so nothing may go to the kernel
    /// ahead of them — not a keystroke, not an injection, not `0x03`. Moving an
    /// interrupt to the front would reorder the person's input against itself
    /// and deliver nothing sooner, because the queue that refused the paste
    /// will refuse the interrupt too.
    ///
    /// **`.unwritable` is not latched into a permanent verdict**, and that is
    /// deliberate. It is the only answer available for two very different
    /// states: a pty whose child has exited, which will refuse forever, and a
    /// panel whose transport is merely absent for a moment — a sidecar between
    /// reconnects, a `localProcess` not yet built. Short-circuiting every later
    /// chunk on the first `.unwritable` would silently wedge the second kind
    /// for the life of the panel, and would make `noteUserWriteOutcome`'s
    /// "reaching a transport again" edge unreachable. Re-attempting costs one
    /// refused `write(2)` per chunk on a genuinely dead descriptor, which is
    /// what the panel already paid before this queue existed; the logging that
    /// would actually be expensive is latched at both ends already.
    @discardableResult
    private func submit(_ data: Data) -> Bool {
        guard outbox.isEmpty else {
            append(data)
            return true
        }
        switch attempt(data) {
        case .accepted:
            return true
        case .refused(let written):
            append(data.dropFirst(written))
            return true
        case .unwritable:
            transportDied()
            return false
        }
    }

    private func append(_ data: some DataProtocol) {
        guard !data.isEmpty else { return }
        let wasEmpty = outbox.isEmpty
        outbox.append(Data(data))
        pendingBytes += data.count
        episodePeakBytes = max(episodePeakBytes, pendingBytes)
        if wasEmpty { beginEpisode() }
    }

    /// Finish what the kernel refused. Called by the drain notifier whenever
    /// the transport can take more — never on a timer, and never speculatively.
    ///
    /// **Every exit from this function leaves the notifier armed if and only if
    /// the outbox is non-empty**, and that is a correctness requirement rather
    /// than tidiness. Readiness notification is level-triggered: an armed
    /// source over an idle, writable pty whose handler writes nothing was
    /// measured firing 44,486 / 182,060 / 47,845 times per second, so a path
    /// that returns with an empty outbox still armed is the main queue at 100%
    /// until the panel closes. There are exactly three exits — the loop's
    /// `.accepted` fallthrough (`endEpisode()`), the `.refused` return (still
    /// owed bytes, stays armed) and `transportDied()` (which calls
    /// `endEpisode()`) — and adding a fourth means adding a disarm.
    ///
    /// **Bounded by the descriptor, not by a clock.** A child that does not
    /// read for thirty seconds holds the outbox for thirty seconds; that is the
    /// truth of the session, and it is what tmux does in the same state.
    /// Expiring the hold would only convert a stall into a tear: the queue is
    /// full, so the bytes released by an expiry could not be written either,
    /// and the payload would be cut with somebody else's bytes in the gap.
    func drain() {
        while let head = outbox.first {
            switch attempt(head) {
            case .accepted:
                outbox.removeFirst()
                pendingBytes -= head.count
            case .refused(let written):
                if written > 0 {
                    outbox[0] = Data(head.dropFirst(written))
                    pendingBytes -= written
                }
                // Stay armed and return to the run loop: the transport has no
                // more room this turn, and spinning here is the main-actor
                // block this design forbids.
                refreshBackpressure()
                return
            case .unwritable:
                transportDied()
                return
            }
        }
        endEpisode()
    }

    /// The arm edge, taken exactly once per episode — when the outbox goes
    /// from empty to non-empty.
    private func beginEpisode() {
        isDrainArmed = true
        armDrain()
        logger.info("""
            outgoingInputQueue: the session's pty refused a write; \
            \(self.pendingBytes, privacy: .public) bytes are queued and will be \
            written as the child reads
            """)
        backpressureTask = Task { [weak self, backpressureThreshold, clock] in
            // Inherits this main-actor context, so the wake-up lands on the
            // same serial executor every other mutation here runs on.
            while !Task.isCancelled {
                try? await clock.sleep(for: backpressureThreshold)
                guard !Task.isCancelled, let self else { return }
                self.refreshBackpressure(force: true)
            }
        }
    }

    /// The disarm edge. `isDrainArmed` makes it idempotent, which matters
    /// twice over: `drain()` and `transportDied()` and `shutdown()` can all
    /// reach it, and the notifier behind `disarmDrain` is a counted
    /// suspend/resume pair that traps when unbalanced.
    private func endEpisode() {
        guard isDrainArmed else { return }
        isDrainArmed = false
        disarmDrain()
        backpressureTask?.cancel()
        backpressureTask = nil
        if isBackpressureVisible {
            isBackpressureVisible = false
            onBackpressureChange(nil)
        }
        logger.info("""
            outgoingInputQueue: the session's pty is taking input again; the \
            episode peaked at \(self.episodePeakBytes, privacy: .public) queued bytes
            """)
        episodePeakBytes = 0
    }

    /// Publishes the pending count when the episode has outlasted the
    /// threshold. `force` is the timer's tick; an ordinary drain only refreshes
    /// a banner that is already showing, so a fast episode never draws one.
    private func refreshBackpressure(force: Bool = false) {
        guard force || isBackpressureVisible else { return }
        isBackpressureVisible = true
        onBackpressureChange(pendingBytes)
    }

    /// The transport is gone for good. Everything it was owed is dropped —
    /// there is no longer anybody to read it — and the episode ends, which is
    /// what disarms the notifier.
    private func transportDied() {
        if pendingBytes > 0 {
            outboxDropLogsForTesting += 1
            logger.error("""
                outgoingInputQueue: the session's pty is gone with \
                \(self.pendingBytes, privacy: .public) bytes still unwritten; \
                they are dropped — the child that was to read them has exited
                """)
        }
        outbox.removeAll()
        pendingBytes = 0
        endEpisode()
    }

    // MARK: - Daemon injection

    /// Enqueues a daemon-originated injection. Returns whether a writer that
    /// will complete or report has it — the caller (the injection-ack path)
    /// reports this truthfully to the daemon, so ownership transfers on the
    /// submit, not on the call.
    ///
    /// `true` covers both "the transport took every byte" and "the transport
    /// took a prefix, or none, and this queue owns the rest": in either case
    /// the bytes are with a writer that will finish them, which is the meaning
    /// `true` already carries on the `localProcess` and sidecar arms of
    /// `performOutgoingWrite`. `false` means, and only means, that nothing was
    /// written and nothing will be.
    ///
    /// `async` because it may have to wait for a paste to close. When no
    /// paste is open it returns without ever suspending.
    func enqueueInjection(_ data: Data) async -> Bool {
        guard isPasteOpen else { return submit(data) }
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
        pending.continuation.resume(returning: submit(pending.data))
    }

    private func flushPending() {
        guard !pendingInjections.isEmpty else { return }
        let toFlush = pendingInjections
        pendingInjections.removeAll()
        for pending in toFlush {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: submit(pending.data))
        }
    }
}
