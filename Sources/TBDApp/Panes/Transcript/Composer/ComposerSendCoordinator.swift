import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "composer.send")

/// How a composed message leaves the app.
///
/// Two paths, and the branch between them is a machine fact rather than a guess:
/// a running session takes a paste, a parked one takes an argv on its respawn.
///
/// **Running.** `terminal.send` with the ordered parts list, the envelope
/// suppressed, and the awaiting-input gate opted in. The composer never uses the
/// keys path and never asks for verification.
///
/// **Not running.** `terminal.wake` with the message in its `prompt`, which the
/// daemon passes to the spawn builder as a trailing argument on
/// `claude --resume <id>` — atomic with the respawn, so no paste-readiness
/// question arises. An argument prompt cannot carry image attachments, so each
/// token is replaced inline with its quoted path; Claude reads the files with its
/// Read tool.
///
/// **And then it holds — on its own spawn.** A wake whose session id no longer
/// resolves makes Claude print one line and exit 1 with the prompt lost, while
/// tmux reports the respawn as a success, so the text stays held as *sending*
/// until the session reports in and is restored editable on timeout. But a
/// `SessionStart` on the same terminal is not that evidence: a competing wake, a
/// post-`--fork-session` recapture, and a person typing `claude --resume` in the
/// pane all produce one. The wake result names the incarnation the respawn
/// minted — the id the daemon planted in the child's environment as
/// `TBD_TERMINAL_INCARNATION_ID` and gets back on that process's hooks — and the
/// hold releases on the `SessionStart` carrying that id and on no other. A
/// `SessionStart` with a different id, or with none at all (a worktree's first
/// spawn, an archive restore), leaves it held.
@MainActor
final class ComposerSendCoordinator {
    enum Outcome: Equatable {
        case sent
        /// The wake landed and the session THIS wake started reported in.
        case woke
        /// Nothing was delivered, or delivery could not be confirmed. The caller
        /// restores the text and shows this message.
        case failed(message: String)
    }

    /// What a wake answered: the incarnation it minted, or why nothing happened.
    ///
    /// Three cases rather than an optional message, because the two failure
    /// shapes mean different things to a person: `.noOp` says the terminal was
    /// already live and the prompt went nowhere, while `.failed` says the
    /// session is gone. Collapsing them would make one of the two unreportable.
    ///
    /// The enum itself lives at file scope in `AppState+ComposerFocus.swift`,
    /// where the wake that produces it does; this is the name the send path
    /// reads it under.
    typealias WakeReply = ComposerWakeReply

    typealias Sender = @Sendable @MainActor (TerminalSendParams) async throws -> Void
    /// terminalID, worktreeID, prompt → what the wake answered.
    typealias Waker = @Sendable @MainActor (UUID, UUID, String) async -> WakeReply
    /// terminalID, incarnationID → true when THAT spawn's `SessionStart` arrives.
    /// Never on another id, never on none.
    typealias SessionStartWaiter = @Sendable @MainActor (UUID, UUID) async -> Bool

    /// How long the text is held as sending before it comes back editable.
    ///
    /// Sized against a cold `claude --resume` on a large session, not against
    /// impatience: the failure it bounds is a lost message, and restoring too
    /// early would show an error for a wake that was about to land.
    static let wakeHoldTimeout: Duration = .seconds(45)

    private let sendParams: Sender
    private let wake: Waker
    private let awaitSessionStart: SessionStartWaiter
    private let clock: any Clock<Duration>

    init(
        send: @escaping Sender,
        wake: @escaping Waker,
        awaitSessionStart: @escaping SessionStartWaiter,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sendParams = send
        self.wake = wake
        self.awaitSessionStart = awaitSessionStart
        self.clock = clock
    }

