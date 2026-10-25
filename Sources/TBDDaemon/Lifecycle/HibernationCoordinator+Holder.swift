import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

/// What the park's escalation ladder may do to the pid a holder row records —
/// the whole decision table, in one type, because each rung asks the same
/// question and the answers must not drift between them.
///
/// Three facts feed it: whether the row named a pid at all, whether that pid is
/// a corpse, and `ProcessIdentityCheck` — the check every other signalling site
/// in this daemon consults. The mapping is deliberately asymmetric, because the
/// two mistakes are not: a refused park is recoverable on the next sweep, and a
/// signal sent to a stranger's process is not.
///
/// - a corpse (`ps` says `Z…`) → `.gone`. Past its last instruction, and its
///   number cannot be reissued while the entry stands.
/// - `.same` → `.ours`. The one verdict that licenses a signal.
/// - `.notRunning` → `.gone`. Nothing holds the pid, so the child this park set
///   out to end is already past its last instruction. This is a *positive*
///   answer about a real pid and may therefore lead to a finalize, exactly like
///   the registry's `.exited`.
/// - `.startTimeMismatch` / `.foreignExecutable` → `.unverifiable`. The pid
///   names a stranger. In the narrow sense our child IS gone — nothing that
///   survives is ours — but "gone" here would mean finalizing a park whose
///   child this daemon never saw exit, over a row it can no longer describe. So
///   the park refuses instead, and only `.notRunning` (and the registry's own
///   `.exited`) are allowed to complete one.
/// - `.startTimeUnreadable` / `.commandUnreadable` → `.unverifiable`. The
///   kernel would not say. "Keep when uncertain" is the doctrine every
///   signalling site here follows, and an unreadable answer is uncertainty, not
///   absence.
/// - no recorded pid → `.unrecorded`. There is nothing to verify and nothing to
///   signal by number, but the holder is still reachable over its socket.
enum HolderChildDisposition: Sendable, Equatable {
    /// A live process this daemon verified as this session's own child.
    case ours
    /// The recorded pid names nothing.
    case gone
    /// The row records no usable child pid.
    case unrecorded
    /// Alive, and not provably this session's child.
    case unverifiable(ProcessIdentityVerdict)
}

extension HolderChildDisposition {
    /// The disposition of a recorded child pid, per the table on the type.
    ///
    /// A corpse is gone, and it is asked about FIRST so this agrees with
    /// `childIsGone`, which reads the same fact. It also has to come first to
    /// be right: `ps` prints a zombie's command in parentheses, which the
    /// executable check below would read as a stranger's — so a child that
    /// exited a moment after the poll gave up would be refused as a foreign
    /// process rather than recognized as the exit it is. A zombie is past its
    /// last instruction and its number cannot be reissued while the entry
    /// stands, so this is a positive answer either way.
    ///
    /// The anchor is the row's own `holderChildStartedAt`, falling back to
    /// `createdAt` for a row written before that column existed — the same
    /// pair the reaper's holder leg and the wake's adopt guard measure
    /// against, so a pid that passes here passes there.
    static func of(
        childPID: Int32, terminal: Terminal, signaller: any ProcessSignaller
    ) -> HolderChildDisposition {
        guard childPID > 1 else { return .unrecorded }
        if signaller.stat(childPID)?.hasPrefix("Z") == true { return .gone }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: HolderChildIdentity.anchor(of: terminal),
            executableIsAcceptable: AgentReaper.isHolderChildExecutable,
            signaller: signaller)
        switch verdict {
        case .same: return .ours
        case .notRunning: return .gone
        case .startTimeUnreadable, .startTimeMismatch, .commandUnreadable, .foreignExecutable:
            return .unverifiable(verdict)
        }
    }

    /// Whether a holder session has ended: its holder AND its job are both
    /// verifiably gone. **The one answer to that question**, asked by the
    /// attach path before it tells the app "ended" and by the park before it
    /// finalizes without its live rails, so a tab is never told its session
    /// ended while a park would still refuse it, or the reverse.
    ///
    /// Fail-closed on every half, because a wrong "ended" either tells somebody
    /// a running job is gone or finalizes a park over it — and a wake then
    /// starts a second agent on the same session:
    ///
    /// - **The holder** must have a recorded pid that is not a live
    ///   `TBDHolder` (`holderIsLive`, which is `HolderSpawner.isLiveHolder` in
    ///   production). No recorded pid is not evidence of anything, and a live
    ///   holder that has merely lost its reader is a session the daemon has
    ///   lost track of, not one that ended.
    /// - **The job** must have a recorded pid whose disposition is `.gone`:
    ///   nothing runs at that number, or a corpse holds it. A holder's death
    ///   does not imply its job's — a viewer holding a dup of the pty master
    ///   keeps the job from ever seeing a hangup — so a pid that is alive
    ///   under another start time or another executable is NOT taken as
    ///   gone. That is a process this daemon cannot identify, which is the
    ///   case `HolderChildDisposition` refuses for every other rung too.
    ///   Unreadable answers refuse for the same reason.
    static func sessionHasEnded(
        _ terminal: Terminal,
        holderIsLive: (Int32) -> Bool,
        signaller: any ProcessSignaller
    ) -> Bool {
        guard let holderPID = terminal.holderPID, holderPID > 1,
              !holderIsLive(holderPID) else { return false }
        guard let childPID = terminal.childPID, childPID > 1 else { return false }
        return of(childPID: childPID, terminal: terminal, signaller: signaller) == .gone
    }
}

/// Park and wake for the pty-holder transport.
///
/// Split from `HibernationCoordinator` so the diff to that file is a set of
/// branch points rather than a second mechanic interleaved with the first. The
/// two transports share every decision about WHETHER to act — the singleflight
/// claim, the refusal cascade, the transcript rail, the resume argv — and share
/// nothing about HOW: tmux parks by `respawn-window`ing a pane it owns, while a
/// holder session is parked by ending the job the holder forked and clearing
/// the pids that named it.
///
/// **The invariant the whole feature is judged on: a row never finalizes parked
/// while its child is still running.** Every failure below rolls the park
/// intent back rather than completing it, because a row that claims parked over
/// a live process is unreclaimable — nothing sweeps it, the app offers a wake
/// that would spawn a second agent onto the same session, and the process is
/// invisible to every reconciler that reads rows.
extension HibernationCoordinator {

    /// How deep a tail of a holder session's screen the park keeps as its
    /// display snapshot: the depth `terminal.output` answers by default, and
    /// about a screen's worth.
    static let holderScreenLines = 50

    /// The refusal for a holder session this daemon is not reading at all:
    /// nobody holds a reader for it, because the session was never adopted or
    /// its reader is gone. A park does not end a session this daemon has lost
    /// track of; nothing the user does to a tab changes that, so the text says
    /// what is true rather than prescribing a gesture that would not help.
    static let holderNoReaderRefusal =
        "The daemon is not reading this session's terminal, so it has not "
        + "adopted the session and will not end it to hibernate"

