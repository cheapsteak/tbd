import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "limitResume")

/// The tmux surface the actuator needs. `TmuxManager` conforms; tests fake it.
/// All sends go through the SAME methods `handleTerminalSend` uses — never
/// raw tmux invocations (spec constraint) — and, since this actuator types
/// without a user gesture, behind the SAME target consultation
/// (`paneSendTarget`) that `handleTerminalSend` runs before it types.
public protocol ResumeSendingTmux: Sendable {
    func windowExists(server: String, windowID: String) async -> Bool
    func paneInMode(server: String, paneID: String) async throws -> Bool
    func panePID(server: String, paneID: String) async throws -> String
    func paneSendTarget(server: String, paneID: String) async throws -> PaneSendTarget
    func sendKeys(server: String, paneID: String, text: String) async throws
    func sendKey(server: String, paneID: String, key: String) async throws
}

extension TmuxManager: ResumeSendingTmux {}

/// Finds the pane's foreground Claude process. `#{pane_current_command}`
/// reports `zsh` on macOS, so we walk the pane PID's process tree and check
/// `ps -o stat=` for the `+` (foreground process group) flag instead
/// (spec §Actuation 3).
public protocol PaneProcessInspecting: Sendable {
    /// PID of the Claude process that owns the pane's tty foreground group,
    /// or nil when Claude is not foreground (bare shell, editor, …).
    func foregroundClaudePID(panePID: Int32) -> Int32?
}

public struct ProductionPaneProcessInspector: PaneProcessInspecting {
    private let signaller: any ProcessSignaller

    public init(signaller: any ProcessSignaller = ProductionProcessSignaller()) {
        self.signaller = signaller
    }

    public func foregroundClaudePID(panePID: Int32) -> Int32? {
        // Candidates: pane PID itself (zsh may have exec'd into Claude),
        // its children, and grandchildren (wrapper-shell spawns).
        var candidates: [Int32] = [panePID]
        let children = signaller.children(ofServerPID: panePID)
        candidates += children
        for child in children {
            candidates += signaller.children(ofServerPID: child)
        }
        for pid in candidates {
            guard let stat = signaller.stat(pid), stat.contains("+"),
                  let command = signaller.commandLine(pid)?.lowercased(),
                  command.contains("claude")
            else { continue }
            return pid
        }
        return nil
    }
}

/// Runs one actuation attempt for a scheduled resume: eligibility checks, the
/// send — tmux's Escape/continue/Enter key sequence, or the holder transport's
/// two writes of the same three things — and post-send verification, which is
/// the same for both because it reads hook-fed state and the transcript rather
/// than anything the transport can see.
public struct LimitResumeActuator: LimitResumeActuating {

    // MARK: - Timing constants (spec §Actuation 5-6)

    static let interKeyPause: Duration = .milliseconds(150)
    /// The literal typed into the pane, recorded verbatim in the rail's row.
    static let continueMessage = "continue"

    /// The one refusal text this rail returns for a holder-backed row while
    /// holder hibernation is off, so the notification, the log line and this
    /// file's tests all name the same reason rather than three near-misses.
    /// Same fact and the same repair as
    /// `HibernationCoordinator.holderTransportRefusal`, which is the other half
    /// of what that flag gates.
    ///
    /// Written to complete the daemon's sentence: the notification reads
    /// "Auto-resume failed — \(reason). Claude may still be parked at the
    /// limit screen."
    static let holderTransportRefusal =
        "this session runs on the pty-holder transport and holder hibernation is off "
        + "(Settings → Hibernate pty-holder sessions, or `tbd config "
        + "holder-hibernation on`), so nothing was typed"

    /// The refusal for a daemon that has no way to write to a holder's pty at
    /// all — mock mode, or a daemon whose registry (and so whose injection
    /// courier) was never built. Kept apart from `holderTransportRefusal`
    /// because the two are different repairs: one is a flag the user can turn
    /// on, the other is a daemon that cannot serve this transport at all.
    static let holderInputPathMissing = "this daemon has no holder input path"

    /// The failure for a write the holder input path took and could not
    /// deliver. Distinct from the two refusals above: the rail tried.
    static let holderWriteRefused =
        "the resume could not be written to the holder-backed session"

