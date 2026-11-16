import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "limitResume")

/// Runs one actuation attempt for a scheduled resume: eligibility checks, the
/// send — three writes to the holder session's pty (Escape, text, carriage
/// return) — and post-send verification, which reads the activity column —
/// written from the agent's own OSC 7501 reports — and the transcript rather
/// than anything the transport can see.
///
/// A row still on tmux is not typed at: TBD no longer types into tmux panes.
public struct LimitResumeActuator: LimitResumeActuating {

    // MARK: - Timing constants (spec §Actuation 5-6)

    static let interKeyPause: Duration = .milliseconds(150)

    /// The text typed into the pane, recorded verbatim in the rail's row.
    ///
    /// A bare "continue" is indistinguishable from a person typing it, and an
    /// agent in the tab can mistake it for a person's answer to an open
    /// question. The leading bracketed head says the text is automatic, so the
    /// agent, and any tool reading prompts, can tell this rail's text from a
    /// person's word. "continue" stays last, so the resume itself is
    /// unchanged. The head shape `[Automatic: <sender> typed this, not <who>.`
    /// is a convention for text no person typed; keep it exact.
    static let continueMessage =
        "[Automatic: TBD's auto-resume typed this, not a person. "
        + "It answers no question and approves nothing.] continue"

    /// The refusal for a daemon that has no way to write to a holder's pty at
    /// all — mock mode, or a daemon whose registry (and so whose injection
    /// courier) was never built. Written to complete the daemon's sentence: the
    /// notification reads "Auto-resume failed — \(reason). Claude may still be
    /// parked at the limit screen."
    static let holderInputPathMissing = "this daemon has no holder input path"

    /// The failure for a write the holder input path took and could not
    /// deliver. Distinct from the refusals: the rail tried.
    static let holderWriteRefused =
        "the resume could not be written to the holder-backed session"

    /// The refusal for a live row still on the tmux transport. Its agent may
    /// still be running in a tmux server an earlier build started, which is how
    /// it could arm a resume at all, and this version of TBD cannot type into
    /// it. Failed by name rather than cancelled silently, so the person hears
    /// that the resume did not happen. Written to complete the daemon's
    /// sentence, like `holderInputPathMissing`.
    static let tmuxSessionNotTyped =
        "this session runs in tmux, which this version of TBD can no longer type into"

    /// The first of the rail's three writes: `ESC`, alone — one byte.
    ///
    /// The whole send is `ESC`, `interKeyPause`, `holderContinueTextPayload`,
    /// `interKeyPause`, `holderSubmitPayload` — Escape, pause, text, pause,
    /// Enter, expressed in raw bytes. There is no
    /// named-key table on this transport (the child-as-contract-party design,
    /// `docs/specs/2026-09-05-child-as-contract-party-design.md`, is where one
    /// comes from: choosing bytes for a named key needs the child's cursor-key
    /// mode), so the two keys this rail needs are written as the bytes a
    /// terminal delivers for them — `0x1B` for Escape, `0x0D` for Return.
    ///
    /// **Why `ESC` gets a write and a pause of its own.** An ink-style input
    /// parser reads `ESC` followed by a printable byte as a meta key, and `ESC`
    /// followed by the text's leading `[` as a CSI introducer: `ESC` `[` `A`
    /// in one read is CSI A (cursor up), which leaves the composer holding
    /// `utomatic: …`. Either way the text is mangled deterministically on
    /// every attempt, which is why the retry in `actuate` could not recover
    /// it. The pause goes through the `waiter` seam, so tests advance it
    /// virtually and only production sleeps.
    static let holderEscapePayload = Data([0x1B])

    /// The second of the rail's three writes: the text, with no carriage
    /// return.
    ///
    /// **Why the carriage return is its own write.** Claude Code's stdin
    /// tokenizer swallows the trailing `\r` of any single unwrapped write of
    /// 64 bytes or more (measured on 2.1.261: 63 bytes submits, 64 does not).
    /// This text is 110 bytes. Measured on Claude Code 2.1.301 in an isolated
    /// tmux pane with this exact text: text and carriage return in one write
    /// left the text unsent in the composer; `ESC`, 150 ms, text, 150 ms, a
    /// lone carriage return submitted it.
    ///
    /// **Why not bracketed-paste wrapping**, which is what `terminal.send`'s
    /// `HolderSendComposition` does: it is correct only when the child has
    /// bracketed-paste mode on, and this rail has no oracle for that. The
    /// split needs none.
    ///
    /// **Splitting across courier calls is safe.** `HolderInjectionCourier`
    /// picks the viewer or the daemon per call, but each call awaits delivery
    /// before the next starts, so order holds across routes. A carriage return
    /// delivered twice by the courier's ack-deadline fallback is an Enter on an
    /// empty composer, which does nothing.
    static let holderContinueTextPayload = Data(continueMessage.utf8)