    /// The frame a park freezes as the parked tab's backdrop, kept as the row's
    /// `suspendedSnapshot`, or nil when there is no live screen to freeze.
    ///
    /// A display capture and nothing more: never judged. Whatever the screen
    /// says, and whether or not it can be read at all, the park goes on — an
    /// unreadable screen costs the backdrop, never the park. A screen that is
    /// not the session's live one is not shown either, because the frame it
    /// would freeze is not the one the session was showing: a viewer holds the
    /// pty and the daemon's emulator is frozen at that attach, or the emulator
    /// was built over a child that was already running and holds cells the
    /// child never wrote (`HolderScreenEvidence`).
    func holderParkSnapshot(
        terminalID: UUID, registry: HolderRegistry
    ) async -> String? {
        let screen: TerminalScreen?
        do {
            screen = try await holderScreen(terminalID: terminalID, registry: registry)
        } catch {
            logger.debug("hibernate: park of \(terminalID, privacy: .public) freezes no snapshot — its screen would not project: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let screen else {
            logger.debug("hibernate: park of \(terminalID, privacy: .public) freezes no snapshot — the daemon holds no screen for it")
            return nil
        }
        if let refusal = HolderScreenEvidence.refusal(
            forSource: screen.source, contentObserved: screen.contentObserved) {
            logger.debug("hibernate: park of \(terminalID, privacy: .public) freezes no snapshot — its screen is not the live one (\(String(describing: refusal), privacy: .public))")
            return nil
        }
        return screen.output.isEmpty ? nil : screen.output
    }

    /// Whether the daemon holds no reader for this holder session, so a park
    /// of it would refuse with `holderNoReaderRefusal`.
    ///
    /// The same question `performHolderHibernate` asks before it ends the job,
    /// lifted out so the sweep can ask it *first*. `HibernationGate` is pure —
    /// it decides from the row, the config and the clock, and has no way to
    /// see which sessions the registry adopted — so the sweep is the only
    /// place with the registry in hand.
    ///
    /// A daemon with no registry at all answers false: that is the tmux-only
    /// configuration, where a holder row is a leftover and the park's own
    /// no-registry refusal is the right place to say so once.
    func holderHasNoReader(terminalID: UUID) async -> Bool {
        guard let registry = holderRegistry else { return false }
        return await registry.reader(for: terminalID) == nil
    }

    /// The screen this daemon holds for a session, or nil when it holds none.
    ///
    /// The test seam first, so a park can be driven against each source without
    /// a real holder, a real pty and a real attach; otherwise the registry's
    /// own reader, which is the single source the design names. Both throw only
    /// what `TerminalScreen`'s construction refuses.
    ///
    /// **This reads the reader directly and must not be routed through
    /// `HolderScreenResolver`.** A screen a viewer holds is one the snapshot
    /// does not freeze either way, so a pull could not change the outcome; it
    /// would only put the pull's bound in front of every park.
    private func holderScreen(
        terminalID: UUID, registry: HolderRegistry
    ) async throws -> TerminalScreen? {
        if let holderScreenOracle {
            return try await holderScreenOracle(terminalID)
        }
        guard let reader = await registry.reader(for: terminalID) else { return nil }
        return try await reader.screen(maxLines: Self.holderScreenLines)
    }

    // MARK: - Park

    /// Park a holder-backed session: end the job its holder forked, then record
    /// the row as parked with no pids on it.
    ///
    /// Entered from `performHibernate` with `hibernatesInFlight` already
    /// claimed, and with NO tmux server lock — a holder session has no server,
    /// so there is nothing for a server lock to exclude. `hibernatesInFlight`
    /// is the whole exclusion here, and it is enough: every mutation below
    /// addresses one terminal row and one holder.
    ///
    /// The session mod's draft gate has already let the park through
    /// (`performHibernate`); nothing here reads the screen to decide anything,
    /// and nothing is written to the pty. The job is ended by signal.
    func performHolderHibernate(
        terminal: Terminal,
        worktree: LocalWorktree,
        reason: HibernateReason,
        policy: HibernateEligibilityPolicy
    ) async -> HibernateResult {
        // Re-read and re-check, in the same order and with the same refusal
        // strings the tmux path uses under its server lock. This method is
        // actor-reentrant across the polls below, so the row it decided on
        // must be the row it acts on.
        guard let currentTerminal = try? await db.terminals.get(id: terminal.id) else {
            return .notFound
        }
        guard TerminalReplacementSnapshot(terminal: terminal).matches(currentTerminal) else {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Terminal process changed before hibernation")
        }
        if case .automatic = policy,
           !TerminalHibernationSnapshot(terminal: terminal).matchesActivity(currentTerminal) {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Session activity changed before hibernation")
        }
        // Re-asked of the row read under the claim, as the tmux park does.
        guard let sessionID = currentTerminal.claudeResumeDecision.resumableSessionID else {
            return Self.parkRefusal(for: currentTerminal)
                ?? .notEligible(reason: Self.noSessionToParkReason)
        }
        if let refusal = hibernationRefusal(terminal: currentTerminal, policy: policy) {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return refusal
        }

        // Every refusal below clears `idleSince` and `pendingKillSince` like
        // every other refusal in this method. Each names a condition that will
        // still hold on the next sweep — no registry on this daemon, a session
        // this daemon never adopted — so leaving the markers armed would
        // re-fire the identical refusal every pass. Clearing them makes the
        // row start its idle clock again from the moment the condition clears.

        // No registry means no reader and no way to abandon the holder
        // afterwards. Say so by name rather than parking a row whose process
        // nothing in this daemon can end.
        guard let registry = holderRegistry else {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "this daemon has no holder registry")
        }

        // **A session whose holder and job are both verifiably gone is parked
        // without the live rails.** Every rail below asks something of a live
        // session — its reader, its transcript mid-write — and a session with
        // neither process has none of those to give: no reader exists, and
        // there is no composer left to hold unsent input. Refusing it would
        // strand the row forever, awake over nothing, with every wake,
        // hibernate and profile swap refused for a reader that can never come
        // back. Parking it is the truthful record,
        // and the invariant this feature is judged on holds trivially: the
        // child is not running. `HolderChildDisposition.sessionHasEnded` is
        // fail-closed — an unrecorded pid, a pid that is alive under an
        // identity this daemon cannot confirm, or an unreadable one is not
        // "gone" — and it is the same answer the attach path gives the app.
        let sessionEnded = HolderChildDisposition.sessionHasEnded(
            currentTerminal, holderIsLive: holderProcessIsLive, signaller: signaller)
        if sessionEnded {
            logger.info("hibernate: \(terminal.id, privacy: .public)'s holder and job are both gone — parking it without the live rails")
        }

        // The display snapshot: the last frame, frozen as the parked tab's
        // backdrop. Read once, for every policy, and judged by none — what the
        // screen shows, and whether it can be read at all, never refuses a
        // park. An ended session has no screen to freeze.
        let capturedSnapshot: String? = sessionEnded
            ? nil
            : await holderParkSnapshot(terminalID: terminal.id, registry: registry)

        // A park ends only a session this daemon has adopted, and the reader
        // is the proof of adoption: no reader means the session was never
        // adopted or its reader is gone. Nothing is written through the reader
        // — the job is ended by signal below.
        if !sessionEnded, await registry.reader(for: terminal.id) == nil {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            logger.debug("hibernate: refusing \(terminal.id, privacy: .public) — the daemon holds no reader for this session")
            return .notEligible(reason: Self.holderNoReaderRefusal)
        }

        // Rail: transcript-tail validity, identical to the tmux path — and
        // bypassed by the same policy, for the same reason: this park is a
        // user's account switch, not a background reclaim, and the tmux arm
        // has never refused one over a tail that was mid-write.
        // Not asked of an ended session: this rail exists to stop a park
        // before it ends a process mid-write, and there is no process left to
        // end. The post-exit check below still reports a cut tail.
        if !sessionEnded, let refusal = Self.transcriptTailRefusal(
            transcriptPath: currentTerminal.transcriptPath, policy: policy) {
            logger.warning("hibernate: skipping \(terminal.id, privacy: .public) — transcript tail not parseable, would be unresumable")
            return refusal
        }

        // Park INTENT, before anything touches the process. A crash between
        // here and the finalize below leaves a parked row that still names its
        // pids, which `reconcileOnStartup` un-parks on the next start after
        // proving the child is alive.
        let expectedState = TerminalHibernationSnapshot(terminal: currentTerminal)
        let inertIncarnation: TerminalSessionIncarnation
        do {
            guard let prepared = try await db.terminals.beginHibernatedShellRespawn(
                id: terminal.id,
                expectedState: expectedState,
                snapshot: capturedSnapshot,
                reason: reason,
                at: now()) else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                return .notEligible(reason: "Terminal process changed before hibernation")
            }
            inertIncarnation = prepared
        } catch {
            logger.warning("hibernate: failed to prepare parked state for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to persist hibernation")
        }