    /// The first of the holder arm's two writes: `ESC`, alone — one byte.
    ///
    /// The whole send is `ESC`, then `interKeyPause`, then
    /// `holderContinuePayload`, which is the tmux arm's Escape/pause/text
    /// timing expressed in raw bytes. There is no named-key table on this
    /// transport (the child-as-contract-party design,
    /// `docs/specs/2026-09-05-child-as-contract-party-design.md`, is where one
    /// comes from: choosing bytes for a named key needs the child's cursor-key
    /// mode), so the two keys this rail needs are written as the bytes a
    /// terminal delivers for them — `0x1B` for Escape, `0x0D` for Return.
    ///
    /// **Why `ESC` gets a write and a pause of its own.** An ink-style input
    /// parser reads `ESC` immediately followed by a printable byte as a meta
    /// key, so `ESC` and the text arriving in one read compose Alt-c and then
    /// "ontinue" — deterministically, on every attempt, which is why the retry
    /// in `actuate` could not recover it. The pause goes through the same
    /// `waiter` seam as the tmux arm's, so tests advance it virtually and only
    /// production sleeps.
    static let holderEscapePayload = Data([0x1B])

    /// The second of the holder arm's two writes: the literal and the carriage
    /// return that submits it — 9 bytes, one write.
    ///
    /// **Text and carriage return together, unlike Escape.** Nothing composes
    /// them into a different key, and a message split across two courier calls
    /// can be split across a routing decision — `HolderInjectionCourier` picks
    /// the viewer or the daemon per call, so two calls are two independent
    /// routings. `performHolderSend` composes its own body and `\r` as one
    /// write for exactly that reason.
    ///
    /// **And no bracketed-paste wrapper.** Claude Code's stdin tokenizer
    /// swallows the trailing `\r` of any single *unwrapped* write of 64 bytes
    /// or more (measured on 2.1.261: 63 bytes submits, 64 does not). The
    /// wrappers are the fix, and they are correct only when the child has
    /// bracketed-paste mode on, which the daemon's emulator does not yet
    /// expose. At 9 bytes this write is far under that threshold, so it
    /// submits as bare bytes and needs no wrapper.
    static let holderContinuePayload = Data((continueMessage + "\r").utf8)

    static let verifyPollInterval: Duration = .seconds(1)
    static let verifyPolls = 20   // ~20s window

    private let db: TBDDatabase
    private let tmux: any ResumeSendingTmux
    private let inspector: any PaneProcessInspecting
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
    /// input path at all (mock mode, or no holder registry), which the holder
    /// arm refuses by name rather than by pretending the transport is the
    /// problem.
    ///
    /// The seam is the courier reduced to what this rail needs — bytes in, a
    /// yes/no out — so the actuator neither imports the holder subsystem nor
    /// has to fake an actor to be tested.
    private let holderSend: (@Sendable (UUID, Data) async -> Bool)?
    /// Whether the holder session behind a terminal has ended, as the daemon's
    /// registry last heard it — this transport's answer to `windowExists`.
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

    /// `holderSend` and `holderSessionEnded` default to `nil` so every existing
    /// call site — and every test that has no holder row in it — constructs the
    /// actuator unchanged.
    public init(
        db: TBDDatabase,
        tmux: any ResumeSendingTmux,
        inspector: any PaneProcessInspecting,
        readTranscript: @escaping @Sendable (String) -> Data?,
        transcriptModifiedAt: @escaping @Sendable (String) -> Date?,
        waiter: @escaping @Sendable (Duration) async -> Void,
        actuationLog: ActuationLog,
        holderSend: (@Sendable (UUID, Data) async -> Bool)? = nil,
        holderSessionEnded: (@Sendable (UUID) async -> Bool)? = nil
    ) {
        self.db = db
        self.tmux = tmux
        self.inspector = inspector
        self.readTranscript = readTranscript
        self.transcriptModifiedAt = transcriptModifiedAt
        self.waiter = waiter
        self.actuationLog = actuationLog
        self.holderSend = holderSend
        self.holderSessionEnded = holderSessionEnded
    }

    /// Early-cancel probe (see `LimitResumeActuating.userAlreadyContinued`).
    /// Read-only: no tmux calls, no writes, and — thanks to the mtime
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
            // copy-mode entered, the user typed manually, the terminal died.
            if attempt > 1 {
                switch await checkEligibility(resume) {
                case .eligible(let ctx): context = ctx
                case .notEligible(let outcome): return outcome
                }
            }

            // The rail's own request row, immediately before the keys go out.
            // The Escape, the literal "continue" and the Enter are sub-steps of
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