    /// The third of the rail's three writes: the carriage return that
    /// submits the text, alone. `holderContinueTextPayload` says why it is not
    /// appended to the text.
    static let holderSubmitPayload = Data([0x0D])

    static let verifyPollInterval: Duration = .seconds(1)
    static let verifyPolls = 20   // ~20s window

    private let db: TBDDatabase
    private let readTranscript: @Sendable (String) -> Data?
    /// Transcript mtime, kept separate from `readTranscript` so the
    /// early-cancel pre-filter is testable without touching the filesystem.
    private let transcriptModifiedAt: @Sendable (String) -> Date?
    /// Injectable sleep so unit tests run instantly.
    private let waiter: @Sendable (Duration) async -> Void
    /// The daemon's actuation record. This rail bypasses the RPC router, so it
    /// writes its own row — with no `method`, and an actor naming the rail.
    private let actuationLog: ActuationLog
    /// Writes bytes to one holder-backed session's pty, answering whether they
    /// were delivered. Production passes `HolderInjectionCourier.deliver`,
    /// which routes by who owns the pty; `nil` means this daemon has no holder
    /// input path at all (mock mode, or no holder registry), which the rail
    /// refuses by name rather than by pretending the transport is the problem.
    ///
    /// The seam is the courier reduced to what this rail needs — bytes in, a
    /// yes/no out — so the actuator neither imports the holder subsystem nor
    /// has to fake an actor to be tested.
    private let holderSend: (@Sendable (UUID, Data) async -> Bool)?
    /// Whether the holder session behind a terminal has ended, as the daemon's
    /// registry last heard it.
    ///
    /// Production passes "the last status this registry recorded is `.exited`
    /// or `.exitedStatusUnknown`", which is a POSITIVE report from the holder
    /// that its job is over. Nothing weaker is admissible here: in particular
    /// **the absence of a daemon reader is not evidence**, because a viewer
    /// holding the pty is the ordinary live state on this transport and would
    /// cancel every armed resume on a session the user is looking at.
    ///
    /// `nil` — mock mode, or no registry — behaves exactly as before: the rail
    /// asks nobody and proceeds to the courier, which fails by name if the
    /// session really is gone.
    private let holderSessionEnded: (@Sendable (UUID) async -> Bool)?

    /// `holderSend` and `holderSessionEnded` default to `nil`: mock mode and a
    /// daemon with no holder registry have neither.
    public init(
        db: TBDDatabase,
        readTranscript: @escaping @Sendable (String) -> Data?,
        transcriptModifiedAt: @escaping @Sendable (String) -> Date?,
        waiter: @escaping @Sendable (Duration) async -> Void,
        actuationLog: ActuationLog,
        holderSend: (@Sendable (UUID, Data) async -> Bool)? = nil,
        holderSessionEnded: (@Sendable (UUID) async -> Bool)? = nil
    ) {
        self.db = db
        self.readTranscript = readTranscript
        self.transcriptModifiedAt = transcriptModifiedAt
        self.waiter = waiter
        self.actuationLog = actuationLog
        self.holderSend = holderSend
        self.holderSessionEnded = holderSessionEnded
    }

    /// Early-cancel probe (see `LimitResumeActuating.userAlreadyContinued`).
    /// Read-only: no writes, and — thanks to the mtime
    /// pre-filter in `transcriptContinuation` — usually no file read either.
    /// A terminal that has vanished answers `false`; cancelling for THAT
    /// reason is fire time's job (`.terminalGone`), not this probe's.
    public func userAlreadyContinued(_ resume: ScheduledResume) async -> Bool {
        guard let terminal = ((try? await db.terminals.get(id: resume.terminalID)) ?? nil) else {
            return false
        }
        return transcriptContinuation(
            path: terminal.transcriptPath, since: resume.createdAt, mtimeGated: true
        ).alreadyContinued
    }