        let childPID = currentTerminal.childPID ?? 0
        // The ladder starts at SIGTERM. Nothing is typed into the pty to end
        // Claude: a typed `/exit` would land after whatever the composer holds
        // and Enter would submit it, and a daemon-sent Ctrl+C would clear a
        // draft the session mod would then record as gone. SIGTERM runs Claude
        // Code's graceful shutdown, so the mod still makes its final save in
        // `session.end`.
        //
        // An ended session skips the whole ladder: there is nothing to signal,
        // and `sessionHasEnded` has already established that the child is
        // gone.
        var gone = sessionEnded
        // Whether the holder has already been told to let go. Only the forced
        // rung does that, and only as part of killing the job; every other way
        // out of the ladder still owes the holder its `forget`.
        var abandoned = false

        if !gone {
            // Rung 1 — `SIGTERM` to the child, and to the child alone.
            //
            // The tmux park's ending is the same SIGTERM, then a forced
            // replacement. A session whose Stop hooks or MCP teardown take a
            // while gets this rung's whole poll window before anything is
            // killed, because a `SIGKILL` of its process group is where a
            // transcript gets cut mid-write. `terminateProcessOnly` is
            // deliberate — widening to the group is the forced rung's job, and
            // on a recycled pid `getpgid` resolves to a stranger's group
            // entirely.
            switch holderChildDisposition(childPID: childPID, terminal: currentTerminal) {
            case .gone:
                gone = true
            case .unverifiable(let verdict):
                return await refuseUnverifiableHolderChild(
                    currentTerminal, childPID: childPID, verdict: verdict, registry: registry)
            case .ours:
                logger.debug("hibernate: ending \(terminal.id, privacy: .public) by SIGTERM to child \(childPID, privacy: .public)")
                signaller.terminateProcessOnly(childPID)
                gone = await pollUntilChildIsGone(
                    childPID: childPID, terminalID: terminal.id, registry: registry,
                    attempts: holderTerminateAttempts)
            case .unrecorded:
                // Nothing to signal by pid, so this rung has nothing to do.
                // The forced rung still does: it reaches the holder over its
                // socket, which needs no pid at all.
                break
            }
        }

        if !gone {
            // Rung 2 — forced. `abandon` is the escalation: the holder is told
            // to let go (closing the pty master), the job is killed by process
            // group, and the holder's corpse is collected. Identity-checked
            // again rather than on the strength of the check above, because the
            // `SIGTERM` rung's own poll window sits between them and a pid
            // freed inside it is a pid the kernel may already have reissued.
            switch holderChildDisposition(childPID: childPID, terminal: currentTerminal) {
            case .gone:
                gone = true
            case .unverifiable(let verdict):
                return await refuseUnverifiableHolderChild(
                    currentTerminal, childPID: childPID, verdict: verdict, registry: registry)
            case .ours, .unrecorded:
                logger.debug("hibernate: SIGTERM did not end the job for \(terminal.id, privacy: .public) within the poll window — abandoning the holder")
                if let unfinished = await registry.abandon(
                    terminal: currentTerminal, reason: .park) {
                    logger.warning("hibernate: holder teardown for \(terminal.id, privacy: .public) was incomplete: \(unfinished, privacy: .public)")
                }
                abandoned = true
                gone = await pollUntilChildIsGone(
                    childPID: childPID, terminalID: terminal.id, registry: registry,
                    attempts: holderEscalationAttempts)
            }
        }

        if gone, !abandoned {
            // The job ended without the forced rung, so the holder was never
            // told to let go — and a holder whose child has exited winds itself
            // down, which is a race this call does not need to win.
            //
            // An ended session's holder is already dead, so its recorded pid
            // may since have been reissued — possibly to one of this daemon's
            // own children, which the holder reap's `waitpid` would collect.
            // It is told to let go with no holder pid at all.
            await letHolderGoWithoutKilling(
                currentTerminal, registry: registry, reapHolder: !sessionEnded)
        }

        guard gone else {
            // THE invariant. The row must not claim parked over a process that
            // is still running: nothing would ever reclaim it, and a wake would
            // spawn a second agent onto the same session. Roll the intent back
            // — `clearHibernated` nils both park columns and the pending
            // incarnation — and report the pid so an operator can act.
            //
            // "Left awake" is the row's state, not the session's, and the
            // difference matters to whoever reads this. Reaching here means the
            // escalation already ran: the holder was torn down and the job was
            // signalled, so what is left is a child that survived `SIGKILL` or
            // could not be confirmed gone. Leaving the row awake is the only
            // honest record of that — it names live pids, so the reconcile arm
            // and the reaper's holder leg can both judge it — but it is not a
            // claim that the session is still usable.
            do {
                try await db.terminals.clearHibernated(id: terminal.id)
            } catch {
                logger.error("hibernate: the job for \(terminal.id, privacy: .public) survived and the park intent could not be rolled back: \(error.localizedDescription, privacy: .public)")
            }
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            logger.error("hibernate: holder child \(childPID, privacy: .public) for terminal \(terminal.id, privacy: .public) survived the escalation; its holder was torn down and the row is left awake for reconciliation to judge")
            return .notEligible(
                reason: "holder child \(childPID) survived the escalation; its holder was torn "
                    + "down and this session is left awake for reconciliation to judge")
        }