            switch context.delivery {
            case .tmux(let server, let paneID):
                do {
                    try await Self.sendContinueSequence(
                        tmux: tmux, server: server, paneID: paneID, waiter: waiter)
                    await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
                } catch {
                    await actuationLog.appendOutcome(
                        confirms: actuationID, result: .transportFailed, error: "\(error)")
                    // Treat a thrown send like a failed verification: retry
                    // (with a fresh eligibility re-check) rather than failing
                    // instantly — only give up after attempt 2 also fails.
                    logger.warning("actuate: send threw on attempt \(attempt, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            case .holder(let send):
                // Not retried, unlike a thrown tmux send. A wedged tmux server
                // is a transient the next attempt may find recovered; the
                // courier has already exhausted its own routes by the time it
                // answers no — viewer, then the daemon's own descriptor — so a
                // second identical write would take the same route to the same
                // answer, ~20s of verification later. Either write answering no
                // ends the actuation the same way: half a send is not a send.
                guard await sendHolderContinue(send: send, terminalID: context.terminalID) else {
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
            }
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

    /// How an eligible pass will put the resume into the session.
    ///
    /// Typed rather than a transport flag plus optional coordinates, so the
    /// holder arm cannot reach for a pane id that a holder row does not have
    /// and the tmux arm cannot reach for a seam that may be nil: whichever
    /// case a pass produced carries exactly what its send needs.
    private enum ResumeDelivery {
        case tmux(server: String, paneID: String)
        case holder(send: @Sendable (UUID, Data) async -> Bool)
    }

    private struct EligibilityContext {
        let delivery: ResumeDelivery
        let terminalID: UUID
        let worktreeID: UUID
        let transcriptPath: String?
        /// Transcript bytes read during THIS eligibility pass's
        /// user-already-continued check (step 2) — reused as the growth
        /// baseline for verification of the send this context leads to.
        let preSendTranscriptData: Data?
    }

    /// Runs eligibility steps 1-4 (spec §Actuation), in order: terminal
    /// alive → user-already-continued → Claude foreground → copy-mode.
    /// The transport branches between the terminal lookup and everything else,
    /// because every one of those steps addresses a tmux pane and a
    /// holder-backed row has none — see `holderEligibility` for what that arm
    /// keeps and what it drops.
    /// Foreground is checked before copy-mode so a dead/backgrounded shell
    /// classifies `.failed` rather than endlessly rescheduling on a stale
    /// copy-mode flag. Two additional checks (0a the row's own limitType-aware toggle, 1b row
    /// status) run on every pass too — they aren't in the spec's numbered
    /// list but close the same "state changed during a prior attempt's ~20s
    /// verify window" gap the spec's steps 1-4 already cover for the other
    /// cancellation reasons.
    private func checkEligibility(_ resume: ScheduledResume) async -> EligibilityCheckResult {
        // 0a. Toggle-off-mid-flight: the row's own gate — autoResumeOnApiError
        //     for api_error rows, autoResumeOnLimitReset for everything else
        //     (spec 2026-07-08 §Gating) — can be switched off while a prior
        //     attempt's ~20s verify window is running. This check runs on
        //     EVERY call to `checkEligibility` (the initial pass and every
        //     attempt>1 re-check in `actuate`), so attempt 2 never fires
        //     after the user turns the row's gate off mid-flight.
        //
        //     One config read serves both this gate and the holder arm's
        //     below, so a single pass cannot act on two different snapshots of
        //     the same row.
        guard let config = try? await db.config.get(),
              config.autoResumeEnabled(forLimitType: resume.limitType) else {
            return .notEligible(.cancelledExternally)
        }

        // 1. Terminal alive AND not parked. Under the unified park model a
        //    parked session's pane has been respawned to a bare shell (its
        //    claude process is gone) and is marked via `hibernatedAt`
        //    (authoritative) or a legacy `suspendedAt` — either way `isParked`.
        //    Never fire keys into a parked pane: parking already cancels the
        //    pending row (spec §Cancellation), so this is the fire-time backstop
        //    for a park that raced the scheduler. Classify as `.terminalGone`
        //    (cancel silently), same as a dead window.
        guard let terminal = ((try? await db.terminals.get(id: resume.terminalID)) ?? nil)
        else { return .notEligible(.terminalGone) }

        // Transport, ahead of every remaining check — including the parked rail
        // and the worktree lookup, which exists only to name a tmux server this
        // row does not have. EVERY step below this point addresses a tmux pane:
        // `windowExists`, the pane-identity consultation, `panePID`, copy-mode,
        // and finally the keys themselves. A holder row's `tmuxWindowID` and
        // `tmuxPaneID` are the empty string by construction, so without this
        // branch the rail exited at step 1 with `.terminalGone` — silently
        // cancelling the user's armed auto-resume on a session that is
        // perfectly alive, and recording "the terminal is gone" for a row that
        // is not.
        //
        // That accident was also fragile rather than safe: it rested entirely
        // on `TmuxManager.windowExists` swallowing its error and answering
        // `false` for an empty window id. Any future change to that answer
        // would have sent this rail on to type "continue" at whatever pane the
        // empty coordinate resolved to.
        //
        // Served rather than refused when holder hibernation is on: the
        // transport now has an input path (`holderSend`), and this rail is
        // gated by that same flag because a resume it delivers is the other
        // half of a park it can undo.
        if terminal.transport == .holder {
            // Off the same snapshot step 0a read, and already carrying the
            // shipped default for an install where nobody has chosen
            // (`ConfigRecord.toModel` applies it).
            return await holderEligibility(
                resume, terminal: terminal,
                hibernationEnabled: config.holderHibernationEnabled)
        }

        guard !terminal.isParked,
              let worktree = ((try? await db.worktrees.getLocal(id: terminal.worktreeID)) ?? nil)
        else { return .notEligible(.terminalGone) }
        let server = worktree.tmuxServer
        guard await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID) else {
            return .notEligible(.terminalGone)
        }

        // 1a. Ask the pane who it is, before any key is typed into it.
        //     `windowExists` above proves a window id resolves to SOME window;
        //     it cannot prove the pane still belongs to THIS terminal. tmux
        //     reuses pane ids, so a stale `tmuxPaneID` names a live stranger
        //     that passes every remaining check — window alive, Claude
        //     foreground, not in copy-mode — and then gets "continue" typed
        //     into it. That is issue #384 as it was actually observed: this
        //     actuator, not a human's `terminal.send`, was the thing typing.
        //
        //     Same rule as the send path: refusal requires POSITIVE
        //     disagreement. A pane that answers with no identity is sent to
        //     exactly as before, so panes predating the stamp do not regress.
        switch await paneTargetVerdict(server: server, terminal: terminal) {
        case .proceed:
            break
        case .notEligible(let outcome):
            return .notEligible(outcome)
        }

        // 1b. Explicit-cancel-mid-flight: the row itself can be cancelled
        //     (`cancelPending`/`cancelAllPending`) while a prior attempt's
        //     verify window is running — e.g. the user clicked "Cancel
        //     scheduled resume". Re-checking the row's own status here
        //     (same every-call guarantee as 0a) closes that gap too. Placed
        //     after the terminal-alive check (not at the very top) so a
        //     terminal/row that was never persisted at all (defensive
        //     callers, tests) still classifies via step 1's `.terminalGone`
        //     rather than this row lookup.
        guard ((try? await db.scheduledResumes.get(id: resume.id)) ?? nil)?.status == .pending else {
            return .notEligible(.cancelledExternally)
        }

        // 2. User already continued? Any transcript record newer than the
        //    detection instant means yes — send nothing. Same predicate the
        //    scheduler's early pass runs (`transcriptContinuation`), but
        //    ungated: keep this read around as the pre-send baseline for
        //    growth verification — a fresh read later would race ahead of
        //    the baseline on a fast-growing transcript and make growth
        //    undetectable.
        let continuation = transcriptContinuation(
            path: terminal.transcriptPath, since: resume.createdAt, mtimeGated: false)
        if continuation.alreadyContinued {
            return .notEligible(.userAlreadyContinued)
        }
        let preSendTranscriptData = continuation.data

        // 3. Claude must be the pane's FOREGROUND process (+ flag). Never
        //    type into a bare shell.
        guard let panePIDString = try? await tmux.panePID(server: server, paneID: terminal.tmuxPaneID),
              let panePID = Int32(panePIDString),
              inspector.foregroundClaudePID(panePID: panePID) != nil
        else {
            return .notEligible(.failed("Claude is not the pane's foreground process"))
        }

        // 4. Copy-mode: typing would go to the mode; cancelling copy-mode
        //    would yank the user out of scrollback. Reschedule instead.
        if (try? await tmux.paneInMode(server: server, paneID: terminal.tmuxPaneID)) == true {
            return .notEligible(.paneInCopyMode)
        }

        return .eligible(EligibilityContext(
            delivery: .tmux(server: server, paneID: terminal.tmuxPaneID),
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            transcriptPath: terminal.transcriptPath, preSendTranscriptData: preSendTranscriptData))
    }

    /// Eligibility for a holder-backed row: the transport-agnostic rails of
    /// `checkEligibility`, with every tmux-shaped step dropped.
    ///
    /// Dropped, and why each one is tmux's alone:
    ///
    /// - **`windowExists` and the worktree lookup.** Both name a tmux server
    ///   and window this row does not have. A holder session's liveness is its
    ///   child process, and the courier addresses it by terminal id — so the
    ///   liveness question is not dropped, it is asked of a different oracle:
    ///   `holderSessionEnded`, in the same position and with the same silent
    ///   `.terminalGone` cancel.
    /// - **The pane-identity consultation (step 1a).** It exists because tmux
    ///   reuses pane ids, so a stale coordinate can name a live stranger. There
    ///   is no coordinate here to go stale: a holder row's pane id is `""` by
    ///   construction, and the write is addressed to the terminal id itself,
    ///   which nothing reuses.
    /// - **`panePID` and the foreground check (step 3).** Both walk the process
    ///   tree under a pane's shell. The holder's child IS the agent — there is
    ///   no shell in front of it to be foreground instead of it.
    /// - **Copy-mode (step 4).** tmux's scrollback mode. A holder session's
    ///   scrollback belongs to whichever emulator is reading it, and there is
    ///   no mode for typing to land in.
    ///
    /// Kept, because none of them was ever about tmux: the flag, the parked
    /// backstop, the row's own cancellation status (1b), and the
    /// user-already-continued check (2) — which also produces the pre-send
    /// growth baseline `verifyResumed` compares against, so skipping it would
    /// leave `preSize == 0` and make any later read look like a resume.
    private func holderEligibility(
        _ resume: ScheduledResume, terminal: Terminal, hibernationEnabled: Bool
    ) async -> EligibilityCheckResult {
        // The flag. Off, this rail refuses by name and `.failed` rather than
        // silently cancelling, because a user who armed auto-resume and will
        // not get it should be told once, not left watching a limit screen
        // behind an "auto-resume scheduled" badge that quietly expired.
        guard hibernationEnabled else {
            logger.info("""
                actuate: terminal \(terminal.id.uuidString, privacy: .public) runs on the \
                pty-holder transport and holder hibernation is off — typing nothing
                """)
            return .notEligible(.failed(Self.holderTransportRefusal))
        }

        // Parked: the same fire-time backstop as the tmux path, and the same
        // silent cancel. Parking already cancels the pending row; this catches
        // a park that raced the scheduler.
        guard !terminal.isParked else { return .notEligible(.terminalGone) }

        // Liveness, in the position `windowExists` occupies on the tmux arm and
        // with the same silent `.terminalGone` cancel. Without it the holder
        // arm had no liveness answer at all: a row whose child exited without
        // anything parking it would be typed at, and the write would land on a
        // pty nobody is reading — an armed resume reported as delivered on a
        // session that is over.
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

        // 1b, unchanged: the row itself can be cancelled while a prior
        // attempt's ~20s verify window runs.
        guard ((try? await db.scheduledResumes.get(id: resume.id)) ?? nil)?.status == .pending else {
            return .notEligible(.cancelledExternally)
        }

        // 2, unchanged — and ahead of the input-path check below on purpose:
        // a session that has already moved on wants the silent cancel, not a
        // notification saying auto-resume failed on it.
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
            delivery: .holder(send: send),
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            transcriptPath: terminal.transcriptPath,
            preSendTranscriptData: continuation.data))
    }

