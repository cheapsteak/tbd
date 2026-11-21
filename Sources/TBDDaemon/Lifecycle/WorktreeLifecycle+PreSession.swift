import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeLifecycle")
private let overlayLogger = Logger(subsystem: "com.tbd.daemon", category: "claude-overlay")

/// Descriptor for a spawned pre-session hook terminal. Phase 3 (the marker
/// wait + primary terminal spawn) consumes it.
struct PreSessionSpawn: Sendable {
    let terminalID: UUID
    /// The tmux server the worktree names, which a hook tab left on tmux by an
    /// earlier build may still be running in. Named in the log when such a tab
    /// is torn down, and never asked anything.
    let tmuxServer: String
    let markerPath: String
    let hookPath: String
    /// The transport the hook tab was born onto. The liveness probe and the
    /// teardown branch on it: a holder-backed tab has pids to check and
    /// reclaim, and a tab left on tmux by an earlier build has neither.
    let transport: TerminalTransport
    /// The pids the holder spawn recorded, for the one path that must reclaim
    /// them after the terminal row is gone (a worktree cascaded away mid-wait).
    /// Nil on the tmux transport.
    let holderPID: Int32?
    let childPID: Int32?
    /// When the job behind `childPID` started, as the row recorded it.
    ///
    /// The teardown may not signal that pid without it: a pid on its own is not
    /// an identity, and the start time is the one fact `execve` cannot move.
    /// Nil on the tmux transport, and nil for a row written before the column
    /// existed — which the readers spell `holderChildStartedAt ?? createdAt`,
    /// the same fallback the reaper's holder leg and the park ladder use.
    let childStartedAt: Date?

    /// Written out rather than synthesized so the tests that describe a wait
    /// without spawning one can leave the holder fields out.
    init(
        terminalID: UUID,
        tmuxServer: String,
        markerPath: String,
        hookPath: String,
        transport: TerminalTransport,
        holderPID: Int32? = nil,
        childPID: Int32? = nil,
        childStartedAt: Date? = nil
    ) {
        self.terminalID = terminalID
        self.tmuxServer = tmuxServer
        self.markerPath = markerPath
        self.hookPath = hookPath
        self.transport = transport
        self.holderPID = holderPID
        self.childPID = childPID
        self.childStartedAt = childStartedAt
    }
}

/// How a pre-session hook run ended.
enum PreSessionOutcome: Equatable, Sendable {
    /// The hook wrote its exit code to the marker file.
    case completed(exitCode: Int)
    /// The marker never appeared within the timeout.
    case timedOut
    /// The hook's tmux window disappeared before the marker was written
    /// (user killed the pane). Treated as failure.
    case paneKilled
}

/// What `runPreSessionPhase3` does to the worktree row once the primary
/// terminals are spawned. Phase 3 must always flip the status eventually —
/// the row would otherwise be stuck in `.creating` forever.
enum PreSessionCompletionAction: Sendable {
    /// Create path: set status to `.active`.
    case markActive
    /// Revive path: `db.worktrees.revive(id:clearSessions:)` — flips to
    /// `.active`, clears `archivedAt`, and (when `clearSessions` is true)
    /// clears `archivedClaudeSessions`, preserving the legacy revive
    /// semantics around session restoration.
    case revive(clearSessions: Bool)
}

extension WorktreeLifecycle {

    // MARK: - Paths & command construction

    /// Directory holding pre-session completion markers. TBD_HOME-relative so
    /// tests redirect automatically.
    static var preSessionRuntimeDir: String {
        TBDConstants.configDir
            .appendingPathComponent("runtime")
            .appendingPathComponent("presession")
            .path
    }

    /// Marker file the wrapped hook command writes its exit code to.
    static func preSessionMarkerPath(worktreeID: UUID) -> String {
        (preSessionRuntimeDir as NSString)
            .appendingPathComponent(worktreeID.uuidString)
    }

