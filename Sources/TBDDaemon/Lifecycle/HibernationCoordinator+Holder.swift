import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

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

    /// The refusal for a holder session the daemon cannot read the screen of.
    ///
    /// Fail-closed, per the transport design's two-store rule: while a viewer
    /// owns the pty the daemon's emulator is frozen at the moment of that
    /// attach, so the pending-input rail would be asking a stale screen whether
    /// there is unsent typed input — and answering that question wrongly is
    /// exactly the harm the rail exists to prevent. Refusing is recoverable;
    /// eating a half-composed prompt is not.
    static let holderViewerAttachedRefusal =
        "A viewer is attached to this session, so the daemon cannot read its "
        + "screen to check for unsent input; close the tab or wait for it to "
        + "leave the viewer before hibernating"

    // MARK: - Park

    /// Park a holder-backed session: end the job its holder forked, then record
    /// the row as parked with no pids on it.
    ///
    /// Entered from `performHibernate` with `hibernatesInFlight` already
    /// claimed, and with NO tmux server lock — a holder session has no server,
    /// so there is nothing for a server lock to exclude. `hibernatesInFlight`
    /// is the whole exclusion here, and it is enough: every mutation below
    /// addresses one terminal row and one holder.
    func performHolderHibernate(
        terminal: Terminal,
        worktree: LocalWorktree,
        reason: HibernateReason,
        policy: HibernateEligibilityPolicy
    ) async -> HibernateResult {
        // Re-read and re-check, in the same order and with the same refusal
        // strings the tmux path uses under its server lock. This method is
        // actor-reentrant across the polite-exit poll below, so the row it
        // decided on must be the row it acts on.
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
        guard let sessionID = currentTerminal.claudeSessionID else {
            return .notEligible(reason: "No session id to resume later")
        }
        if let refusal = hibernationRefusal(terminal: currentTerminal, policy: policy) {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return refusal
        }

        // No registry means no reader, no way to write `/exit`, and no way to
        // abandon the holder afterwards. Say so by name rather than parking a
        // row whose process nothing in this daemon can end.
        guard let registry = holderRegistry else {
            return .notEligible(reason: "this daemon has no holder registry")
        }

        // Rail: typed-but-unsent input, read off the daemon's own emulator.
        // Fail-closed on both halves — a viewer holding the pty, or no reader
        // at all — because either one means the screen this rail would judge is
        // not the screen the session is showing.
        guard await registry.viewerAttachment(for: terminal.id) == nil,
              let reader = await registry.reader(for: terminal.id) else {
            logger.debug("hibernate: refusing \(terminal.id, privacy: .public) — the daemon is not this session's reader")
            return .notEligible(reason: Self.holderViewerAttachedRefusal)
        }
        let screen = await reader.renderScreen()
        if HibernationSafetyChecks.hasPendingInput(paneCapture: screen) {
            logger.debug("hibernate: skipping \(terminal.id, privacy: .public) — pending typed input in prompt")
            return .notEligible(reason: "Terminal has unsent typed input")
        }
        let capturedSnapshot: String? = screen.isEmpty ? nil : screen

        // Rail: transcript-tail validity, identical to the tmux path. Killing
        // mid-write can leave an unresumable jsonl.
        if let transcriptPath = currentTerminal.transcriptPath,
           let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
           !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) {
            logger.warning("hibernate: skipping \(terminal.id, privacy: .public) — transcript tail not parseable, would be unresumable")
            return .notEligible(reason: "Transcript is mid-write; try again shortly")
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
        // Polite park: `/exit` in band, so Claude flushes its transcript, shuts
        // down MCP children and fires Stop hooks. Written to the pty the daemon
        // is already reading — the same descriptor `terminal.send` uses — rather
        // than through tmux `send-keys`, which addresses a pane this row has
        // not got.
        try? await reader.write(Data("/exit\r".utf8))
        var gone = await pollUntilChildIsGone(
            childPID: childPID, terminalID: terminal.id, registry: registry,
            attempts: exitPollAttempts)

        if !gone {
            // The polite exit did not take. `abandon` is the escalation: the
            // holder is told to let go (closing the pty master), the job is
            // killed by process group, and the holder's corpse is collected.
            logger.debug("hibernate: /exit did not end the job for \(terminal.id, privacy: .public) within the poll window — abandoning the holder")
            if let unfinished = await registry.abandon(terminal: currentTerminal) {
                logger.warning("hibernate: holder teardown for \(terminal.id, privacy: .public) was incomplete: \(unfinished, privacy: .public)")
            }
            gone = await pollUntilChildIsGone(
                childPID: childPID, terminalID: terminal.id, registry: registry,
                attempts: holderEscalationAttempts)
        } else {
            // Gone politely, so the holder was never told to let go — and a
            // holder whose child has exited winds itself down, which is a race
            // this call does not need to win. `childPID: 0` is the sentinel
            // `dispose` refuses to signal, and that is the point: the recorded
            // pid is now free and the next process to take that number is
            // somebody else's.
            do {
                let socketPath = try HolderRendezvous.socketPath(
                    sessionID: terminal.id, environment: registry.environment)
                await registry.abandon(
                    terminalID: terminal.id,
                    handle: HolderHandle(
                        holderPID: currentTerminal.holderPID ?? 0,
                        childPID: 0,
                        socketPath: socketPath))
            } catch {
                // Nothing is leaked by skipping it: the job is confirmed gone
                // and its holder exits when its child does.
                logger.warning("hibernate: could not derive the rendezvous path for \(terminal.id, privacy: .public), so its holder was not told to let go: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard gone else {
            // THE invariant. The row must not claim parked over a process that
            // is still running: nothing would ever reclaim it, and a wake would
            // spawn a second agent onto the same session. Roll the intent back
            // — `clearHibernated` nils both park columns and the pending
            // incarnation — and report the pid so an operator can act.
            do {
                try await db.terminals.clearHibernated(id: terminal.id)
            } catch {
                logger.error("hibernate: the job for \(terminal.id, privacy: .public) survived and the park intent could not be rolled back: \(error.localizedDescription, privacy: .public)")
            }
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            logger.error("hibernate: holder child \(childPID, privacy: .public) for terminal \(terminal.id, privacy: .public) did not exit; the row was left awake")
            return .notEligible(
                reason: "holder child \(childPID) did not exit; the session was left running")
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
        inputActivity.forget(paneID: InputActivityTracker.key(for: currentTerminal))

        guard let persisted = try? await db.terminals.get(id: terminal.id),
              persisted.isParked else {
            logger.warning("hibernate: prepared row disappeared or changed during the holder park for \(terminal.id, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to verify hibernation")
        }
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        broadcastHibernation(
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

    private func childIsGone(
        childPID: Int32, terminalID: UUID, registry: HolderRegistry
    ) async -> Bool {
        let status = await registry.lastKnownStatus(for: terminalID)
        switch status {
        case .exited, .exitedStatusUnknown: return true
        case .alive, nil: break
        }
        let statusAlive = (status == .alive)
        // A pid of 0 or below names nothing this daemon may signal or wait on,
        // so the process table has no answer to give and the registry's is the
        // only evidence there is. An explicit `.alive` is a positive report
        // from the holder that its job is still running, and it must not be
        // thrown away because the row's `child_pid` column happened to be
        // NULL — that reading would let a park finalize over a live child,
        // which is the one thing this whole path exists to prevent. With no
        // report either way, a row that never recorded a child pid has nothing
        // to outlive.
        guard childPID > 1 else { return !statusAlive }
        guard signaller.isAlive(childPID) else { return true }
        // `ps -o stat=` reports a corpse as `Z...`. It answers `kill(pid, 0)`,
        // so liveness alone cannot tell it from a running process — and the
        // distinction matters here: the job has finished, and the `waitpid`
        // still owed to it belongs to the holder, not to this park.
        return signaller.stat(childPID)?.hasPrefix("Z") ?? false
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
    /// **It is deliberately ungated, and that is not an oversight.**
    /// `holder_hibernation_enabled` decides whether a row may be parked; this
    /// arm judges rows that already are, including the ones the soak parked
    /// before the flag was turned off. Gating it would make turning the flag
    /// off strand exactly the rows an abort most needs healed. Both of its
    /// mutations are safety-only in the direction a disabled feature wants:
    /// one un-parks a row over a child that is verifiably alive, the other
    /// clears pids that verifiably name nothing. Neither ends a process,
    /// neither parks anything, and neither can be undone into a worse state
    /// than the row was already in.
    func reconcileParkedHolderRow(_ terminal: Terminal) async {
        guard let childPID = terminal.childPID, childPID > 1 else { return }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: terminal.holderChildStartedAt ?? terminal.createdAt,
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
            of: terminal.holderChildStartedAt ?? terminal.createdAt,
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

    /// The mutate half of a holder wake: spawn a fresh holder running the
    /// resume command, record what it started, then un-park the row.
    ///
    /// The ordering is the same one `WorktreeLifecycle+Create` uses and for the
    /// same reason: the pids are persisted BEFORE the row stops being parked,
    /// so a failure in between leaves a parked row that names live processes —
    /// which `reconcileOnStartup` un-parks — rather than an awake row that
    /// names nothing, which nothing would ever reconcile.
    func wakeHolderSection(
        terminal: Terminal,
        worktree: LocalWorktree,
        sessionID: String,
        expectedReplacementState: TerminalReplacementSnapshot,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        cols: Int?,
        rows: Int?
    ) async -> WakeResult {
        guard let registry = holderRegistry else {
            return .respawnFailed(
                reason: "this daemon has no holder registry, so the session cannot be resumed on the pty-holder transport")
        }
        // "Registry present" is not "can spawn": a daemon whose `TBDHolder`
        // binary has moved still builds a registry, because adoption of a
        // running holder needs no executable. Only this fact may gate a spawn.
        guard registry.canSpawn else {
            return .respawnFailed(
                reason: "the TBDHolder helper is missing beside the daemon, so no holder can be started for this session; the row stays parked")
        }

        guard let currentTerminal = try? await db.terminals.get(id: terminal.id),
              expectedReplacementState.matches(currentTerminal) else {
            return .respawnFailed(reason: "terminal changed while wake was preparing; retry")
        }

        let incarnationID: UUID
        do {
            guard let prepared = try await db.terminals.prepareHibernatedAgentRespawn(
                id: terminal.id,
                expectedState: expectedReplacementState,
                at: now()) else {
                return .respawnFailed(reason: "terminal changed before wake could launch; retry")
            }
            incarnationID = prepared
        } catch {
            logger.warning("wake: failed to prepare the replacement agent for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "preparing the replacement agent failed: \(error.localizedDescription)")
        }
        let replacementEnv = AgentProcessEnvironment.replacement(
            base: env, incarnationID: incarnationID)

        let handle: HolderHandle
        do {
            handle = try await registry.spawn(
                terminalID: terminal.id,
                launch: WorktreeLifecycle.holderLaunch(
                    shellCommand: spawnCommand,
                    env: replacementEnv,
                    sensitiveEnv: sensitiveEnv,
                    workingDirectory: worktree.path,
                    cols: cols ?? TmuxManager.defaultCols,
                    rows: rows ?? TmuxManager.defaultRows,
                    environment: registry.environment))
        } catch {
            // The row stays parked, so the next focus or menu retry can wake it.
            logger.warning("wake: could not start a holder for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "starting a holder for this session failed: \(error.localizedDescription)")
        }

        do {
            try await db.terminals.setHolderProcess(
                id: terminal.id,
                holderPID: handle.holderPID,
                childPID: handle.childPID,
                startedAt: now())
        } catch {
            // A holder and a job no row names would be reclaimable by nothing,
            // so undo the spawn from the failing call itself.
            await registry.abandon(terminalID: terminal.id, handle: handle)
            logger.warning("wake: started a holder for \(terminal.id, privacy: .public) but could not record its pids, so it was abandoned: \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "the replacement agent started, but recording its process ids failed: \(error.localizedDescription)")
        }

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
        broadcastHibernation(
            terminal: currentTerminal, hibernated: false, keepWarm: currentTerminal.keepWarm,
            tmuxWindowID: "", tmuxPaneID: "")
        // No `SessionRecaptureScheduler`: it re-reads the session id off a tmux
        // pane's screen, and this row has no pane. A holder session's resumed
        // id is recaptured the way every other fact about it is — from hooks.
        logger.info("woke holder-backed terminal \(terminal.id, privacy: .public) (resume \(sessionID, privacy: .public), holder \(handle.holderPID, privacy: .public), child \(handle.childPID, privacy: .public))")
        return .ok
    }
}