    /// What the pane consultation concluded for step 1a.
    private enum PaneTargetVerdict {
        case proceed
        case notEligible(ResumeActuationOutcome)
    }

    /// Classify one `paneSendTarget` consultation into an eligibility verdict.
    ///
    /// The outcomes mirror how this actuator already treats the same facts:
    /// a pane that is gone or whose process has exited is the `windowExists`
    /// case one level finer, so it cancels silently as `.terminalGone`. A pane
    /// that answers with a DIFFERENT terminal is not "gone" and not a
    /// transient state to retry — the row's coordinate is stale and will stay
    /// stale until something respawns the window, so retrying would only aim
    /// at the same stranger again. It fails the row with a message naming both
    /// ids, the way step 3's not-foreground check fails a row a retry cannot
    /// help either.
    private func paneTargetVerdict(
        server: String, terminal: Terminal
    ) async -> PaneTargetVerdict {
        let target: PaneSendTarget
        do {
            target = try await tmux.paneSendTarget(server: server, paneID: terminal.tmuxPaneID)
        } catch {
            // The consultation could not be RUN (a wedged tmux tripping the
            // subprocess timeout) — not an answer about the pane. Step 3's
            // `panePID` treats the same wedged server as `.failed`, and typing
            // into a pane we could not look at is exactly what this check
            // exists to stop.
            return .notEligible(.failed("could not verify the target pane: \(error)"))
        }

        switch target {
        case .missing:
            logger.info("""
                actuate: pane \(terminal.tmuxPaneID, privacy: .public) for terminal \
                \(terminal.id.uuidString, privacy: .public) no longer exists — cancelling
                """)
            return .notEligible(.terminalGone)
        case .dead:
            logger.info("""
                actuate: pane \(terminal.tmuxPaneID, privacy: .public) for terminal \
                \(terminal.id.uuidString, privacy: .public) is dead — cancelling
                """)
            return .notEligible(.terminalGone)
        case .live(let paneTerminalID):
            guard let paneTerminalID else {
                // Absence is not disagreement: a pane spawned before TBD
                // stamped identities carries none, and refusing on nothing
                // would break auto-resume for every such session.
                logger.debug("""
                    actuate: pane \(terminal.tmuxPaneID, privacy: .public) claims no terminal \
                    identity; proceeding without verifying it is terminal \
                    \(terminal.id.uuidString, privacy: .public)
                    """)
                return .proceed
            }
            guard paneTerminalID.caseInsensitiveCompare(terminal.id.uuidString) != .orderedSame
            else { return .proceed }
            logger.warning("""
                actuate: pane \(terminal.tmuxPaneID, privacy: .public) belongs to terminal \
                \(paneTerminalID, privacy: .public), not \
                \(terminal.id.uuidString, privacy: .public) — typing nothing
                """)
            return .notEligible(.failed("""
                tmux pane \(terminal.tmuxPaneID) now belongs to terminal \(paneTerminalID), \
                not the scheduled terminal \(terminal.id.uuidString) — nothing was sent \
                (tmux reuses pane ids, so this coordinate is stale)
                """))
        }
    }