    /// Environment for hook panes (preSession + setup), passed as the spawn's
    /// `sensitiveEnv` so it lands in the PROCESS environment before zsh starts. The regular
    /// `env:` dict is inlined as `export KEY='V'; ` statements inside the
    /// `-c` command string, which runs AFTER every startup file (profile and
    /// rc) completes, so it cannot affect anything the startup files do.
    /// oh-my-zsh's tools/check_for_upgrade.sh
    /// honors the legacy `DISABLE_AUTO_UPDATE` var (mapped to
    /// `zstyle ':omz:update' mode disabled`), so this skips its interactive
    /// "Would you like to update?" prompt that would otherwise block the hook
    /// command until the user answers or the preSession wait times out.
    /// Deliberately per-window (never `setenv -g`): plain shell tabs must
    /// keep omz update checks — a human is present there. Agent (claude/codex)
    /// tabs also suppress the prompt, but at their own spawn sites
    /// (`ClaudeSpawnCommandBuilder` and the codex spawn env), since a spawned
    /// agent command must never block on an interactive prompt. Callers apply
    /// this env only when the hook actually resolves — a hook-less "Setup"
    /// tab is a plain shell and keeps update checks.
    static let hookPaneEnv: [String: String] = ["DISABLE_AUTO_UPDATE": "true"]

    /// Wraps the hook so its exit code lands in the marker file and the pane
    /// stays alive as a usable shell afterward (same rationale as
    /// `shellWrapped`). Paths are quoted with `shellEscape`, as in `shellWrapped`.
    static func preSessionCommand(
        hookPath: String, runtimeDir: String, markerPath: String, shell: String
    ) -> String {
        return "\(shellEscape(hookPath)); __tbd_rc=$?; "
            + "/bin/mkdir -p \(shellEscape(runtimeDir)); "
            + "/bin/echo $__tbd_rc > \(shellEscape(markerPath)); "
            + "exec \(shell)"
    }

    // MARK: - Phase 2b: spawn the pre-session terminal

