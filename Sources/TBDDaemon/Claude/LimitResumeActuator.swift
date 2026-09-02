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

/// Runs one actuation attempt for a scheduled resume: eligibility checks,
/// the Escape/continue/Enter send sequence, and post-send verification.
public struct LimitResumeActuator: LimitResumeActuating {

    // MARK: - Timing constants (spec §Actuation 5-6)

    static let interKeyPause: Duration = .milliseconds(150)
    /// The literal typed into the pane, recorded verbatim in the rail's row.
    static let continueMessage = "continue"

    /// The one refusal text this rail returns for a holder-backed row, so the
    /// notification, the log line and this file's tests all name the same
    /// reason rather than three near-misses.
    ///
    /// Written to complete the daemon's sentence: the notification reads
    /// "Auto-resume failed — \(reason). Claude may still be parked at the
    /// limit screen."
    static let holderTransportRefusal =
        "this session runs on the pty-holder transport, which has no key-send "
        + "path yet, so nothing was typed"
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

    public init(
        db: TBDDatabase,
        tmux: any ResumeSendingTmux,
        inspector: any PaneProcessInspecting,
        readTranscript: @escaping @Sendable (String) -> Data?,
        transcriptModifiedAt: @escaping @Sendable (String) -> Date?,
        waiter: @escaping @Sendable (Duration) async -> Void,
        actuationLog: ActuationLog
    ) {
        self.db = db
        self.tmux = tmux
        self.inspector = inspector
        self.readTranscript = readTranscript
        self.transcriptModifiedAt = transcriptModifiedAt
        self.waiter = waiter
        self.actuationLog = actuationLog
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

            do {
                try await Self.sendContinueSequence(
                    tmux: tmux, server: context.server, paneID: context.paneID, waiter: waiter)
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
        let server: String
        let paneID: String
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
    /// A transport guard runs between the terminal lookup and everything else,
    /// because every one of those steps addresses a tmux pane and a
    /// holder-backed row has none.
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
        guard ((try? await db.config.get())?.autoResumeEnabled(forLimitType: resume.limitType)) ?? false else {
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
        // guard the rail exited at step 1 with `.terminalGone` — silently
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
        // Refused rather than served, because Milestone A wires no input path
        // for the holder transport: the registry can render a session's screen
        // and report its child's last known status, but nothing writes to a
        // holder's pty. `.failed` rather than a silent cancel, because a user
        // who armed auto-resume and will not get it should be told once, not
        // left watching a limit screen behind an "auto-resume scheduled" badge
        // that quietly expired.
        guard terminal.transport != .holder else {
            logger.info("""
                actuate: terminal \(terminal.id.uuidString, privacy: .public) runs on the \
                pty-holder transport — typing nothing
                """)
            return .notEligible(.failed(Self.holderTransportRefusal))
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
            server: server, paneID: terminal.tmuxPaneID, terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            transcriptPath: terminal.transcriptPath, preSendTranscriptData: preSendTranscriptData))
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

    /// The exact production send sequence (spec §Actuation 5):
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