        // The transcript rail, asked a second time now that the child is gone.
        //
        // The first ask was before the SIGTERM, which is the only moment it
        // can stop a park; this one cannot and must not. The process is gone, and
        // the row parked is the truthful record of that — rolling back here
        // would leave an awake row over a session that no longer exists, which
        // is a worse lie than a transcript that needs repair. So it reports and
        // continues: a tail that was parseable before the shutdown and is not
        // parseable after it means the write was cut, and the resume that finds
        // it will need to know why.
        if let transcriptPath = currentTerminal.transcriptPath,
           let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
           !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) {
            logger.warning("hibernate: the transcript for \(terminal.id, privacy: .public) is not parseable after its child exited — it may have been cut mid-write; parking anyway, because the process is gone")
        }

        do {
            guard try await db.terminals.finalizeHibernatedShellRespawn(
                id: terminal.id,
                expectedIncarnation: inertIncarnation,
                at: now()) != nil else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                return .notEligible(reason: "Terminal process changed during hibernation")
            }
        } catch {
            logger.warning("hibernate: failed to fence replaced agent for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to finalize hibernation")
        }

        // A parked holder row names no processes. Leaving the pids on it would
        // point `AgentReaper`'s holder leg and every identity check at numbers
        // the kernel has already handed to somebody else.
        do {
            try await db.terminals.setHolderProcess(
                id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
        } catch {
            logger.warning("hibernate: parked \(terminal.id, privacy: .public) but failed to clear its holder pids: \(error.localizedDescription, privacy: .public)")
        }

        guard let persisted = try? await db.terminals.get(id: terminal.id),
              persisted.isParked else {
            logger.warning("hibernate: prepared row disappeared or changed during the holder park for \(terminal.id, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to verify hibernation")
        }
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        await broadcastHibernation(
            terminal: currentTerminal, hibernated: true, keepWarm: currentTerminal.keepWarm,
            suspendedSnapshot: capturedSnapshot, hibernateReason: reason)
        logger.info("hibernated holder-backed terminal \(terminal.id, privacy: .public) in worktree \(worktree.id, privacy: .public) (session \(sessionID, privacy: .public))")
        return .ok
    }

    /// Poll `attempts` times, sleeping `exitPollInterval` on the injected clock
    /// between checks, for the holder's job to be gone.
    ///
    /// Two independent facts count as gone, because they answer from opposite
    /// ends. The process table says the pid names nothing, or names a corpse
    /// nobody has collected — a zombie is past its last instruction, and only
    /// its parent's `waitpid` is outstanding. And the holder itself may have
    /// already reported the exit, which is the one answer that survives a pid
    /// the kernel has already recycled.
    private func pollUntilChildIsGone(
        childPID: Int32, terminalID: UUID, registry: HolderRegistry, attempts: Int
    ) async -> Bool {
        for _ in 0..<max(0, attempts) {
            try? await clock.sleep(for: exitPollInterval)
            if await childIsGone(childPID: childPID, terminalID: terminalID, registry: registry) {
                return true
            }
        }
        return await childIsGone(
            childPID: childPID, terminalID: terminalID, registry: registry)
    }

    /// Whether the holder's job can be treated as gone.
    ///
    /// Two positive facts count as gone, and one silence deliberately does not.
    ///
    /// **A verdict must never rest on evidence the escalation itself erased.**
    /// `abandon(terminal:)` sets this session's remembered status back to nil,
    /// so the poll that runs *after* the escalation reads no status at all. On
    /// a row whose `child_pid` column is NULL there is then nothing else to
    /// read — the process table has no answer to give for a pid this daemon may
    /// not signal — and treating that silence as an exit is precisely how a row
    /// finalizes parked over a live child.
    ///
    /// **It answers "did our child exit", not "who holds this number now".**
    /// The second question is `holderChildDisposition`'s, and the two agree
    /// where they overlap: both read a `Z…` stat as gone, and neither lets a
    /// stranger on a recycled pid complete a park — this one because the
    /// stranger is alive, that one because it refuses to signal what it cannot
    /// identify. The full table is on `HolderChildDisposition`.
    ///
    /// So when the pid is unusable, only a POSITIVE `.exited` /
    /// `.exitedStatusUnknown` from the registry counts as gone; nil and
    /// `.alive` alike answer "not gone". The consequence is that a NULL-pid
    /// park rolls back after its escalation rather than completing, which is
    /// the safe direction: the row is left awake, where the reconcile arm and
    /// the reaper's holder leg can judge it. Every path that recorded a real
    /// child pid is unchanged, because the process table answers there.
    private func childIsGone(
        childPID: Int32, terminalID: UUID, registry: HolderRegistry
    ) async -> Bool {
        switch await registry.lastKnownStatus(for: terminalID) {
        case .exited, .exitedStatusUnknown: return true
        case .alive, nil: break
        }
        // Reaching here means the registry reported the job alive, or has
        // nothing to report because the escalation cleared what it knew.
        // Neither is evidence of an exit, and with no pid to check there is no
        // second source to ask.
        guard childPID > 1 else { return false }
        guard signaller.isAlive(childPID) else { return true }
        // `ps -o stat=` reports a corpse as `Z...`. It answers `kill(pid, 0)`,
        // so liveness alone cannot tell it from a running process — and the
        // distinction matters here: the job has finished, and the `waitpid`
        // still owed to it belongs to the holder, not to this park.
        return signaller.stat(childPID)?.hasPrefix("Z") ?? false
    }

    /// What the escalation ladder may do to this row's recorded child pid.
    ///
    /// Asked before every signal, and asked again between rungs, because the
    /// poll window between them is exactly long enough for a pid to be freed
    /// and reissued. The verdict-to-disposition mapping and the reasoning for
    /// each arm live on `HolderChildDisposition`.
    ///
    /// The anchor is the row's own `holderChildStartedAt`, falling back to
    /// `createdAt` for a row written before that column existed — the same pair
    /// the reaper's holder leg and the wake's adopt guard measure against, so a
    /// pid that passes here passes there.
    func holderChildDisposition(
        childPID: Int32, terminal: Terminal
    ) -> HolderChildDisposition {
        HolderChildDisposition.of(childPID: childPID, terminal: terminal, signaller: signaller)
    }

    /// Abandon a park whose child pid this daemon cannot prove is its own.
    ///
    /// "Keep when uncertain", spelled out on the park path: nothing is
    /// signalled — not the pid, not its group — because the process at that
    /// number may be a stranger's work on a machine running dozens of agent
    /// sessions, and a wrong kill there is unrecoverable while a refused park
    /// is not.
    ///
    /// The holder is still told to let go, without a kill. That is not a
    /// contradiction: the `forget` addresses the holder over its own socket and
    /// signals nothing, and leaving the daemon reading a pty whose job it can
    /// no longer identify would keep a reader alive over a session nobody can
    /// describe. What is left behind is a row that is awake and still names its
    /// pids — the state the reconcile arm and the reaper's holder leg are built
    /// to judge, both of which apply the same identity check and will keep for
    /// the same reason.
    private func refuseUnverifiableHolderChild(
        _ terminal: Terminal,
        childPID: Int32,
        verdict: ProcessIdentityVerdict,
        registry: HolderRegistry
    ) async -> HibernateResult {
        await letHolderGoWithoutKilling(terminal, registry: registry)
        do {
            try await db.terminals.clearHibernated(id: terminal.id)
        } catch {
            logger.error("hibernate: could not verify the child of \(terminal.id, privacy: .public) and could not roll the park intent back either: \(error.localizedDescription, privacy: .public)")
        }
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        logger.warning("hibernate: refusing to signal child \(childPID, privacy: .public) for terminal \(terminal.id, privacy: .public) — its identity is \(String(describing: verdict), privacy: .public); the row is left awake with its pids intact")
        return .notEligible(
            reason: "the process holding child pid \(childPID) could not be verified as this "
                + "session's own (\(verdict)), so nothing was signalled and this session is "
                + "left awake")
    }

    /// Tell the holder to let go of the pty without killing anything.
    ///
    /// `childPID: 0` is the sentinel `dispose` refuses to signal, and that is
    /// the point on both paths that reach here: after a confirmed exit the
    /// recorded pid is free and the next process to take that number is
    /// somebody else's, and after an unverifiable identity the number was never
    /// ours to signal in the first place.
    ///
    /// `reapHolder: false` hands `abandon` no holder pid, so its reap step
    /// (`waitpid` on that pid) is skipped — for a holder already known dead,
    /// whose recorded number the kernel is free to have reissued.
    private func letHolderGoWithoutKilling(
        _ terminal: Terminal, registry: HolderRegistry, reapHolder: Bool = true
    ) async {
        do {
            let socketPath = try HolderRendezvous.socketPath(
                sessionID: terminal.id, environment: registry.environment)
            // A park's let-go: the one a later wake of this row may undo.
            await registry.abandon(
                terminalID: terminal.id,
                handle: HolderHandle(
                    holderPID: reapHolder ? (terminal.holderPID ?? 0) : 0,
                    childPID: 0,
                    socketPath: socketPath),
                reason: .park)
        } catch {
            // The processes are not the concern: nothing here was going to be
            // signalled anyway. What does outlive this call is bookkeeping
            // `abandon` would have cleared — this session's registry slot and
            // its remembered status — and the collector for that is
            // `reclaimIfSessionEnded`, which the reader's end-of-output
            // notifier fires once the drain runs dry.
            //
            // Worth naming rather than glossing: that reclaimer derives the
            // SAME rendezvous path, and the only thing that makes this throw is
            // a path over `sun_path` — a persistent fact about this install's
            // `TBD_HOME` and this session's id, not a transient. So the pairing
            // is real but not a guarantee here; it is also the reason this
            // branch is close to unreachable, since a session whose path cannot
            // be represented could neither have been spawned nor adopted by
            // this daemon.
            logger.warning("hibernate: could not derive the rendezvous path for \(terminal.id, privacy: .public), so its holder was not told to let go: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Startup reconciliation

    /// Reconcile one PARKED holder row against the process table.
    ///
    /// **It must not consult the registry, and that is a startup-ordering
    /// fact rather than a preference**: `reconcileOnStartup` runs before
    /// `HolderRegistry.adoptAll`, so at this moment the registry holds no
    /// readers and knows no statuses — asking it would answer "gone" for every
    /// session on the machine and un-park nothing while looking authoritative.
    /// The recorded child pid is the only ground truth available this early,
    /// read through the same `ProcessIdentityCheck` the reaper's holder leg
    /// consults.
    ///
    /// Two verdicts move the row and every other one leaves it alone:
    ///
    /// - `.same` — the daemon died mid-park, after the intent was written and
    ///   before the child was confirmed gone. The child is alive and is this
    ///   row's; un-park it, and adoption will pick the session up moments later.
    ///   The tmux recovery in the same method has exactly this shape.
    /// - `.notRunning` — the child is gone but the row still names it. Clear the
    ///   pids so nothing later signals a number the kernel has recycled.
    ///
    /// Everything else — an unreadable start time, a mismatch, a foreign
    /// executable — is an uncertain identity, and an uncertain identity is not
    /// evidence in either direction.
    ///
    /// **It runs on every pass, and that is not an oversight.** This arm judges
    /// rows that are already parked, including ones parked by a build or a
    /// configuration that no longer holds. Both of its mutations are
    /// safety-only: one un-parks a row over a child that is verifiably alive,
    /// the other clears pids that verifiably name nothing. Neither ends a
    /// process, neither parks anything, and neither can be undone into a worse
    /// state than the row was already in.
    func reconcileParkedHolderRow(_ terminal: Terminal) async {
        guard let childPID = terminal.childPID, childPID > 1 else { return }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: HolderChildIdentity.anchor(of: terminal),
            executableIsAcceptable: AgentReaper.isHolderChildExecutable,
            signaller: signaller)
        switch verdict {
        case .same:
            do {
                try await db.terminals.clearHibernated(id: terminal.id)
                logger.info("startup: holder-backed terminal \(terminal.id, privacy: .public) was parked while its child \(childPID, privacy: .public) was still running — un-parking; adoption will pick it up")
            } catch {
                logger.warning("startup: failed to un-park holder-backed terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case .notRunning:
            do {
                try await db.terminals.setHolderProcess(
                    id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
                logger.info("startup: cleared the stale holder pids on parked terminal \(terminal.id, privacy: .public) — its recorded child \(childPID, privacy: .public) is gone")
            } catch {
                logger.warning("startup: failed to clear the stale holder pids on \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case .startTimeUnreadable, .startTimeMismatch, .commandUnreadable, .foreignExecutable:
            logger.debug("startup: leaving parked holder-backed terminal \(terminal.id, privacy: .public) alone — child identity is uncertain (\(String(describing: verdict), privacy: .public))")
        }
    }

    // MARK: - Wake

    /// What a wake aimed at an UNPARKED holder row should answer.
    ///
    /// The tmux answer to this question probes a pane; a holder row has none.
    /// The equivalent evidence is the recorded child pid, read through the same
    /// `ProcessIdentityCheck` the reaper's holder leg consults before it
    /// signals anything — so a pid the kernel has recycled is recognized here
    /// the same way it is there.
    ///
    /// Only `.notRunning` downgrades the answer. Every other verdict is an
    /// uncertain identity, and an uncertain identity is not evidence that a
    /// session died — the same asymmetry the tmux classification applies to a
    /// probe that merely threw. Like it, this reports and does not repair.
    func classifyUnparkedHolderWake(_ terminal: Terminal) async -> WakeResult {
        guard let childPID = terminal.childPID, childPID > 1 else { return .notHibernated }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: HolderChildIdentity.anchor(of: terminal),
            executableIsAcceptable: AgentReaper.isHolderChildExecutable,
            signaller: signaller)
        guard verdict == .notRunning else { return .notHibernated }
        logger.warning("""
            wake: terminal \(terminal.id, privacy: .public) is unparked but the job its \
            holder forked (pid \(childPID, privacy: .public)) is gone — reporting sessionGone \
            instead of "already awake"
            """)
        // No pane id to name, and the empty string is what the row carries.
        // `RPCRouter.unparkedWakeMessage` phrases an empty one as "its
        // holder-backed session" rather than as a pane that does not exist.
        return .sessionGone(paneID: "", detail: .processExited)
    }

    /// Wake a parked holder row onto a spawn command the CALLER composed — the
    /// wake half of an action that rewrote the row in place while it was
    /// parked. The in-place profile swap is the one such action today.
    ///
    /// A caller that needs no command of its own takes the public `wake`
    /// instead: everything above its single transport branch is already
    /// transport-independent, so an in-place change that only rewrote a column
    /// resumes through the code every other wake uses. This entry point exists
    /// for the caller that composes its own command.
    ///
    /// `wakeHolderSection` is the mutate half and claims nothing, while the
    /// public `wake` claims the in-flight sets and then composes its own
    /// resume. The swap needs the first without the second: its plan may say
    /// fresh (a blank session swapped on tmux spawns fresh rather than showing
    /// "no conversation found", and this arm matches it).
    ///
    /// A refused claim releases `spawnTitle` here rather than in the section,
    /// because the section is never entered.
    func wakeHolderAfterInPlaceChange(
        terminal: Terminal,
        worktree: LocalWorktree,
        sessionID: String,
        expectedReplacementState: TerminalReplacementSnapshot,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        cols: Int?,
        rows: Int?,
        spawnTitle: ClaudeSpawnTitle? = nil,
        overlay: ReplacementSpawnOverlay
    ) async -> WakeResult {
        guard !hibernatesInFlight.contains(terminal.id),
              !wakesInFlight.contains(terminal.id) else {
            await sessionTitles.release(spawnTitle)
            return .inFlight
        }
        // The public `wake` asks this before its transport branch; this entry
        // skips that branch, so it asks for itself. The caller composed the
        // command — possibly a fresh session rather than a resume — but only a
        // row a wake may resume may have its process replaced by one.
        let refusal: WakeResult?
        switch terminal.claudeResumeDecision {
        case .resume: refusal = nil
        case .noSession: refusal = .noSessionID
        case .notAClaudeTab(let kind): refusal = .notAClaudeTab(kind: kind)
        }
        if let refusal {
            await sessionTitles.release(spawnTitle)
            return refusal
        }
        wakesInFlight.insert(terminal.id)
        defer { wakesInFlight.remove(terminal.id) }

        return await wakeHolderSection(
            terminal: terminal,
            worktree: worktree,
            sessionID: sessionID,
            expectedReplacementState: expectedReplacementState,
            spawnCommand: spawnCommand,
            env: env,
            sensitiveEnv: sensitiveEnv,
            cols: cols,
            rows: rows,
            spawnTitle: spawnTitle,
            overlay: overlay)
    }

    /// The mutate half of a holder wake: spawn a fresh holder running the
    /// resume command, record what it started, then un-park the row.
    ///
    /// The ordering is the same one `WorktreeLifecycle+Create` uses and for the
    /// same reason: the pids are persisted BEFORE the row stops being parked,
    /// so a failure in between leaves a parked row that names live processes —
    /// which `reconcileOnStartup` un-parks — rather than an awake row that
    /// names nothing, which nothing would ever reconcile. Both orders can fail
    /// in the middle; only this one fails into a state something owns.
    ///
    /// **What makes that order converge rather than compound is the adopt
    /// guard below.** Without it, the window between the pid write and the
    /// cleared park marker is not merely untidy, it multiplies: the row still
    /// reads parked, so the app's next focus-wake re-enters this method,
    /// `registry.spawn` runs unconditionally, `setHolderProcess` overwrites the
    /// pids with a third generation, and the second generation — live, and no
    /// longer named by any row — is beyond every reconciler, because the
    /// reaper's holder leg sweeps by the pids a row carries. Healing the row
    /// instead means the retry that used to widen the damage is now what
    /// repairs it, and `reconcileOnStartup` stops being the only cure.
    ///
    /// `spawnTitle`, the session title reserved for `spawnCommand`'s
    /// `--name`, is settled here because only this method knows whether a
    /// session launched under it: confirmed once the replacement is running
    /// and recorded — even if un-parking the row then fails, since the
    /// session carries the name — and released on every refusal and on an
    /// adopting wake, which starts nothing.
    func wakeHolderSection(
        terminal: Terminal,
        worktree: LocalWorktree,
        sessionID: String,
        expectedReplacementState: TerminalReplacementSnapshot,
        spawnCommand: String,
        env: [String: String],
        // The job's process environment: the free-form overrides with the
        // spawn builder's auth and routing env layered on top.
        sensitiveEnv: [String: String],
        cols: Int?,
        rows: Int?,
        spawnTitle: ClaudeSpawnTitle? = nil,
        // The overlay `spawnCommand` was composed with, planned before this
        // spawn's session-mod features were known: written from the context
        // `SessionModSpawn.prepare` returns, just before the launch, and never
        // by a wake that adopts a live holder instead. Required, as
        // `wakeTmux`'s is: the command already names a per-session file that
        // only `settle` writes, so a caller must not be able to launch it
        // without settling.
        overlay: ReplacementSpawnOverlay
    ) async -> WakeResult {
        // Every refusal below goes through this rather than returning
        // `.respawnFailed` directly, because each one is a spawn that did not
        // happen, and the title reserved for it must be released.
        func refuse(_ reason: String) async -> WakeResult {
            await sessionTitles.release(spawnTitle)
            return .respawnFailed(reason: reason)
        }

        guard let registry = holderRegistry else {
            return await refuse(
                "this daemon has no holder registry, so the session cannot be resumed on the pty-holder transport")
        }

        guard let currentTerminal = try? await db.terminals.get(id: terminal.id),
              expectedReplacementState.matches(currentTerminal) else {
            return await refuse("terminal changed while wake was preparing; retry")
        }

        // The row said parked, but its holder may already be running — an
        // earlier wake of this same row that got as far as the pids. Heal it
        // rather than starting a second one.
        if let adopted = await adoptLiveHolderInsteadOfRespawning(
            currentTerminal, registry: registry) {
            // No session launched under this wake's `--name`: the healed one
            // keeps whatever name it had, and the store the entry it had.
            await sessionTitles.release(spawnTitle)
            return adopted
        }

        // "Registry present" is not "can spawn": a daemon whose `TBDHolder`
        // binary has moved still builds a registry, because adoption of a
        // running holder needs no executable. Only this fact may gate a spawn.
        //
        // Asked here rather than at the top of the method because it gates a
        // SPAWN, and the branch above does not spawn: a daemon whose helper has
        // moved can still un-park a row over the holder it already adopted, and
        // refusing that would strand exactly the row this method just proved is
        // healthy. Everything between here and the guard is read-only, so
        // moving the question down costs the refusal nothing.
        guard registry.canSpawn else {
            return await refuse(
                "the TBDHolder helper is missing beside the daemon, so no holder can be started for this session; the row stays parked")
        }

        let incarnationID: UUID
        do {
            guard let prepared = try await db.terminals.prepareHibernatedAgentRespawn(
                id: terminal.id,
                expectedState: expectedReplacementState,
                at: now()) else {
                return await refuse("terminal changed before wake could launch; retry")
            }
            incarnationID = prepared
        } catch {
            logger.warning("wake: failed to prepare the replacement agent for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return await refuse(
                "preparing the replacement agent failed: \(error.localizedDescription)")
        }
        let replacementEnv = AgentProcessEnvironment.replacement(
            base: env, incarnationID: incarnationID)
        // `sessionID` is the session `spawnCommand` runs — the resume, or the
        // fresh session an in-place swap planned — so it names the directory
        // the replacement's mod writes under.
        let sessionMod = SessionModSpawn.prepare(
            config: try? await db.config.get(),
            claudeSessionID: sessionID, incarnationID: incarnationID,
            sessionsDir: sessionsDir, now: now())
        // Written here and not when the overlay was planned: the adopting
        // branch above launches nothing, and must leave the running process's
        // overlay as it is.
        let launchCommand = overlay.settle(command: spawnCommand)

        let handle: HolderHandle
        do {
            handle = try await registry.spawn(
                terminalID: terminal.id,
                launch: WorktreeLifecycle.holderLaunch(
                    shellCommand: launchCommand,
                    env: replacementEnv,
                    // `sensitiveEnv` is the job's process environment:
                    // `holderLaunch` inlines `env` as `export K='v';` in front
                    // of the command and never this dictionary. The session
                    // mod's variables ride here too, empty when every feature
                    // is off.
                    sensitiveEnv: sensitiveEnv.addingSessionMod(sessionMod),
                    workingDirectory: worktree.path,
                    cols: cols ?? TmuxManager.defaultCols,
                    rows: rows ?? TmuxManager.defaultRows,
                    environment: registry.environment))
        } catch {
            // The row stays parked, so the next focus or menu retry can wake it.
            logger.warning("wake: could not start a holder for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return await refuse(
                "starting a holder for this session failed: \(error.localizedDescription)")
        }

        do {
            try await db.terminals.setHolderProcess(
                id: terminal.id,
                holderPID: handle.holderPID,
                childPID: handle.childPID,
                startedAt: now())
        } catch {
            // A holder and a job no row names would be reclaimable by nothing,
            // so undo the spawn from the failing call itself. A park's let-go,
            // not a teardown's: the row stays parked, and a later wake may
            // bring the session back.
            await registry.abandon(terminalID: terminal.id, handle: handle, reason: .park)
            logger.warning("wake: started a holder for \(terminal.id, privacy: .public) but could not record its pids, so it was abandoned: \(error.localizedDescription, privacy: .public)")
            return await refuse(
                "the replacement agent started, but recording its process ids failed: \(error.localizedDescription)")
        }
        // The replacement is running and recorded under the reserved name.
        await sessionTitles.confirm(spawnTitle)

        do {
            try await db.terminals.clearHibernated(id: terminal.id)
        } catch {
            // Keep the live replacement parked. The row names live pids, and
            // startup reconciliation clears the marker off a parked row whose
            // child is identity-verified alive.
            logger.error("wake: launched the replacement agent for \(terminal.id, privacy: .public), but failed to clear its parked marker: \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "replacement agent launched, but clearing the parked marker failed: \(error.localizedDescription)")
        }

        idleSince[terminal.id] = nil
        // Empty tmux coordinates, because that is what a holder row carries and
        // what the app's cached row must keep: a non-empty pair here would send
        // the terminal view looking for a window that does not exist.
        await broadcastHibernation(
            terminal: currentTerminal, hibernated: false, keepWarm: currentTerminal.keepWarm,
            tmuxWindowID: "", tmuxPaneID: "")
        // No `SessionRecaptureScheduler`: a holder wake knows the id it resumed
        // and hooks report the id the agent settles on, so there is nothing for
        // a recapture to discover. Should that change, `SessionRecaptureTarget`
        // has a `.holderChild(pid:)` case that addresses this row's job
        // directly — the absence here is a decision about what is worth
        // reading, not a coordinate the scheduler lacks.
        logger.info("woke holder-backed terminal \(terminal.id, privacy: .public) (resume \(sessionID, privacy: .public), holder \(handle.holderPID, privacy: .public), child \(handle.childPID, privacy: .public))")
        // The incarnation this wake minted for the replacement agent, the same
        // fact the tmux arm reports: it is what scopes a caller's wait to the
        // session THIS call started rather than to whatever starts next.
        return .ok(sessionIncarnationID: incarnationID)
    }

    /// Un-park a parked row whose holder is already running, or answer nil so
    /// the wake spawns as usual.
    ///
    /// The state this recognizes is a wake that half-finished: `setHolderProcess`
    /// landed and `clearHibernated` did not, so the row names a live holder and
    /// a live child while still claiming parked. `reconcileOnStartup` heals it,
    /// but only at the next daemon start, and the periodic reconcile sweep skips
    /// parked rows by design — so between those two events every retry used to
    /// spawn again and abandon the generation before it.
    ///
    /// Two independent facts count as "already running", because they answer
    /// from opposite ends and either one alone is enough:
    ///
    /// - **The registry still holds a reader for the session.** That means this
    ///   daemon is draining that session's pty right now — whichever daemon
    ///   started the holder, since `adoptAll` adopts rows this one never
    ///   spawned — which is first-hand evidence that the holder is alive rather
    ///   than an inference about a number. A re-adopted row may carry no pids
    ///   at all, so this leg restores them from what the registry itself
    ///   observed before the park marker is cleared; that is what
    ///   `restoreHolderPIDsFromRegistry` is doing here. It is also what makes
    ///   this a guard rather than a nicety: `HolderRegistry.spawn` refuses a
    ///   session that already occupies a slot (`sessionAlreadyRegistered`), so
    ///   without the guard the retry's spawn throws and the row stays parked
    ///   forever — the guard is what turns that throw into a heal.
    /// - **The recorded child pid is identity-verified alive**, through the same
    ///   `ProcessIdentityCheck` the reaper's holder leg consults before it
    ///   signals anything: alive, started within
    ///   `AgentReaper.defaultHolderIdentityWindow` of the row's recorded child
    ///   start, and running an executable a holder's job could be. A pid the
    ///   kernel has recycled fails it exactly as it fails there.
    ///
    /// **What the second leg is actually for**, since the obvious answer is
    /// wrong: it is not "a daemon restart, where no reader exists". `adoptAll`
    /// filters on transport alone and adopts parked rows too, so after a
    /// restart such a session normally *does* get a reader and the first leg
    /// fires. The second leg is what is left when adoption itself failed — a
    /// holder that would not answer the hand-over — and the recorded pid is
    /// nonetheless certain. When identity is uncertain as well, this returns
    /// nil, the wake proceeds to `registry.spawn`, and the holder's creation
    /// lock refuses a second holder for a session that already has one: the row
    /// then stays parked until that holder dies. Fail-safe, in that no second
    /// agent is ever started, but the outcome is a session stuck parked, and it
    /// is named here rather than left to be rediscovered.
    ///
    /// Every other verdict — `.notRunning`, an unreadable start time or command
    /// line, a mismatch, a foreign executable — returns nil and lets the spawn
    /// proceed. That is the safe direction on this side: an uncertain identity
    /// must not silently un-park a row over a session nobody is running, and a
    /// spawn that turns out to be unnecessary is refused by the registry rather
    /// than duplicated.
    ///
    /// **The second leg adopts the holder before it un-parks the row.** The
    /// startup adoption that failed is the one nothing would repeat, and an
    /// awake row with no reader is a session nobody drains — whose job cannot
    /// finish exiting — that no park can end, and that only an attach would
    /// adopt. So the wake takes the hand-over itself, and the row comes back
    /// awake with a reader on it and its pids checked against what the holder
    /// reported. The wait is bounded as an attach's is
    /// (`HolderRegistry.adoptWithinAttachBudget`), and a hand-over still
    /// running at the limit finishes on its own. If the hand-over fails, or is
    /// still running, the row is un-parked regardless: a row parked over a
    /// live child is the state this transport treats as worst, while an awake
    /// row names live pids every reconciler can judge, and the next attach
    /// adopts on demand (`HolderRegistry.adoptForAttach`). The wake clears the
    /// park's let-go mark it found on those paths, because that attach refuses
    /// a session this registry told to let go and the wake has just revived
    /// it. A teardown's let-go is never the wake's to undo: found before the
    /// adoption, the wake does not reach for the holder at all. After the
    /// adoption, whatever it came to, `refusalToUnpark` keeps the row parked —
    /// releasing any reader the wake published — for a daemon that is shutting
    /// down, a teardown that let the session go meanwhile, or a session
    /// released or let go anew while the wake waited.
    private func adoptLiveHolderInsteadOfRespawning(
        _ terminal: Terminal, registry: HolderRegistry
    ) async -> WakeResult? {
        let evidence: String
        if await registry.reader(for: terminal.id) != nil {
            evidence = "this daemon is still reading its holder"
            // Before the row stops being parked, and this is the ordering that
            // matters: a row un-parked without pids on it is invisible to every
            // reclaimer this transport has, all of which sweep by the numbers a
            // row carries.
            await restoreHolderPIDsFromRegistry(terminal, registry: registry)
        } else if let childPID = terminal.childPID, childPID > 1,
                  ProcessIdentityCheck.verify(
                    pid: childPID,
                    startedWithin: AgentReaper.defaultHolderIdentityWindow,
                    of: HolderChildIdentity.anchor(of: terminal),
                    executableIsAcceptable: AgentReaper.isHolderChildExecutable,
                    signaller: signaller) == .same {
            // Adopted before the row stops being parked, for the reason the
            // header gives: un-parked without a reader, nothing drains it.
            // Bounded like an attach's adoption, because this wake holds its
            // claim and its caller's RPC for as long as it waits. The let-go
            // is read before the wait. A teardown's let-go — a delete, an
            // archive — means the session is going away and the wake does not
            // reach for its holder at all; a park's is the one this wake
            // exists to undo, and its mark tells it apart from any newer
            // let-go that lands while the wake is adopting.
            let foundLetGo = await registry.letGo(for: terminal.id)
            if foundLetGo?.reason == .teardown {
                return keepParkedOverATeardown(terminal)
            }
            let adoption = await registry.adoptWithinAttachBudget(terminal: terminal)
            if let leftParked = await refusalToUnpark(
                terminal, adoption: adoption, foundLetGo: foundLetGo, registry: registry) {
                return leftParked
            }
            if case .success(_)? = adoption {
                evidence = "its recorded child \(childPID) is identity-verified alive, and its "
                    + "holder is now adopted"
                await restoreHolderPIDsFromRegistry(terminal, registry: registry)
            } else {
                if case .failure(let error)? = adoption {
                    evidence = "its recorded child \(childPID) is identity-verified alive, though "
                        + "its holder could not be adopted, so the next attach will adopt it"
                    logger.warning("wake: \(terminal.id, privacy: .public) is parked over a live holder that would not hand its pty over; un-parking it without a reader: \(error.localizedDescription, privacy: .public)")
                } else {
                    evidence = "its recorded child \(childPID) is identity-verified alive, and its "
                        + "holder's adoption is still running"
                    logger.notice("wake: the adoption of \(terminal.id, privacy: .public)'s live holder outlasted its budget; un-parking the row while the adoption finishes on its own")
                }
                // The wake revives this session on purpose, and it leaves the
                // adoption to the next attach — which refuses a session this
                // registry told to let go, as a park that reached `abandon`
                // did. Only the park's mark the wake found is cleared; a newer
                // let-go, or any teardown, has already kept the row parked.
                await registry.clearLetGo(
                    terminalID: terminal.id, ifUnchangedSince: foundLetGo?.mark)
            }
        } else {
            return nil
        }

        do {
            try await db.terminals.clearHibernated(id: terminal.id)
        } catch {
            // Nothing was spawned and nothing is abandoned: the row is still
            // parked over its own live holder and still names its pids. If
            // this wake adopted the holder, the reader stays — it is draining
            // a live session — and the next retry takes the first leg;
            // otherwise the next retry or the next daemon start reaches this
            // same branch again.
            logger.error("wake: \(terminal.id, privacy: .public) is parked over a holder that is already running, but the parked marker could not be cleared: \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "this session's holder is already running, but clearing its parked "
                    + "marker failed: \(error.localizedDescription)")
        }

        idleSince[terminal.id] = nil
        // The same empty tmux coordinates the spawn path broadcasts, for the
        // same reason: a holder row carries none, and a non-empty pair would
        // send the terminal view looking for a window that does not exist.
        await broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: terminal.keepWarm,
            tmuxWindowID: "", tmuxPaneID: "")
        logger.info("wake: adopted the holder already running for \(terminal.id, privacy: .public) instead of spawning a second one — \(evidence, privacy: .public); the row was parked over it")
        // No incarnation: adopting a holder that was already running spawns
        // nothing, so there is no new session for a caller's wait to scope to.
        return .ok(sessionIncarnationID: nil)
    }

    /// Why a wake that reached for a parked row's live holder must leave the
    /// row parked after all, or nil when it may un-park it. Asked after the
    /// adoption, whatever it came to, and before the row stops being parked.
    ///
    /// Three answers keep it parked, and none can be read off the adoption's
    /// result alone:
    ///
    /// - **The daemon is shutting down** (when nothing was adopted). Asked of
    ///   the registry, because a shutdown that began while the adoption was
    ///   in flight reaches it as a supersession, a budget timeout or the
    ///   hand-over's own failure — never as `daemonShuttingDown`. The row
    ///   stays parked for the next daemon's startup adoption, which adopts
    ///   parked rows too.
    /// - **A teardown let the session go** while the wake waited — a delete or
    ///   an archive reaches `abandon` with no hibernation claim, so it can
    ///   overlap a wake. Nothing may revive that session.
    /// - **The session was released, or let go anew, while the wake waited**:
    ///   the adoption was superseded, a let-go newer than the one the wake
    ///   found stands, or — after an adoption that published — the reader is
    ///   already gone again.
    ///
    /// When the wake did adopt, a keep-parked answer also releases that
    /// reader, so nothing reads a session the row will not show as awake;
    /// the teardown that caused it would release it too, and a second release
    /// is a no-op.
    private func refusalToUnpark(
        _ terminal: Terminal,
        adoption: Result<HolderReader, Swift.Error>?,
        foundLetGo: HolderRegistry.LetGo?,
        registry: HolderRegistry
    ) async -> WakeResult? {
        var adopted = false
        var superseded = false
        switch adoption {
        case .success(_)?:
            adopted = true
        case .failure(let error)?:
            if let refusal = error as? HolderRegistry.Error, case .superseded = refusal {
                superseded = true
            }
        case nil:
            break
        }
        if !adopted, await registry.isShuttingDown {
            logger.notice("wake: \(terminal.id, privacy: .public) is parked over a live holder, but the daemon is shutting down and adopts nothing; leaving the row parked for the next daemon to adopt")
            return .respawnFailed(
                reason: "the daemon is shutting down, so this session stays parked; its holder is "
                    + "still running and the next daemon will adopt it")
        }
        let current = await registry.letGo(for: terminal.id)
        let tornDown = current?.reason == .teardown
        let letGoAnew = current != nil && current?.mark != foundLetGo?.mark
        var readerGone = false
        if adopted {
            readerGone = await registry.reader(for: terminal.id) == nil
        }
        guard tornDown || superseded || letGoAnew || readerGone else { return nil }
        if adopted {
            await registry.release(terminalID: terminal.id)
        }
        if tornDown {
            return keepParkedOverATeardown(terminal)
        }
        logger.notice("wake: \(terminal.id, privacy: .public) was released or let go while this wake was adopting its holder, so the row stays parked")
        return .respawnFailed(
            reason: "this session was released while the wake was adopting its holder, so it "
                + "stays parked")
    }

    /// The answer for a wake that finds the session let go by a teardown: the
    /// row stays parked, and nothing is adopted or kept.
    private func keepParkedOverATeardown(_ terminal: Terminal) -> WakeResult {
        logger.notice("wake: \(terminal.id, privacy: .public) is being torn down — its holder was let go by a delete, an archive or another teardown — so the wake leaves the row parked")
        return .respawnFailed(
            reason: "this session was released while the wake was adopting its holder, so it "
                + "stays parked")
    }

    /// Put the registry's own view of a session's processes back onto its row.
    ///
    /// The state this repairs is narrow and real: `HolderRegistry.spawn`
    /// publishes its reader before `wakeHolderSection` persists the pids, and a
    /// daemon that dies in that window — SIGKILL, OOM, a panic; not a thrown
    /// error, which the spawn path already undoes itself — leaves a parked row
    /// naming no processes behind a holder that is alive. `reconcileParkedHolderRow`
    /// cannot repair it, because it has no pid to verify. `adoptAll` re-adopts
    /// the holder regardless, so the next wake reaches the reader leg above and
    /// would un-park the row with no pid on it — and from then on the reaper's
    /// holder leg, the startup arm, and any later park's own escalation are all
    /// blind to that session, permanently.
    ///
    /// The registry is the right source precisely because it is first-hand: the
    /// child pid comes from the hand-over that produced the live reader, and
    /// the holder pid from the socket that carried it. A registry that answers
    /// nothing is logged and left alone rather than guessed at — this runs
    /// under a live reader, so it should always answer, and inventing a pid
    /// would be worse than recording none.
    ///
    /// The start time is the identity anchor every reclaimer measures that pid
    /// against, so it is taken from the most trustworthy source available and
    /// the log says which one: the row's own value when it still describes this
    /// child, else the kernel's start time for the pid, else the current time —
    /// which is a fallback rather than a fact, and is honest in the direction
    /// that matters, since a wrong anchor makes the identity check refuse to
    /// signal rather than signal wrongly.
    private func restoreHolderPIDsFromRegistry(
        _ terminal: Terminal, registry: HolderRegistry
    ) async {
        guard let observed = await registry.adoptedProcess(for: terminal.id) else {
            logger.warning("wake: \(terminal.id, privacy: .public) is parked over a holder this daemon is reading, but the registry names no processes for it, so the row's pids cannot be repaired")
            return
        }
        // A holder pid the kernel would not name is recorded as nil rather than
        // faked. Nothing needs it: the child pid is the anchor every reclaimer
        // sweeps by, `HolderRegistry.abandon(terminal:)` reaches the holder over
        // its socket, and `AgentReaper.decideHolderChild` keeps — never kills —
        // when the holder pid is missing.
        let holderPID = observed.holderPID ?? terminal.holderPID
        let startedAt: Date
        let anchorSource: String
        if let recorded = terminal.holderChildStartedAt, terminal.childPID == observed.childPID {
            startedAt = recorded
            anchorSource = "the row's own recorded start"
        } else if let measured = signaller.startTime(observed.childPID) {
            startedAt = measured
            anchorSource = "the kernel's start time for the child"
        } else {
            startedAt = now()
            anchorSource = "this moment, because the kernel would not say when the child started"
        }
        guard terminal.childPID != observed.childPID
                || terminal.holderPID != holderPID
                || terminal.holderChildStartedAt != startedAt else { return }
        do {
            try await db.terminals.setHolderProcess(
                id: terminal.id, holderPID: holderPID, childPID: observed.childPID,
                startedAt: startedAt)
            // Hoisted rather than folded into the interpolation: `0` here is
            // "the kernel would not name the holder", not a pid.
            let loggedHolderPID = holderPID ?? 0
            logger.info("wake: restored the holder pids on \(terminal.id, privacy: .public) from the registry — holder \(loggedHolderPID, privacy: .public), child \(observed.childPID, privacy: .public), anchored on \(anchorSource, privacy: .public)")
        } catch {
            // The un-park below still proceeds. A row that is awake and pid-less
            // is the state this method exists to prevent, but refusing the wake
            // over it would leave the session parked over a holder that is
            // already running — which nothing else repairs either, and which the
            // user cannot get out of.
            logger.error("wake: could not restore the holder pids on \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