    /// The single copy of the "already continued" predicate: does the
    /// transcript hold a record newer than the limit-detection instant?
    /// Returns the bytes it read alongside the verdict (nil when the read
    /// was skipped or failed).
    ///
    /// `mtimeGated` selects the caller's cost profile:
    /// - `false` — fire-time eligibility (step 2). ALWAYS reads, because
    ///   those bytes double as the pre-send growth baseline for
    ///   `verifyResumed`; skipping would leave `preSize == 0` and make any
    ///   later read look like growth.
    /// - `true` — the scheduler's early pass, which runs every
    ///   `earlyCheckInterval` per pending row. Skips the whole-file read
    ///   entirely when the file's mtime is at or before `cutoff`: nothing
    ///   can have been appended since, and a long session's JSONL runs to
    ///   tens of MB. An absent/unreadable mtime is NOT read as
    ///   "unmodified" — it falls through to the read.
    private func transcriptContinuation(
        path: String?, since cutoff: Date, mtimeGated: Bool
    ) -> (alreadyContinued: Bool, data: Data?) {
        guard let path, !path.isEmpty else { return (false, nil) }
        if mtimeGated, let mtime = transcriptModifiedAt(path), mtime <= cutoff {
            return (false, nil)
        }
        guard let data = readTranscript(path) else { return (false, nil) }
        return (RateLimitDetection.hasRecord(newerThan: cutoff, in: data), data)
    }

    public func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome {
        // Attempt 1's eligibility pass also captures the pre-send transcript
        // baseline used for growth verification (see comment at `preSize`
        // below).
        let firstContext: EligibilityContext
        switch await checkEligibility(resume) {
        case .eligible(let ctx): firstContext = ctx
        case .notEligible(let outcome): return outcome
        }

        // The growth baseline is fixed at attempt 1's eligibility snapshot
        // for BOTH attempts — deliberately not re-baselined on attempt 2.
        // Re-snapshotting per attempt would let a transcript that grew
        // during a failed/late-landing attempt 1 mask itself as "no growth"
        // against attempt 2's fresh (already-grown) baseline; reusing the
        // original baseline means that growth still counts as resumed.
        let preSize = firstContext.preSendTranscriptData?.count ?? 0

        var context = firstContext
        for attempt in 1...2 {
            // Re-run eligibility (spec §Actuation "one retry of steps 1-5")
            // on every attempt except the first, which already ran it above.
            // State can change during a prior attempt's ~20s verify window:
            // the user typed manually, the session ended, the row was cancelled.
            if attempt > 1 {
                switch await checkEligibility(resume) {
                case .eligible(let ctx): context = ctx
                case .notEligible(let outcome): return outcome
                }
            }

            // The rail's own request row, immediately before the keys go out.
            // The Escape, the text and the Enter are sub-steps of
            // one send, so they share one row. Fail-closed: an unrecordable
            // send is not sent.
            var row = ActuationRow(
                actor: .daemon(rail: ActuationRail.limitResume), kind: .send)
            row.target = .local(worktree: context.worktreeID, terminal: context.terminalID)
            row.message = Self.continueMessage
            row.submit = true
            guard let actuationID = try? await actuationLog.appendRequest(row) else {
                return .failed("could not record the resume in the actuation log")
            }

            // Not retried on a refused write: the courier has already
            // exhausted its own routes by the time it answers no — viewer, then
            // the daemon's own descriptor — so a second identical write would
            // take the same route to the same answer, ~20s of verification
            // later. Any write answering no ends the actuation the same way:
            // half a send is not a send.
            guard await sendHolderContinue(send: context.send, terminalID: context.terminalID) else {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed,
                    error: Self.holderWriteRefused)
                logger.warning("""
                    actuate: the holder input path took nothing for terminal \
                    \(context.terminalID.uuidString, privacy: .public)
                    """)
                return .failed(Self.holderWriteRefused)
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
            if await verifyResumed(terminalID: context.terminalID,
                                   transcriptPath: context.transcriptPath,
                                   preSize: preSize) {
                return .sent
            }
            logger.warning("actuate: no resume signal after attempt \(attempt, privacy: .public) for terminal \(context.terminalID.uuidString, privacy: .public)")
        }
        return .failed("no activity within the verification window after 2 sends")
    }