    /// The exact production send sequence for the tmux arm (spec §Actuation 5);
    /// the holder arm's raw-bytes equivalent is `sendHolderContinue`:
    /// Escape first — at the limit, newer Claude Code opens the
    /// `/rate-limit-options` menu whose highlighted default can be "Upgrade
    /// your plan"; a blind Enter can confirm a paid upgrade. Escape
    /// dismisses and can never select. 150ms pauses — Claude's TUI drops
    /// keys during UI transitions ("ontinue"). Enter as a separate
    /// named-key call — text+Enter in one send-keys is treated as a
    /// bracketed paste (literal newline, nothing submits).
    ///
    /// Static + seam-typed so the live tmux test drives this very code path.
    public static func sendContinueSequence(
        tmux: any ResumeSendingTmux, server: String, paneID: String,
        waiter: (Duration) async -> Void
    ) async throws {
        try await tmux.sendKey(server: server, paneID: paneID, key: "Escape")
        await waiter(interKeyPause)
        try await tmux.sendKeys(server: server, paneID: paneID, text: continueMessage)
        await waiter(interKeyPause)
        try await tmux.sendKey(server: server, paneID: paneID, key: "Enter")
    }

    /// The holder arm's counterpart to `sendContinueSequence`: the same
    /// Escape/pause/text-and-submit shape, written as bytes.
    ///
    /// Two writes with `interKeyPause` between them — `holderEscapePayload`
    /// says why the pause is load-bearing rather than cosmetic here, and
    /// `holderContinuePayload` says why the literal and its carriage return
    /// stay together. The pause runs on the same injected `waiter` the tmux arm
    /// uses, so a test advances it and only production sleeps.
    ///
    /// Answers whether the whole sequence was delivered. A `false` from the
    /// first write skips the second: nothing is gained by typing "continue" at
    /// a session that did not take the Escape, and the caller reports one named
    /// failure either way.
    private func sendHolderContinue(
        send: @Sendable (UUID, Data) async -> Bool, terminalID: UUID
    ) async -> Bool {
        guard await send(terminalID, Self.holderEscapePayload) else { return false }
        await waiter(Self.interKeyPause)
        return await send(terminalID, Self.holderContinuePayload)
    }

    /// Success signal within ~20s: the activity hook reports `working`, or
    /// the transcript file grows (spec §Actuation 6).
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
