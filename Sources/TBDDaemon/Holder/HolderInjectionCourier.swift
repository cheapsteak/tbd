import Foundation
import TBDShared
import os

/// Delivers one daemon-originated write to a holder-backed session, routed by
/// **who is reading that session's pty**.
///
/// Two writers exist for any session: the person at the keyboard, and the
/// daemon (`tbd terminal send`, queued prompts, the Claude limit-resume
/// actuator). On the tmux transport they never collide, because every byte
/// funnels through one tmux server process that serializes them for free. On
/// the holder transport the app and the daemon hold separate descriptors for
/// the same pty master, and a `write()` to a tty is not atomic — so a daemon
/// injection landing mid-keystroke can shear, and one landing between a
/// bracketed paste's `ESC[200~`/`ESC[201~` markers is silently absorbed into
/// the pasted text.
///
/// The rule that closes it, from
/// `docs/specs/2026-08-30-pty-holder-session-transport-design.md` ("Input is
/// not arbitrated, but it is serialized"):
///
/// - **Detached** — nobody else is on the pty, so the daemon writes to its own
///   dup.
/// - **Attached** — the daemon sends an `.injection` frame and waits for the
///   app's `.injectionAck`. The app is then the session's only writer as well
///   as its only reader, and the concurrency does not exist.
/// - **No usable answer before the deadline** — the daemon writes anyway.
///
/// ## The last rule fails *open*, and it can deliver twice
///
/// A missing ack does not mean the injection was not delivered: the app may
/// have written it and had the ack lost or merely delayed, which App Nap can
/// cause by coalescing a backgrounded app's work far past any deadline worth
/// waiting on. So the fallback can deliver an injection **twice**. That is the
/// at-least-once versus at-most-once fork, taken knowingly in favour of
/// at-least-once: a duplicated prompt is visible and recoverable, a silently
/// dropped one strands an agent indefinitely with nothing to see.
///
/// **Do not "fix" the duplicate by acking before writing.** That trades a
/// visible duplicate for exactly the invisible loss this design rejected, and
/// it will look like a tidy-up. For the same reason a late ack — one arriving
/// after its injection has already been written directly — is *recorded and
/// dropped*, never used to retract or dedupe the write that already happened.
///
/// ## What the deadline may be, and what it must be longer than
///
/// The number is not the point; its *relationship* to the app-side hold is.
/// `OutgoingInputQueue` (TBDApp) parks an injection that arrives while a user
/// paste is open, and that hold must stay strictly shorter than this deadline
/// — otherwise every held injection would be written directly by the daemon
/// while the paste is still open, landing between the markers, which is the
/// precise harm the app-side queue exists to prevent, made systematic rather
/// than rare.
///
/// Neither side can see the other's literal, so both live together in
/// `HolderInputTiming` (TBDShared): `injectionAckDeadline` is the default for
/// `ackDeadline` below, `pasteHoldBound` is the default for the app's hold, and
/// that one type carries the full statement of the invariant along with the
/// tests that enforce it. `ackDeadline` stays a defaulted parameter so a test
/// can still inject a deadline of its own.
actor HolderInjectionCourier {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holderInjection")

    enum Error: LocalizedError, Equatable {
        /// The daemon holds no descriptor for this session's pty. Ordinary
        /// while a viewer is attached — the attach acknowledgement releases the
        /// daemon's reader, which closes it — and a genuine fault otherwise.
        case noDaemonDescriptor(terminalID: UUID)

        var errorDescription: String? {
            switch self {
            case .noDaemonDescriptor(let terminalID):
                return "the daemon holds no descriptor for session \(terminalID.uuidString)'s pty"
            }
        }
    }

    /// Why the daemon wrote a session's pty itself rather than letting the
    /// viewer do it. Recorded on the outcome so a caller — and the log — can
    /// tell "nobody was attached" from "somebody was attached and did not
    /// answer", which are the same write and completely different facts.
    enum DaemonWriteReason: String, Sendable {
        /// No viewer owns this pty, so the daemon is the only writer there is.
        /// The ordinary case, and the only one that is not a fallback.
        case detached
        /// The app answered, and its answer was that nothing took the bytes.
        /// Trustworthy — every refusal the app can know synchronously reports
        /// `false` — so this is the one fallback that is certain not to
        /// duplicate.
        case viewerReportedNothingWritten
        /// The injection frame could not be put on the sidecar at all, so the
        /// app never saw it.
        case viewerFrameUndeliverable
        /// No ack arrived within `ackDeadline`. **This is the branch that can
        /// duplicate**, and it is meant to.
        case ackDeadlineElapsed
    }

    enum Delivery: Sendable, Equatable {
        /// The app acknowledged that it wrote the bytes. "Handed to a
        /// transport", not "the child read them" — the app's own write
        /// completes asynchronously, so no stronger claim is available.
        case viewerWrote
        /// The daemon wrote to its own dup of the pty.
        case daemonWrote(DaemonWriteReason)
        /// Nothing was written, and this is the reason a caller is told.
        case notDelivered(String)
    }

    /// Puts one encoded frame on the app sidecar. Throws when there is no
    /// connected app to put it on.
    private let sendFrame: @Sendable (Data) async throws -> Void
    /// The attach generation a viewer holds this session's pty under, or nil
    /// when the daemon still owns it. The routing decision, and the only thing
    /// this type asks about attach state.
    private let viewerAttachment: @Sendable (UUID) async -> UInt64?
    /// Writes to the daemon's own dup of the session's pty. Throws when the
    /// daemon holds no descriptor for it — which, today, is the normal state
    /// while a viewer is attached; see `deliver`'s note.
    private let writeDirectly: @Sendable (UUID, Data) async throws -> Void
    private let ackDeadline: Duration
    private let clock: any Clock<Duration>

    /// The largest injection this courier will put on the sidecar — the
    /// same cap `sendInput` and `sendPaste` enforce, for two reasons that are
    /// both worse than the send being refused.
    ///
    /// The app's frame scanner reads a declared length past its 4 MiB hard cap
    /// as corruption: it sets `isDesynced` and the receive loop closes the
    /// sidecar, which takes control-mode input down **app-wide** until the app
    /// reconnects — and a sidecar-only death with the RPC socket intact has no
    /// recovery at all. Separately, `FDVendingServer.sendFrame` is a
    /// synchronous blocking send *on the actor*, so a multi-MiB payload to a
    /// slow app parks the whole fd-vending actor for every session.
    ///
    /// Nothing composes a send this large today — reachability from the RPC
    /// front end is unconfirmed — which is the reason to have the cap rather
    /// than a reason to skip it: an unreachable refusal costs nothing, and the
    /// failure it prevents is not local to the send that caused it.
    static let maxInjectionBytes = SidecarFrameCodec.maxPasteBytes

    /// Injections whose ack has not arrived and whose deadline has not fired.
    /// Keyed by the injection's own id, so an ack can be matched to exactly
    /// the injection it answers and a late one can be recognized as late.
    private var waiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]

    /// How many acks arrived for an injection that was no longer waiting.
    /// Test-facing, and the instrument for the property that matters most
    /// here: a late ack must be *observed and ignored*, never allowed to
    /// suppress or retract the direct write that already happened.
    private(set) var lateAcksObserved = 0

    init(
        sendFrame: @escaping @Sendable (Data) async throws -> Void,
        viewerAttachment: @escaping @Sendable (UUID) async -> UInt64?,
        writeDirectly: @escaping @Sendable (UUID, Data) async throws -> Void,
        ackDeadline: Duration = HolderInputTiming.injectionAckDeadline,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sendFrame = sendFrame
        self.viewerAttachment = viewerAttachment
        self.writeDirectly = writeDirectly
        self.ackDeadline = ackDeadline
        self.clock = clock
    }

    /// Deliver `bytes` to `terminalID`'s child, by whichever route owns the
    /// pty right now.
    ///
    /// One call is **one message**: the caller composes everything the send
    /// means — envelope, body, and the carriage return that submits it — and
    /// hands it over whole, so a payload is never split across a routing
    /// decision and never interleaved with another daemon write. The
    /// per-terminal send serializer upstream is what keeps two callers'
    /// messages apart.
    ///
    /// **Known gap, and the honest statement of it.** Once a viewer has
    /// *acknowledged* an attach the daemon has released its reader and closed
    /// its descriptor (`HolderRegistry.confirmAttach` → `HolderReader.stop`),
    /// so `writeDirectly` has nothing to write to and the fail-open fallback
    /// reports `.notDelivered` instead of writing. Nothing is lost silently —
    /// the caller is told, and the actuation row records a transport failure —
    /// but in that state the fallback is not yet the fail-open the spec
    /// describes. Closing it means the daemon keeping a **write-only** dup
    /// across an attach (the one-reader invariant is about readers; multiple
    /// writers to a pty master are fine), which is an ownership change
    /// belonging to the detach and app-death work, not here.
    ///
    /// **The gap is not every attached state, and the exceptions matter.**
    /// `viewerAttachment` means "a viewer *may* hold this pty", and two states
    /// leave the daemon's descriptor open underneath it:
    ///
    /// - **A timed-out attach.** `HolderRegistry.cancelPendingAttach`'s
    ///   `.unacknowledged` arm records the claim and deliberately leaves the
    ///   slot `.adopted` with its reader merely `.suspended` — the descriptor
    ///   is still open, and `HolderReader.write` guards only on `.stopped`. So
    ///   `viewerAttachment != nil` **and** `reader(for:) != nil`, and the
    ///   fallback really fires and really writes. That is the case fail-open
    ///   exists for above all others: the app is presumed hung or dead.
    /// - **The vended-but-not-yet-acked window.** `beginAttach` records a
    ///   pending attach but no `viewerAttachment`, so this method takes the
    ///   *detached* branch and writes through that same suspended reader —
    ///   while the app already holds its `dup` of the descriptor
    ///   (`TerminalPanelView.startHolderClient` takes it before
    ///   `attach.ready`) and may already be writing keystrokes. Two writers,
    ///   for one RPC round trip. Narrow, not zero.
    func deliver(terminalID: UUID, bytes: Data) async -> Delivery {
        guard await viewerAttachment(terminalID) != nil else {
            return await writeFromDaemon(terminalID: terminalID, bytes: bytes, because: .detached)
        }
        guard bytes.count <= Self.maxInjectionBytes else {
            // Refused, not fallen back on: the app is attached, and there is
            // no route for a payload this size that does not cost more than
            // the send is worth. The caller is told, by size, at once.
            let message = """
                terminal \(terminalID.uuidString) is open in the app and this send is \
                \(bytes.count) bytes, past the \(Self.maxInjectionBytes)-byte injection cap — \
                nothing was typed. A frame that large is read as corruption by the app's \
                sidecar, which closes it and takes every pane's input with it.
                """
            Self.logger.error("\(message, privacy: .public)")
            return .notDelivered(message)
        }
        let injectionID = UUID()
        do {
            let frame = try SidecarFrameCodec.encodeInjection(
                header: SidecarInjectionHeader(terminalID: terminalID, injectionID: injectionID),
                bytes: bytes)
            try await sendFrame(frame)
        } catch {
            Self.logger.error("""
                could not put an injection for session \(terminalID.uuidString, privacy: .public) \
                on the app sidecar: \(error.localizedDescription, privacy: .public)
                """)
            return await writeFromDaemon(
                terminalID: terminalID, bytes: bytes, because: .viewerFrameUndeliverable)
        }
        switch await awaitAck(injectionID) {
        case .some(true):
            return .viewerWrote
        case .some(false):
            return await writeFromDaemon(
                terminalID: terminalID, bytes: bytes, because: .viewerReportedNothingWritten)
        case .none:
            return await writeFromDaemon(
                terminalID: terminalID, bytes: bytes, because: .ackDeadlineElapsed)
        }
    }

    /// Record the app's answer to one injection.
    ///
    /// `nonisolated` and fire-and-forget because the caller is the sidecar's
    /// receive thread, which has nothing to await on and nobody to report to.
    nonisolated func acknowledge(_ ack: SidecarInjectionAck) {
        Task { await self.record(ack) }
    }

    private func record(_ ack: SidecarInjectionAck) {
        guard let waiter = waiters.removeValue(forKey: ack.injectionID) else {
            // Late: this injection's deadline already fired and the daemon
            // wrote it directly. Counted and logged, and deliberately nothing
            // else — the write that happened cannot be taken back, and trying
            // to suppress the duplicate is how at-least-once quietly becomes
            // at-most-once.
            lateAcksObserved += 1
            Self.logger.info("""
                injection \(ack.injectionID.uuidString, privacy: .public) was acknowledged \
                (written=\(ack.written, privacy: .public)) after its deadline had already \
                elapsed; the daemon has written it as well, so the session may show it twice
                """)
            return
        }
        waiter.resume(returning: ack.written)
    }

    /// Wait for the app's answer, or for the deadline. `nil` means the
    /// deadline won.
    private func awaitAck(_ injectionID: UUID) async -> Bool? {
        let deadline = Task { [clock, ackDeadline] in
            // Inherits this actor's isolation, so `expire` lands on the same
            // executor `record` does and the two cannot both resolve one
            // waiter. Non-throwing on cancellation: `try?` swallows the
            // `CancellationError` the `defer` below produces, and the guard
            // then stops a cancelled deadline from expiring an injection that
            // was answered.
            try? await clock.sleep(for: ackDeadline)
            guard !Task.isCancelled else { return }
            await self.expire(injectionID)
        }
        defer { deadline.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            waiters[injectionID] = continuation
        }
    }

    private func expire(_ injectionID: UUID) {
        guard let waiter = waiters.removeValue(forKey: injectionID) else { return }
        waiter.resume(returning: nil)
    }

    private func writeFromDaemon(
        terminalID: UUID, bytes: Data, because reason: DaemonWriteReason
    ) async -> Delivery {
        do {
            try await writeDirectly(terminalID, bytes)
            if reason != .detached {
                Self.logger.error("""
                    a viewer owns session \(terminalID.uuidString, privacy: .public)'s pty but \
                    did not take this injection (\(reason.rawValue, privacy: .public)), so the \
                    daemon wrote it directly; if the app wrote it too, the session shows it twice
                    """)
            }
            return .daemonWrote(reason)
        } catch {
            let message = Self.failureMessage(
                terminalID: terminalID, reason: reason, error: error)
            Self.logger.error("\(message, privacy: .public)")
            return .notDelivered(message)
        }
    }

    /// The text a caller reads when nothing was written. Names which of the two
    /// situations it is, because the remedies differ: a detached session that
    /// cannot be written to is a broken session, while an attached one that
    /// could not be reached is a viewer problem the caller can resolve by
    /// closing the tab.
    private static func failureMessage(
        terminalID: UUID, reason: DaemonWriteReason, error: Swift.Error
    ) -> String {
        switch reason {
        case .detached:
            return """
                terminal \(terminalID.uuidString) runs on the pty-holder transport and the \
                daemon could not write to its pty: \(error.localizedDescription) — nothing was \
                typed.
                """
        case .viewerReportedNothingWritten, .viewerFrameUndeliverable, .ackDeadlineElapsed:
            return """
                terminal \(terminalID.uuidString) is open in the app, which did not take this \
                send (\(reason.rawValue)), and the daemon could not write to its pty either: \
                \(error.localizedDescription) — nothing was typed. Closing the terminal's tab \
                hands the session back to the daemon.
                """
        }
    }
}