    /// What one eligibility pass (spec §Actuation 1-4) concluded: either all
    /// checks passed (carrying what the send/verify steps need), or a check
    /// failed — in which case its outcome IS the actuation outcome.
    private enum EligibilityCheckResult {
        case eligible(EligibilityContext)
        case notEligible(ResumeActuationOutcome)
    }

    private struct EligibilityContext {
        /// The holder input path the send writes through.
        let send: @Sendable (UUID, Data) async -> Bool
        let terminalID: UUID
        let worktreeID: UUID
        let transcriptPath: String?
        /// Transcript bytes read during THIS eligibility pass's
        /// user-already-continued check (step 2) — reused as the growth
        /// baseline for verification of the send this context leads to.
        let preSendTranscriptData: Data?
    }

    /// Runs the eligibility checks on every pass, in order: the row's own
    /// limitType-aware toggle (0a), the terminal present and not parked (1),
    /// then the holder checks in `holderEligibility` — the session's liveness,
    /// the row's own status (1b), user-already-continued (2) and an input
    /// path. 0a and 1b are not in the spec's numbered list but close the same
    /// "state changed during a prior attempt's ~20s verify window" gap.
    ///
    /// The spec's foreground (3) and copy-mode (4) steps asked a tmux pane and
    /// have no counterpart on the pty holder, whose child is the agent and has
    /// no mode for typing to land in. A row still on tmux is not typed at.
    private func checkEligibility(_ resume: ScheduledResume) async -> EligibilityCheckResult {
        // 0a. Toggle-off-mid-flight: the row's own gate — autoResumeOnApiError
        //     for api_error rows, autoResumeOnLimitReset for everything else
        //     (spec 2026-07-08 §Gating) — can be switched off while a prior
        //     attempt's ~20s verify window is running. This check runs on
        //     EVERY call to `checkEligibility` (the initial pass and every
        //     attempt>1 re-check in `actuate`), so attempt 2 never fires
        //     after the user turns the row's gate off mid-flight.
        guard let config = try? await db.config.get(),
              config.autoResumeEnabled(forLimitType: resume.limitType) else {
            return .notEligible(.cancelledExternally)
        }

        // 1. Terminal present. A row that has gone cancels silently.
        guard let terminal = ((try? await db.terminals.get(id: resume.terminalID)) ?? nil)
        else { return .notEligible(.terminalGone) }

        // Parked: the fire-time backstop for a park that raced the scheduler —
        // parking already cancels the pending row. Cancelled silently,
        // whatever the transport: nothing runs behind a parked row.
        guard !terminal.isParked else { return .notEligible(.terminalGone) }

        guard terminal.transport == .holder else {
            logger.info("""
                actuate: terminal \(terminal.id.uuidString, privacy: .public) runs on tmux, \
                which this version of TBD no longer types into — typing nothing
                """)
            return .notEligible(.failed(Self.tmuxSessionNotTyped))
        }
        return await holderEligibility(resume, terminal: terminal)
    }