    /// Resolves the `preSession` hook and, if present, creates its terminal.
    /// Returns nil when no hook resolves — callers then spawn the primary
    /// terminals directly (today's behavior, unchanged).
    ///
    /// `claimsFocus` distinguishes the two callers. Create/revive spawn this
    /// as the FIRST and only window, so they claim tab order and focus. A
    /// manual re-run lands beside live agent tabs: it appends to the existing
    /// order and leaves `activeTabID` untouched.
    ///
    /// `repo` is optional because scratch spaces have none. `TBD_REPO_PATH`
    /// then falls back to the worktree's own path.
    ///
    /// `claudeSpawnExtras` are the Claude values of the create this hook gates,
    /// stored on the hook's row so phase 3 can apply them to the primary even
    /// when it runs from recovery, with nothing but rows to go on. The hook
    /// itself is a shell and ignores them.
    func spawnPreSessionTerminal(
        worktree: Worktree, repo: Repo?,
        worktreePath: String,
        cols: Int? = nil, rows: Int? = nil,
        claimsFocus: Bool = true,
        claudeSpawnExtras: ClaudeSpawnExtras? = nil
    ) async throws -> PreSessionSpawn? {
        guard let hookPath = hooks.resolve(
            event: .preSession,
            repoPath: worktreePath,
            appHookPath: worktree.repoID.map {
                TBDConstants.hookPath(repoID: $0, eventName: HookEvent.preSession.rawValue)
            }
        ) else {
            return nil
        }

        let worktreeID = worktree.id
        let resolvedCols = cols ?? TerminalSpawnSize.defaultCols
        let resolvedRows = rows ?? TerminalSpawnSize.defaultRows

        let terminalID = UUID()
        let markerPath = Self.preSessionMarkerPath(worktreeID: worktreeID)
        // Delete any stale marker from a previous run of this worktree ID.
        try? FileManager.default.removeItem(atPath: markerPath)

        let command = Self.preSessionCommand(
            hookPath: hookPath,
            runtimeDir: Self.preSessionRuntimeDir,
            markerPath: markerPath,
            shell: defaultShell
        )
        // The spawn gate, the same one every other spawn asks. A hook tab is a
        // session like any other once it is running: it holds a pty, and it is
        // read through the same surfaces. A refusal throws before anything is
        // spawned, and the caller reports it as its own failure.
        let transport = try TerminalSpawnTransport.decide(registry: holderRegistry).get()
        let currentWorktree = try await Self.worktreeForSpawn(
            db: db, id: worktreeID, allowedStatuses: [worktree.status])
        let currentPath = currentWorktree.path
        let env: [String: String] = [
            "TBD_WORKTREE_ID": worktreeID.uuidString,
            "TBD_TERMINAL_ID": terminalID.uuidString,
            "TBD_EVENT": HookEvent.preSession.rawValue,
            "TBD_WORKTREE_NAME": currentWorktree.name,
            "TBD_WORKTREE_PATH": currentPath,
            "TBD_REPO_PATH": repo?.path ?? currentPath,
            "TBD_BRANCH": currentWorktree.branch,
        ]
        // The one spawn-and-record step every path shares: it starts the
        // holder job, writes the row that records it, and owns the rollback.
        let terminal = try await spawnTerminal(
            id: terminalID,
            worktreeID: worktreeID,
            workingDirectory: currentPath,
            command: command,
            env: env,
            sensitiveEnv: Self.hookPaneEnv,
            cols: resolvedCols,
            rows: resolvedRows,
            label: TerminalLabel.preSession,
            claudeSessionID: nil,
            profileID: nil,
            kind: .shell,
            transport: transport,
            claudeSpawnExtras: claudeSpawnExtras)
        let tmuxServer = currentWorktree.tmuxServer
        if claimsFocus {
            // The pre-session terminal is the only tab until phase 3 runs.
            try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: [terminalID])
            try await db.worktrees.setActiveTabID(worktreeID: worktreeID, tabID: terminalID)
        } else {
            // Manual re-run: append beside the live agent tabs, don't steal focus.
            var order = try await db.worktrees.getTabOrder(worktreeID: worktreeID)
            order.append(terminalID)
            try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: order)
            // The create/revive path broadcasts terminalCreated for the primaries
            // later in phase 3; the hook tab there arrives bundled with the
            // worktree row. A re-run has no such follow-up broadcast, so the app
            // needs this one to render the tab immediately.
            subscriptions?.broadcast(delta: .terminalCreated(TerminalDelta(
                terminalID: terminalID,
                worktreeID: worktreeID,
                label: TerminalLabel.preSession
            )))
        }

        logger.info("preSession hook \(hookPath, privacy: .public) spawned for worktree \(worktreeID, privacy: .public); gating primary terminals on marker")
        return PreSessionSpawn(
            terminalID: terminalID,
            tmuxServer: tmuxServer,
            markerPath: markerPath,
            hookPath: hookPath,
            transport: terminal.transport,
            holderPID: terminal.holderPID,
            childPID: terminal.childPID,
            childStartedAt: terminal.holderChildStartedAt
        )
    }

    // MARK: - Phase 3: marker wait + primary spawn

    /// Reads + deletes the marker file if present, returning the recorded
    /// exit code. Returns nil when no marker exists yet.
    private static func consumeMarker(atPath path: String) -> PreSessionOutcome? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        let code = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        return .completed(exitCode: code)
    }

    /// Whether the hook's own terminal is still there to finish the run — the
    /// "did the user close it" probe.
    ///
    /// A tab is closed by deleting its row, and the teardown that does it
    /// disposes the holder in the same step, so a row that is gone is a closed
    /// tab. The job's own pid is the second half: a hook that was killed
    /// directly leaves the row untouched, and nothing else here would notice.
    /// A spawn that recorded no child pid answers on the row alone rather than
    /// reporting a dead tab it cannot see.
    ///
    /// A hook tab an earlier build started on tmux answers on its row alone
    /// too, because TBD runs no tmux command: a hook still running in tmux
    /// finishes and writes its marker, and one whose server is gone ends the
    /// wait at its timeout.
    ///
    /// **Only a nil result means the tab is gone.** A read that THREW says
    /// nothing about the row, and reading it as a deletion would report
    /// `.paneKilled` for a hook that is still running — after which phase 3
    /// starts the primary agent on a tree the hook has not finished preparing.
    /// A transient database error is answered "assume alive", the same way the
    /// worktree-row existence check in `runPreSessionPhase3` answers it, so the
    /// wait simply continues and the next poll asks again.
    private func hookTerminalIsAlive(preSession: PreSessionSpawn) async -> Bool {
        let row: Terminal?
        do {
            row = try await db.terminals.get(id: preSession.terminalID)
        } catch {
            logger.warning("hook terminal \(preSession.terminalID, privacy: .public) liveness check failed: \(error.localizedDescription, privacy: .public) — assuming its tab is still there and continuing the wait")
            return true
        }
        guard row != nil else { return false }
        guard preSession.transport == .holder, let childPID = preSession.childPID else {
            return true
        }
        return processSignaller.isAlive(childPID)
    }

    /// Polls for the completion marker. Short-circuits when the hook's terminal
    /// disappears (user closed it). Reads + deletes the marker.
    func waitForPreSessionCompletion(
        preSession: PreSessionSpawn
    ) async -> PreSessionOutcome {
        let deadline = Date().addingTimeInterval(preSessionTimeout)
        let pollNanos = UInt64(max(preSessionPollInterval, 0.01) * 1_000_000_000)
        while Date() < deadline {
            // Marker check first: if the hook finished and the user then
            // closed the pane, the recorded exit code wins.
            if let outcome = Self.consumeMarker(atPath: preSession.markerPath) {
                return outcome
            }
            let hookTabAlive = await hookTerminalIsAlive(preSession: preSession)
            if !hookTabAlive {
                // Same-iteration race: the hook can write the marker after the
                // fileExists check above and exit before the liveness check.
                // Re-check the marker once so a hook that actually finished
                // isn't misreported as a killed pane.
                if let outcome = Self.consumeMarker(atPath: preSession.markerPath) {
                    return outcome
                }
                return .paneKilled
            }
            // swiftlint:disable:next no_raw_task_sleep - already seamed: `preSessionPollInterval` / `preSessionTimeout` are injected `WorktreeLifecycle.init` parameters, exercised by Tests/TBDDaemonTests/PreSessionHookTests.swift (via PreSessionTestSupport's `makeLifecycle`, which injects 0.05); migrating to `any Clock<Duration>` would also have to restructure the `Date()`-based deadline above, since the existential pins `Duration` but not `Instant`; see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(nanoseconds: pollNanos)
        }
        // Deadline race: the marker may have landed during the final poll
        // sleep. Honor a hook that finished (just barely too late) instead of
        // reporting a timeout — and consume the marker so it never leaks.
        if let outcome = Self.consumeMarker(atPath: preSession.markerPath) {
            return outcome
        }
        return .timedOut
    }

    /// Phase 3: await the pre-session hook, notify on failure/timeout, then
    /// spawn the primary terminals regardless of hook outcome.
    ///
    /// Never throws and never deletes the worktree row — by the time phase 3
    /// runs, the git checkout is valid. Spawn errors are logged + notified.
    /// `completionAction` decides the final status flip (`.markActive` on the
    /// create path, `.revive` on the revive path); it always runs no matter
    /// what happened, so the row never sticks in `.creating`.
    ///
    /// `claudeSpawnExtras` are the create's Claude values for the primary.
    /// When the caller passes none — recovery, which resumes a wait from rows
    /// alone — the hook's own row supplies them (`spawnPreSessionTerminal`
    /// stored them there). `archivedClaudeSpawnExtras` is a revive's archived
    /// map, passed from the same worktree row as `archivedClaudeSessions`:
    /// each restored session starts with its own values from it.
    func runPreSessionPhase3(
        preSession: PreSessionSpawn,
        worktree: Worktree, repo: Repo,
        worktreePath: String,
        skipClaude: Bool,
        archivedClaudeSessions: [String]? = nil,
        archivedClaudeSpawnExtras: [String: ClaudeSpawnExtras]? = nil,
        archivedAgentTabs: [ArchivedAgentTab]? = nil,
        preparedArchivedCodexLaunches: [Int: CodexLaunchPreparation]? = nil,
        initialPrompt: String? = nil,
        cols: Int? = nil, rows: Int? = nil,
        completionAction: PreSessionCompletionAction,
        overrideProfileID: UUID? = nil,
        modelOverride: String? = nil,
        codexModelOverride: String? = nil,
        primaryAgentPreference: PrimaryAgentPreference? = nil,
        claudeSpawnExtras: ClaudeSpawnExtras? = nil,
        carryover: ConversationCarryover? = nil,
        preparedCodexLaunch: CodexLaunchPreparation? = nil
    ) async {
        // Read before the wait: the hook's row is certain to exist now, and a
        // holder-backed tab the user closes mid-wait takes its row with it.
        let primarySpawnExtras: ClaudeSpawnExtras?
        if let claudeSpawnExtras {
            primarySpawnExtras = claudeSpawnExtras
        } else {
            do {
                primarySpawnExtras = try await db.terminals.get(id: preSession.terminalID)?
                    .claudeSpawnExtras
            } catch {
                overlayLogger.warning("phase-3: could not read the Claude values on pre-session terminal \(preSession.terminalID, privacy: .public): \(error.localizedDescription, privacy: .public) — the primary starts without them")
                primarySpawnExtras = nil
            }
        }

        let outcome = await waitForPreSessionCompletion(preSession: preSession)
        // The marker must never outlive the wait, whatever the outcome —
        // `.completed` consumes it inside the wait; this catches any straggler
        // written between the wait's last check and now.
        try? FileManager.default.removeItem(atPath: preSession.markerPath)

        // The worktree row can vanish mid-wait (repo remove cascades a
        // deleteForRepo while phase 3 is parked on the marker). Spawning the
        // primary terminals would then fail the terminal FK insert AFTER the
        // holder (and its Claude process) was started — orphaning both.
        // Bail out before any spawn: reclaim the hook tab's holder
        // best-effort; the marker is already gone (removed above), and there
        // is no row left to flip or notify. A thrown DB error is NOT proof the
        // row is gone — treat it as transient and proceed with the spawn
        // rather than tear down a valid worktree.
        // Location-neutral on purpose: the question is "did the row vanish",
        // and `getLocal` would answer nil for a row that exists but is remote
        // — indistinguishable here from deleted, and the branch below reclaims
        // a live holder. Existence is not a locality question.
        let rowExists: Bool
        do {
            rowExists = try await db.worktrees.get(id: worktree.id) != nil
        } catch {
            logger.warning("phase-3: worktree existence check failed for \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public) — assuming the row still exists and proceeding")
            rowExists = true
        }
        guard rowExists else {
            logger.warning("phase-3: worktree \(worktree.id, privacy: .public) row disappeared mid-wait — skipping primary spawn and cleaning up")
            switch preSession.transport {
            case .tmux:
                // A hook tab an earlier build started on tmux: TBD runs no
                // tmux command, so whatever tmux still runs for it is left as
                // it is (`closeLeftoverTmuxRow`).
                logger.notice("phase-3: the hook tab \(preSession.terminalID, privacy: .public) of the vanished worktree is on tmux; its session may still be running in tmux server \(preSession.tmuxServer, privacy: .public). \(LeftoverTmuxSession.endingAdvice(server: preSession.tmuxServer), privacy: .public)")
            case .holder:
                // The terminal row went with the worktree, so nothing can read
                // the pids back any more — this is the last moment either can
                // be named, and the descriptor phase 2b returned is where they
                // are.
                await abandonHookHolder(
                    terminalID: preSession.terminalID,
                    holderPID: preSession.holderPID,
                    childPID: preSession.childPID,
                    childStartedAt: preSession.childStartedAt)
            }
            return
        }

        let succeeded = outcome == .completed(exitCode: 0)

        switch outcome {
        case .completed(exitCode: 0):
            logger.info("preSession hook completed for worktree \(worktree.id, privacy: .public)")
        case .completed(let exitCode):
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook failed (exit \(exitCode)) — starting the agent anyway"
            )
        case .timedOut:
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook timed out after \(Int(preSessionTimeout))s — starting the agent anyway"
            )
        case .paneKilled:
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook terminal closed before the hook finished — starting the agent anyway"
            )
        }

        var primarySpawnSucceeded = false
        do {
            let created = try await spawnPrimaryTerminals(
                worktree: worktree, repo: repo,
                worktreePath: worktreePath,
                skipClaude: skipClaude,
                archivedClaudeSessions: archivedClaudeSessions,
                archivedClaudeSpawnExtras: archivedClaudeSpawnExtras,
                archivedAgentTabs: archivedAgentTabs,
                preparedArchivedCodexLaunches: preparedArchivedCodexLaunches,
                initialPrompt: initialPrompt,
                cols: cols, rows: rows,
                // On success the hook tab is about to be deleted — never splice
                // it into tab order. On failure it stays, at index 1 as before.
                preSessionTerminalID: succeeded ? nil : preSession.terminalID,
                overrideProfileID: overrideProfileID,
                modelOverride: modelOverride,
                codexModelOverride: codexModelOverride,
                primaryAgentPreference: primaryAgentPreference,
                claudeSpawnExtras: primarySpawnExtras,
                carryover: carryover,
                preparedCodexLaunch: preparedCodexLaunch
            )
            primarySpawnSucceeded = true
            for terminal in created {
                subscriptions?.broadcast(delta: .terminalCreated(TerminalDelta(
                    terminalID: terminal.id,
                    worktreeID: worktree.id,
                    label: terminal.label
                )))
            }

            // Close the hook tab only after the primaries exist and
            // `spawnPrimaryTerminals` has moved activeTabID onto the primary —
            // the worktree is never momentarily tab-less, and focus never sits
            // on a tab that is about to vanish. Deliberately INSIDE the `do`:
            // if the spawn threw, the primaries don't exist, so tearing the
            // hook tab down would leave the worktree tab-less — keep it instead.
            // `.paneKilled` already has no window; the kill is best-effort so
            // the row/tab cleanup still runs.
            if succeeded {
                await closePreSessionTerminal(worktree: worktree, preSession: preSession)
            }
        } catch {
            if let archivedAgentTabs {
                try? await orderArchivedRestore(worktreeID: worktree.id, tabs: archivedAgentTabs)
            }
            logger.error("phase-3 primary terminal spawn failed for worktree \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Failed to start agent terminals after the pre-session hook: \(error.localizedDescription)"
            )
        }

        // Never leave the worktree stuck in .creating — the checkout is valid.
        do {
            switch completionAction {
            case .markActive:
                try await db.worktrees.updateStatus(id: worktree.id, status: .active)
            case .revive(let clearSessions):
                try await db.worktrees.revive(id: worktree.id, clearSessions: clearSessions && primarySpawnSucceeded)
                // Deliberate revive: disarm auto-archive so a still-merged PR
                // doesn't immediately re-archive the worktree the user just revived.
                do {
                    try await db.worktrees.setAutoArchiveOnMerge(id: worktree.id, value: false)
                } catch {
                    logger.warning("failed to disarm auto-archive for \(worktree.id, privacy: .public): \(error, privacy: .public)")
                }
                // Likewise disarm auto-hibernate-on-merge: a still-merged PR would
                // otherwise immediately re-park the sessions in the worktree the
                // user just deliberately revived.
                do {
                    try await db.worktrees.setAutoHibernateOnMerge(id: worktree.id, value: false)
                } catch {
                    logger.warning("failed to disarm auto-hibernate for \(worktree.id, privacy: .public): \(error, privacy: .public)")
                }
            }
        } catch {
            logger.error("phase-3 status update failed for worktree \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tears the pre-session tab down after a clean run: kill the tmux window,
    /// delete the terminal + tab rows, broadcast `.terminalRemoved`.
    ///
    /// Deliberately NOT reusing `RPCRouter.handleTerminalDelete`: that handler
    /// also cancels scheduled resumes, clears pending questions, and reclaims
    /// a per-session `ClaudeHookOverlay` — all Claude
    /// concerns, all no-ops for this `.shell` tab, and several reach for
    /// `RPCRouter` state the lifecycle doesn't hold.
    ///
    /// Best-effort: a failure here must never take down the worktree, whose
    /// checkout and agent terminals are already valid.
    func closePreSessionTerminal(worktree: Worktree, preSession: PreSessionSpawn) async {
        await closeHookTerminal(worktree: worktree, preSession: preSession)
    }

    /// Shared hook-tab teardown (pre-session and auto-closed setup tabs), from
    /// the descriptor the tab's spawn returned: tear the session down in the
    /// terms its transport uses, delete the terminal + tab rows, prune the tab
    /// from the persisted tab order, broadcast `.terminalRemoved`. The prune is
    /// a no-op on the create-success path (the primary spawn already set an
    /// order without the hook tab) and keeps the stored order consistent on the
    /// paths that appended the tab (manual re-run, setup auto-close).
    ///
    /// The row is the authority on the transport for as long as it can be read;
    /// the descriptor answers when it cannot. Both halves are load-bearing. A
    /// row that has already been deleted — or one whose read threw — still
    /// names a holder, the job it forked and its rendezvous files that outlive
    /// the only record of their pids. The descriptor is where those pids are,
    /// which is why the rowless case is reclaimable at all.
    ///
    /// A read that *throws* is deliberately folded into "unreadable" rather
    /// than retried or surfaced: the answer then comes from the descriptor,
    /// which is a strictly safer place to take it from than the alternative of
    /// giving up on a teardown whose whole purpose is reclamation. The two
    /// halves then differ only in where the pids are read from — both reclaim
    /// through `abandonHookHolder`. A row-backed *agent* tab would not be safe
    /// to tear down this way, which is why this reasoning is local to hook
    /// tabs.
    func closeHookTerminal(worktree: Worktree, preSession: PreSessionSpawn) async {
        let terminalID = preSession.terminalID
        let terminal = try? await db.terminals.get(id: terminalID)
        switch terminal?.transport ?? preSession.transport {
        case .holder:
            // The Closed Terminals entry comes from the daemon's own emulator,
            // through the same helper every history-keeping holder teardown
            // uses, and before the reclaim below releases the reader.
            //
            // Reclaimed through `abandonHookHolder` on both halves, not
            // through `disposeHolder`: the row-shaped teardown is an
            // unverified kill by recorded pid, which is exactly what a hook
            // tab must not do (see
            // `HolderRegistry.abandonVerifiedJob`). The row is still the better
            // source for the pids while it can be read.
            if let terminal {
                await Self.recordHolderClosedTerminal(
                    terminal, registry: holderRegistry, resolver: holderScreenResolver,
                    history: db.terminalHistory)
                await abandonHookHolder(
                    terminalID: terminal.id,
                    holderPID: terminal.holderPID,
                    childPID: terminal.childPID,
                    // The anchor every other reader of a holder row uses, and
                    // the reason the fallback is `createdAt`: a row written
                    // before the start-time column existed still has to be
                    // reclaimable.
                    childStartedAt: HolderChildIdentity.anchor(of: terminal))
            } else {
                // No row to read the pids back from, so the descriptor's own
                // pids are all there is — the same reclaim phase 3 does when a
                // cascading worktree delete takes the terminal row with it.
                await abandonHookHolder(
                    terminalID: terminalID, holderPID: preSession.holderPID,
                    childPID: preSession.childPID,
                    childStartedAt: preSession.childStartedAt)
            }
        case .tmux:
            // A hook tab an earlier build started on tmux. No tmux command
            // runs; the row's own teardown is all there is. A row that could
            // not be read has nothing to say about its session, and nothing to
            // keep. A row whose entry could not be marked is kept with its
            // tab, so it keeps naming its session to the resume gate; closing
            // the tab by hand tries again.
            if let terminal {
                do {
                    try await Self.closeLeftoverTmuxRow(
                        terminal, server: preSession.tmuxServer, history: db.terminalHistory)
                } catch {
                    logger.warning("keeping hook terminal \(terminalID, privacy: .public): \(String(describing: error), privacy: .public)")
                    return
                }
            }
        }
        do {
            try await db.terminals.delete(id: terminalID)
            await sessionTitles.forget(terminalID: terminalID)
            try await db.tabs.delete(tabID: terminalID)
            var order = try await db.worktrees.getTabOrder(worktreeID: worktree.id)
            if order.contains(terminalID) {
                order.removeAll { $0 == terminalID }
                try await db.worktrees.setTabOrder(worktreeID: worktree.id, tabIDs: order)
            }
            subscriptions?.broadcast(delta: .terminalRemoved(TerminalIDDelta(
                terminalID: terminalID
            )))
        } catch {
            logger.warning("failed to close hook terminal \(terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reclaims a holder-backed hook tab from the pids its spawn recorded —
    /// identity-checking the job before signalling it.
    ///
    /// `abandonVerifiedJob` rather than the general `abandon`, and that is the
    /// point of this method existing. A hook tab's job has very often exited
    /// before anything tears the tab down — the setup tab auto-closes *because*
    /// the hook finished — so the recorded pid may by then belong to whatever
    /// the kernel handed the number to next, and the general path would kill it
    /// and its process group on a recorded number alone.
    ///
    /// It also serves the case where the row is already gone: the row-shaped
    /// teardown (`disposeHolder`) reads its pids off a row that no longer
    /// exists. A daemon with no registry is reported rather than passed over —
    /// it is exactly the daemon whose holder and job nothing else would ever
    /// find.
    private func abandonHookHolder(
        terminalID: UUID, holderPID: Int32?, childPID: Int32?, childStartedAt: Date?
    ) async {
        guard let holderRegistry else {
            logger.warning("hook terminal \(terminalID, privacy: .public) runs on the holder transport but this daemon has no holder registry, so its holder and job were left running")
            return
        }
        if let left = await holderRegistry.abandonVerifiedJob(
            terminalID: terminalID, holderPID: holderPID, childPID: childPID,
            childStartedAt: childStartedAt
        ) {
            logger.warning("hook terminal \(terminalID, privacy: .public) holder teardown incomplete: \(left, privacy: .public)")
        }
    }

    /// Records a daemon notification and broadcasts it (same pattern as
    /// `handleNotify` in RPCRouter+TerminalHandlers).
    func notifyPreSessionProblem(
        worktree: Worktree, terminalID: UUID, message: String
    ) async {
        logger.warning("preSession: \(message, privacy: .public) (worktree \(worktree.id, privacy: .public))")
        do {
            let notification = try await db.notifications.create(
                worktreeID: worktree.id,
                type: .error,
                message: message,
                terminalID: terminalID
            )
            subscriptions?.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID
            )))
        } catch {
            logger.error("failed to record preSession notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Why a manual `preSession` re-run was refused.
public enum RerunPreSessionError: LocalizedError, Equatable, CustomStringConvertible {
    case worktreeNotFound(UUID)
    case noHookConfigured
    case alreadyRunning
    case worktreeBusy

    public var description: String {
        switch self {
        case .worktreeNotFound(let id):
            return "Worktree not found: \(id)"
        case .noHookConfigured:
            return "No pre-session hook is configured for this worktree."
        case .alreadyRunning:
            return "Pre-session hook is already running for this worktree."
        case .worktreeBusy:
            return "This worktree is still being created — its pre-session hook is already running."
        }
    }

    public var errorDescription: String? { description }
}

extension WorktreeLifecycle {

    /// Re-runs the `preSession` hook in a fresh, non-focused tab, leaving the
    /// worktree's status and its running agents completely alone.
    ///
    /// Returns as soon as the hook's terminal exists. A detached task awaits the
    /// outcome, then closes the tab (clean exit) or leaves it open with its
    /// output and records an `.error` notification (non-zero / timeout / killed
    /// pane).
    func rerunPreSessionHook(
        worktreeID: UUID, cols: Int? = nil, rows: Int? = nil
    ) async throws {
        guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
            throw RerunPreSessionError.worktreeNotFound(worktreeID)
        }
        // A `.creating` worktree is already running its hook under phase 3.
        guard worktree.status != .creating else {
            throw RerunPreSessionError.worktreeBusy
        }
        var repo: Repo?
        if let repoID = worktree.repoID {
            repo = try await db.repos.get(id: repoID)
        }

        // Claim before spawning: the marker path is keyed by worktree ID, so two
        // concurrent runs would race the same file and each other's teardown.
        guard await preSessionRuns.begin(worktreeID) else {
            throw RerunPreSessionError.alreadyRunning
        }

        let spawn: PreSessionSpawn?
        do {
            spawn = try await spawnPreSessionTerminal(
                worktree: worktree.worktree, repo: repo,
                worktreePath: worktree.path,
                cols: cols, rows: rows,
                claimsFocus: false
            )
        } catch {
            await preSessionRuns.end(worktreeID)
            throw error
        }

        guard let spawn else {
            await preSessionRuns.end(worktreeID)
            throw RerunPreSessionError.noHookConfigured
        }

        logger.info("preSession hook re-run started for worktree \(worktreeID, privacy: .public)")

        let lifecycle = self
        Task.detached {
            await lifecycle.finishRerunPreSession(worktree: worktree.worktree, preSession: spawn)
        }
    }

    /// Detached tail of a manual re-run: wait, then close-on-success or
    /// notify-on-failure. Always releases the registry claim — this is a
    /// single linear function (no early returns, and none of the awaited
    /// calls below throw), so the final `preSessionRuns.end` at the bottom
    /// runs on every path.
    private func finishRerunPreSession(
        worktree: Worktree, preSession: PreSessionSpawn
    ) async {
        let outcome = await waitForPreSessionCompletion(preSession: preSession)
        // The marker must never outlive the wait, whatever the outcome.
        try? FileManager.default.removeItem(atPath: preSession.markerPath)

        switch outcome {
        case .completed(exitCode: 0):
            logger.info("preSession hook re-run completed for worktree \(worktree.id, privacy: .public)")
            await closePreSessionTerminal(worktree: worktree, preSession: preSession)
        case .completed(let exitCode):
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook failed (exit \(exitCode)) — its tab is left open with the output"
            )
        case .timedOut:
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook timed out after \(Int(preSessionTimeout))s"
            )
        case .paneKilled:
            // Not an error on a re-run: the user closed the tab, a legitimate
            // cancel. (On the create path this IS a notification, because
            // there the primary agent is about to start on an unprepared
            // tree — that concern doesn't apply here.)
            logger.info("preSession hook re-run pane closed early for worktree \(worktree.id, privacy: .public)")
        }

        await preSessionRuns.end(worktree.id)
    }
}