    func send(
        text: String, paths: [Int: String], state: ComposerState,
        terminalID: UUID, worktreeID: UUID
    ) async -> Outcome {
        let parts = ComposerTokens.parts(text: text, paths: paths)
        // A message that is nothing but whitespace names nothing — but one that
        // is nothing but an image token is a real message.
        let carriesSomething = parts.contains { part in
            switch part {
            case .text(let value):
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .imagePath:
                return true
            }
        }
        guard carriesSomething else {
            return .failed(message: "Nothing to send.")
        }

        switch state {
        case .hidden:
            return .failed(message: "This terminal has no composer.")
        case .blocked(let message):
            return .failed(message: message)
        case .running:
            return await sendToRunningSession(parts: parts, terminalID: terminalID)
        case .notRunning:
            return await wakeWith(
                text: text, paths: paths, terminalID: terminalID, worktreeID: worktreeID)
        }
    }

    // MARK: - Running

    private func sendToRunningSession(
        parts: [SendPart], terminalID: UUID
    ) async -> Outcome {
        do {
            try await sendParams(TerminalSendParams(
                terminalID: terminalID,
                submit: true,
                parts: parts,
                // The person is speaking in their own voice, exactly as at the
                // keyboard; Claude should see only the message. Suppression is a
                // request — the daemon authenticates the connection and decides.
                envelope: .suppressed,
                // The composer always opts in. A pasted body plus Enter into a
                // permission dialog commits whichever option is highlighted.
                gateOnAwaitingInput: true))
            return .sent
        } catch {
            logger.warning("""
            composer send failed for terminal \(terminalID.uuidString, privacy: .public): \
            \(error, privacy: .public)
            """)
            return .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Not running

    private func wakeWith(
        text: String, paths: [Int: String], terminalID: UUID, worktreeID: UUID
    ) async -> Outcome {
        let prompt = ComposerTokens.flattened(text: text, paths: paths)
        let incarnationID: UUID
        switch await wake(terminalID, worktreeID, prompt) {
        case .failed(let message):
            // Session gone, worktree missing, profile missing. Nothing was
            // delivered and there is nothing to wait for.
            return .failed(message: message)
        case .noOp:
            // `woken: false`. The terminal was already live, or another wake was
            // in flight, and the daemon delivered the prompt NOWHERE — which is
            // exactly what makes the parameter safe to pass while racing a
            // background wake. Surfaced, never held on.
            return .failed(message:
                "This terminal was already running, so the message was not "
                + "delivered. It is back in the box — try sending it again.")
        case .woken(let minted):
            guard let minted else {
                // The wake respawned and delivered the prompt, but named no
                // spawn — an older daemon, or a row that carried no incarnation.
                // There is nothing to scope a wait to, and waiting on "any
                // SessionStart" is exactly what this design rejects, so report
                // the delivery rather than hold until the timeout and show an
                // error for a message that landed.
                logger.debug("""
                wake for terminal \(terminalID.uuidString, privacy: .public) named no \
                incarnation; not entering the hold
                """)
                return .woke
            }
            incarnationID = minted
        }

        guard await holdUntilSessionStart(
            terminalID: terminalID, incarnationID: incarnationID)
        else {
            return .failed(message:
                "The session this send started did not report in within "
                + "\(Self.wakeHoldTimeout). Your message was not delivered — "
                + "it is back in the box.")
        }
        return .woke
    }

    /// Held as sending until THIS spawn says it started.
    ///
    /// Written duration-relative as a task-group race, which is the shape the
    /// existential clock supports and the shape a test can advance: the loser is
    /// cancelled, and the waiter answers `false` on cancellation rather than
    /// leaving a continuation nobody resumes.
    private func holdUntilSessionStart(
        terminalID: UUID, incarnationID: UUID
    ) async -> Bool {
        // Lifted into locals rather than captured off `self`: both are `Sendable`
        // on their own, and a capture list on a child closure is a shape the
        // region-based isolation checker cannot reason about.
        let waiter = awaitSessionStart
        let holdClock = clock
        return await withTaskGroup(of: Bool.self) { group in
            // No isolation annotation on the child: `waiter` is an async
            // `@MainActor` closure, so the call hops to the main actor by
            // itself. Spelling `@MainActor` on the closure instead is a shape
            // the region-based isolation checker rejects outright.
            group.addTask {
                await waiter(terminalID, incarnationID)
            }
            group.addTask {
                try? await holdClock.sleep(for: Self.wakeHoldTimeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