    /// Eligibility for a holder-backed, unparked row.
    ///
    /// The write is addressed to the terminal id itself, which nothing reuses,
    /// so there is no coordinate to go stale and no pane to ask who it is. The
    /// holder's child IS the agent, so there is no shell in front of it to be
    /// foreground instead of it.
    ///
    /// The user-already-continued check (2) also produces the pre-send growth
    /// baseline `verifyResumed` compares against, so skipping it would leave
    /// `preSize == 0` and make any later read look like a resume.
    private func holderEligibility(
        _ resume: ScheduledResume, terminal: Terminal
    ) async -> EligibilityCheckResult {
        // Liveness, with a silent `.terminalGone` cancel. Without it a row
        // whose child exited without anything parking it would be typed at,
        // and the write would land on a pty nobody is reading — an armed
        // resume reported as delivered on a session that is over.
        //
        // The evidence has to be positive, which is why the seam asks about the
        // holder's reported STATUS rather than about the daemon's reader.
        // `reader(for:)` answers which emulator is this session's, not whether
        // the session is alive: the registry keeps that reader across an attach
        // and hands out none while a slot is mid-adoption or mid-release. So
        // `reader(for:) == nil` names a transition as often as a death, and a
        // rail keyed on it would cancel auto-resumes on sessions that are
        // running.
        if let sessionEnded = self.holderSessionEnded, await sessionEnded(terminal.id) {
            logger.info("""
                actuate: terminal \(terminal.id.uuidString, privacy: .public) is holder-backed \
                and its holder reported the session over — cancelling
                """)
            return .notEligible(.terminalGone)
        }

        // 1b. Explicit-cancel-mid-flight: the row itself can be cancelled
        //     (`cancelPending`/`cancelAllPending`) while a prior attempt's
        //     verify window is running — e.g. the user clicked "Cancel
        //     scheduled resume". Re-checked here on every pass, as 0a is.
        guard ((try? await db.scheduledResumes.get(id: resume.id)) ?? nil)?.status == .pending else {
            return .notEligible(.cancelledExternally)
        }

        // 2. User already continued? Any transcript record newer than the
        //    detection instant means yes — send nothing. Same predicate the
        //    scheduler's early pass runs (`transcriptContinuation`), but
        //    ungated: this read is kept as the pre-send baseline for growth
        //    verification — a fresh read later would race ahead of the
        //    baseline on a fast-growing transcript and make growth
        //    undetectable. Ahead of the input-path check below on purpose: a
        //    session that has already moved on wants the silent cancel, not a
        //    notification saying auto-resume failed on it.
        let continuation = transcriptContinuation(
            path: terminal.transcriptPath, since: resume.createdAt, mtimeGated: false)
        if continuation.alreadyContinued {
            return .notEligible(.userAlreadyContinued)
        }

        guard let send = self.holderSend else {
            logger.warning("""
                actuate: terminal \(terminal.id.uuidString, privacy: .public) is holder-backed \
                and this daemon has no holder input path — typing nothing
                """)
            return .notEligible(.failed(Self.holderInputPathMissing))
        }

        return .eligible(EligibilityContext(
            send: send,
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            transcriptPath: terminal.transcriptPath,
            preSendTranscriptData: continuation.data))
    }

    /// The send: Escape, pause, text, pause, carriage return, as three writes.
    ///
    /// Escape first — at the limit, newer Claude Code opens the
    /// `/rate-limit-options` menu whose highlighted default can be "Upgrade
    /// your plan", and a blind Enter can confirm a paid upgrade. Escape
    /// dismisses and can never select. 150 ms pauses — Claude's TUI drops keys
    /// during UI transitions ("ontinue"), and the pause after Escape also keeps
    /// it from combining with the text's leading `[` into a CSI sequence.
    /// `holderEscapePayload` says why that first pause is load-bearing rather
    /// than cosmetic, and `holderContinueTextPayload` says why the carriage
    /// return is its own write. The pauses run on the injected `waiter`, so a
    /// test advances them and only production sleeps.
    ///
    /// Answers whether the whole sequence was delivered. A `false` from any
    /// write stops the sequence with no further writes: nothing is gained by
    /// typing at a session that did not take the Escape, and the caller reports
    /// one named failure either way.
    private func sendHolderContinue(
        send: @Sendable (UUID, Data) async -> Bool, terminalID: UUID
    ) async -> Bool {
        guard await send(terminalID, Self.holderEscapePayload) else { return false }
        await waiter(Self.interKeyPause)
        guard await send(terminalID, Self.holderContinueTextPayload) else { return false }
        await waiter(Self.interKeyPause)
        return await send(terminalID, Self.holderSubmitPayload)
    }

    /// Success signal within ~20s: the agent reports `working`, or the
    /// transcript file grows (spec §Actuation 6).
    private func verifyResumed(terminalID: UUID, transcriptPath: String?, preSize: Int) async -> Bool {
        for _ in 0..<Self.verifyPolls {
            if let terminal = ((try? await db.terminals.get(id: terminalID)) ?? nil),
               terminal.activityState == .working {
                return true
            }
            if let path = transcriptPath, !path.isEmpty,
               let size = readTranscript(path)?.count, size > preSize {
                return true
            }
            await waiter(Self.verifyPollInterval)
        }
        return false
    }
}
