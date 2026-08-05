import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch.desk")

/// Protocol for dependency injection in testing. Allows mocking DeskSessionManager
/// for testing DaywatchRunner's desk-gated branches (ensure-on-start, nudge-on-tick-10, wrap-up-on-stop, etc).
public protocol DeskSessionManaging: Sendable {
    func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree
    func nudgeDeskSession(worktreeID: UUID, act: Bool) async
    func postShiftWrapUp(worktreeID: UUID) async
    func closeDeskSession() async
    func releaseJudgeLease(worktreeID: UUID) async
    func maintainJudgeLease(worktreeID: UUID) async
}

public extension DeskSessionManaging {
    func releaseJudgeLease(worktreeID: UUID) async {}
    func maintainJudgeLease(worktreeID: UUID) async {}
}

/// Manages the persistent "Watch Desk" scratch space for daywatch/nightwatch operations.
/// Idempotent creation: mode switches reuse the existing desk session.
/// Nudges the session when judgment items are queued (tick exit code 10).
public actor DeskSessionManager: DeskSessionManaging {
    // MARK: - Dependencies

    private let db: TBDDatabase
    private let lifecycle: WorktreeLifecycle
    private let tmux: TmuxManager
    /// Broadcasts worktree create/archive deltas so connected app clients update
    /// immediately (matching RPCRouter+ScratchHandlers) instead of waiting for a poll.
    private let subscriptions: StateSubscriptionManager?
    private let skillDir: String
    /// Date seam for the nudge-overlap guard — a compared timestamp, so per
    /// `Tests/CLAUDE.md` this is the `now:` shape, not an injected `Clock`.
    /// Without it the 10-minute window is unreachable in a test, which is why the
    /// guard went so long with no observable beyond "doesn't throw".
    private let now: @Sendable () -> Date
    /// The daemon's actuation record. The desk's pastes bypass the RPC router,
    /// so this rail writes its own rows.
    private let actuationLog: ActuationLog

    // MARK: - State

    // MARK: - Serialization gate
    //
    // Actors are reentrant across suspension points, so ensure/close each have
    // read→await→write windows on `deskWorktreeID` that can interleave (two
    // concurrent first-ensures double-creating a desk; a stale close archiving
    // a desk a newer ensure just made). This FIFO gate makes each public
    // mutating operation atomic with respect to the others.
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private func gateAcquire() async {
        if gateBusy {
            await withCheckedContinuation { gateWaiters.append($0) }
            // Resumed by gateRelease(); gateBusy intentionally stays true.
        } else {
            gateBusy = true
        }
    }

    private func gateRelease() {
        if gateWaiters.isEmpty {
            gateBusy = false
        } else {
            gateWaiters.removeFirst().resume()
        }
    }

    /// UUID of the current Watch Desk worktree; nil if none exists.
    /// Cleared when mode transitions to .off. Persists across mode switches between
    /// daywatch and nightwatch.
    private var deskWorktreeID: UUID?

    /// Timestamp of the last nudge; used to skip overlapping nudges (< 10 min apart).
    /// M2: nudge-overlap guard. Phase B upgrade: claim-file (queue/claims) single-driver enforcement.
    private var lastNudgeTime: Date?

    /// Mode carried by the last nudge that actually reached the session.
    ///
    /// The judge is told to read `JUDGE-INSTRUCTIONS.md` once rather than every
    /// tick, so *someone* has to notice when the body it memorized stops matching
    /// the body on disk. The desk is deliberately reused across daywatch ↔
    /// nightwatch without respawning (see `ensureDeskSession`), and the two bodies
    /// differ on exactly the thing that matters — whether an unattended
    /// `gh pr merge` is authorized. `nil` means nothing has been nudged yet, which
    /// is treated the same as changed: a judge with no reads is a judge that must read.
    ///
    /// Internal rather than private so tests can assert the transition; it is state
    /// the manager needs regardless.
    private(set) var lastNudgedMode: NightwatchMode?

    /// Deduplicates the fail-closed notification for one conflicting owner
    /// generation. A new generation is a new incident and notifies again.
    private var notifiedContentionGeneration: Int64?

    // MARK: - Init

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        skillDir: String,
        subscriptions: StateSubscriptionManager? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        actuationLog: ActuationLog
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.subscriptions = subscriptions
        self.skillDir = skillDir
        self.now = now
        self.actuationLog = actuationLog
        self.deskWorktreeID = nil
    }

    // MARK: - Public API

    /// Idempotent: ensure a Watch Desk scratch space exists.
    /// Returns existing desk worktree if already created, otherwise creates one.
    /// On recovery, respawns the configured primary agent if it has no live pane
    /// (H1 fix: desk dead after off→on cycle).
    /// - Parameter mode: The current nightwatch mode (daywatch or nightwatch)
    /// - Returns: The Worktree for the desk session
    public func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree {
        await gateAcquire()
        defer { gateRelease() }
        let preferredKind = try await preferredAgentKind()

        // Validate cached desk session: the row alone is not enough. Agent
        // processes can exit before their terminal row is removed, so require a
        // live pane owned by the currently configured primary agent.
        if let cachedID = deskWorktreeID,
           let existing = try await db.worktrees.get(id: cachedID),
           existing.status == .active {
            if try await liveAgentTerminal(
                worktreeID: existing.id,
                server: existing.tmuxServer,
                kind: preferredKind
            ) != nil {
                // Fast path: cached desk is alive and valid.
                // Mode switches (daywatch ↔ nightwatch) intentionally REUSE the existing desk and terminal.
                // The desk is NOT respawned on mode switch because every tick re-derives the mode and
                // rewrites JUDGE-INSTRUCTIONS.md to match. Since the judge is told to read that file once
                // rather than per tick, reuse-without-respawn is exactly the case where a memorized copy
                // can go stale — `nudgeDeskSession` compares against `lastNudgedMode` and flags the flip.
                // Initial frame is one-time; steady-state mode is driven per-tick.
                return existing
            }
        }

        // Cached entry was stale (archived or no terminal); clear it and fall through to recovery/create
        deskWorktreeID = nil

        // Query by displayName to detect existing desk worktrees (active only).
        // This recovery path excludes archived worktrees so off→on cycles don't
        // resurrect dead desk sessions. (survives daemon restart since displayName is stable).
        let activeWorktrees = try await db.worktrees.list(excludeArchived: true)
        if let existing = activeWorktrees.first(where: { $0.displayName == NightwatchDeskPrompts.deskDisplayName && $0.isScratch }) {
            deskWorktreeID = existing.id

            // Ensure the recovered desk has a live configured agent; respawn if
            // its row is missing OR its pane exited.
            if try await liveAgentTerminal(
                worktreeID: existing.id,
                server: existing.tmuxServer,
                kind: preferredKind
            ) == nil {
                logger.info("Recovered Watch Desk \(existing.id, privacy: .public) but no live \(preferredKind.rawValue, privacy: .public) terminal; respawning")
                do {
                    _ = try await spawnDeskTerminal(worktree: existing, mode: mode)
                } catch {
                    logger.warning("Failed to respawn terminal on recovery: \(error.localizedDescription, privacy: .public)")
                    // Best-effort; don't fail the recovery
                }
            }

            logger.info("Reusing existing Watch Desk session: \(existing.id, privacy: .public)")
            return existing
        }

        // Create a new scratch space
        let fm = FileManager.default
        let scratchDir = TBDConstants.scratchDir
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        // Allocate a unique directory name
        var name = "watch-desk"
        var deskPath = scratchDir.appendingPathComponent(name)
        var attempts = 0
        while true {
            let existsOnDisk = fm.fileExists(atPath: deskPath.path)
            let existsInDB = try await db.worktrees.findByPath(path: deskPath.path) != nil
            if !existsOnDisk && !existsInDB {
                break
            }
            name = "watch-desk-\(UUID().uuidString.prefix(8))"
            deskPath = scratchDir.appendingPathComponent(name)
            attempts += 1
            if attempts > 50 {
                throw WorktreeLifecycleError.createFailed("Could not allocate unique desk directory after 50 attempts")
            }
        }

        // Create the directory
        try fm.createDirectory(at: deskPath, withIntermediateDirectories: false)

        let tmuxServer = TmuxManager.serverName(forRepoPath: scratchDir.path)

        // Create DB row
        let wt: Worktree
        do {
            wt = try await db.worktrees.createScratch(
                name: name,
                displayName: NightwatchDeskPrompts.deskDisplayName,
                path: deskPath.path,
                tmuxServer: tmuxServer
            )
        } catch {
            try? fm.removeItem(at: deskPath)
            throw error
        }

        // Spawn the configured primary agent for nightwatch operations.
        do {
            _ = try await spawnDeskTerminal(worktree: wt, mode: mode)
        } catch {
            logger.warning("Failed to spawn desk terminal: \(error.localizedDescription, privacy: .public)")
            // Terminal spawn failure is best-effort; don't fail the worktree creation
        }

        // Cache the worktree ID
        deskWorktreeID = wt.id

        // Mirror handleScratchCreate: tell connected clients immediately.
        subscriptions?.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: wt.id, repoID: nil, name: wt.name, path: wt.path, status: wt.status)))

        logger.info("Created Watch Desk session: \(wt.id, privacy: .public) at \(wt.path, privacy: .public)")
        return wt
    }

    /// Resolve the Watch Desk's *live* configured agent terminal, newest first.
    ///
    /// `TerminalStore.list` orders by `createdAt` ascending, so the previous
    /// `terminals.first(where:)` deterministically returned the OLDEST row —
    /// not a race, a guarantee. Desk terminal rows outlive their
    /// panes: a session that dies, or was killed out-of-band by an older
    /// Nightwatch handoff that bypassed TBD's terminal-close path,
    /// leaves its row behind forever. The oldest row is therefore the one *most* likely
    /// to be dead, and every handoff inserted another corpse ahead of the live desk.
    ///
    /// Observed in production: one desk carried three `Claude Code` rows, the nudge aimed
    /// at the first, and the judge prompt was discarded every fifteen minutes for hours
    /// while ticks kept correctly reporting queued judgment.
    ///
    /// Two guards make that impossible. Prefer the NEWEST row, and confirm its tmux window
    /// still exists before sending. The liveness check is not redundant belt-and-braces:
    /// tmux recycles pane IDs per server — both dead rows in the incident above had been
    /// assigned `%1` — so a stale row can start resolving to a *live pane owned by an
    /// unrelated session*, which would then receive a pasted judge prompt plus Enter. That
    /// is issue #384, and picking the newest row alone would not prevent it.
    ///
    /// Hibernated/suspended rows are excluded even if their tmux window still
    /// exists: their pane contains a shell, not an agent, and pasting a judge
    /// prompt there would execute it as shell input.
    ///
    /// - Returns: The newest matching agent terminal whose tmux window is still alive, or nil.
    private func liveAgentTerminals(
        worktreeID: UUID,
        server: String,
        kind: TerminalKind
    ) async throws -> [Terminal] {
        let candidates = try await db.terminals.list(worktreeID: worktreeID)
            .filter {
                $0.suspendedAt == nil
                    && $0.hibernatedAt == nil
                    && terminal($0, matches: kind)
            }
            // Secondary key on id: Swift's sort is not stable, and two rows can share a
            // createdAt, so without it the winner between same-instant rows is arbitrary.
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }

        var live: [Terminal] = []
        for terminal in candidates {
            guard await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID) else {
                logger.notice("""
                    Skipping stale Watch Desk terminal \(terminal.id, privacy: .public): \
                    window \(terminal.tmuxWindowID, privacy: .public) no longer exists
                    """)
                continue
            }
            if tmux.verifiesPaneCurrentCommand {
                guard let command = try? await tmux.paneCurrentCommand(
                    server: server,
                    paneID: terminal.tmuxPaneID
                ), Self.agentCommand(command, matches: kind) else {
                    logger.notice("""
                        Skipping stale Watch Desk terminal \(terminal.id, privacy: .public): \
                        pane exists but no \(kind.rawValue, privacy: .public) process is running
                        """)
                    continue
                }
            }
            live.append(terminal)
        }
        return live
    }

    private func liveAgentTerminal(
        worktreeID: UUID,
        server: String,
        kind: TerminalKind
    ) async throws -> Terminal? {
        try await liveAgentTerminals(
            worktreeID: worktreeID, server: server, kind: kind).first
    }

    private func liveJudgeCandidates(worktree: Worktree) async throws -> [Terminal] {
        let claude = try await liveAgentTerminals(
            worktreeID: worktree.id, server: worktree.tmuxServer, kind: .claude)
        let codex = try await liveAgentTerminals(
            worktreeID: worktree.id, server: worktree.tmuxServer, kind: .codex)
        return (claude + codex).sorted {
            ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString)
        }
    }

    /// Resolve the sole mutable judge. Existing valid ownership wins even when
    /// observers are present. With no lease, multiple candidates are ambiguous
    /// and fail closed rather than selecting by recency.
    private func leasedJudgeTerminal(
        worktree: Worktree
    ) async throws -> (Terminal, WatchDeskLease, String)? {
        var candidates = try await liveJudgeCandidates(worktree: worktree)
        let now = now()

        if let lease = try await db.watchDeskLeases.status(worktreeID: worktree.id),
           lease.isValid(at: now) {
            if let owner = candidates.first(where: { $0.id == lease.terminalID }) {
                let renewed = try await db.watchDeskLeases.renew(
                    worktreeID: worktree.id, terminalID: owner.id,
                    token: lease.token, generation: lease.generation, now: now)
                let credentialFile = try WatchDeskLeaseCredentialFile.ensure(WatchDeskLeaseCredential(
                    worktreeID: renewed.worktreeID, terminalID: renewed.terminalID,
                    token: renewed.token, generation: renewed.generation))
                notifiedContentionGeneration = nil
                return (owner, renewed, credentialFile)
            }
            logger.warning("Revoking Watch Desk judge lease generation \(lease.generation): owner pane is gone")
            try await db.watchDeskLeases.revoke(worktreeID: worktree.id)
            subscriptions?.broadcast(delta: .watchDeskRolesChanged(
                WorktreeIDDelta(worktreeID: worktree.id)))
            candidates = try await liveJudgeCandidates(worktree: worktree)
        }

        guard candidates.count <= 1 else {
            // Generation 0 denotes pre-lease ambiguity. Once a real lease has
            // existed, its persisted generation makes subsequent incidents distinct.
            let generation = try await db.watchDeskLeases.status(worktreeID: worktree.id)?.generation ?? 0
            if notifiedContentionGeneration != generation {
                let candidatesList = candidates.map(\.id.uuidString).joined(separator: ", ")
                let notification = try await db.notifications.create(
                    worktreeID: worktree.id,
                    type: .error,
                    message: "Watch Desk has multiple live judge candidates (\(candidatesList)). Mutable Nightwatch actions are paused. Recover with `tbd nightwatch lease acquire --worktree \(worktree.id.uuidString) --terminal <chosen-terminal-id>`."
                )
                subscriptions?.broadcast(delta: .notificationReceived(NotificationDelta(
                    notificationID: notification.id,
                    worktreeID: notification.worktreeID,
                    type: notification.type,
                    message: notification.message,
                    terminalID: notification.terminalID,
                    activate: false
                )))
                notifiedContentionGeneration = generation
            }
            logger.error("Watch Desk judge contention: \(candidates.count) live agent candidates; no nudge sent")
            return nil
        }
        guard let candidate = candidates.first else { return nil }
        let lease = try await db.watchDeskLeases.acquire(
            worktreeID: worktree.id, terminalID: candidate.id, now: now)
        let credentialFile: String
        do {
            credentialFile = try WatchDeskLeaseCredentialFile.ensure(WatchDeskLeaseCredential(
                worktreeID: lease.worktreeID, terminalID: lease.terminalID,
                token: lease.token, generation: lease.generation))
        } catch {
            try? await db.watchDeskLeases.revoke(worktreeID: worktree.id)
            throw error
        }
        subscriptions?.broadcast(delta: .watchDeskRolesChanged(
            WorktreeIDDelta(worktreeID: worktree.id)))
        notifiedContentionGeneration = nil
        return (candidate, lease, credentialFile)
    }

    static func agentCommand(_ command: String, matches kind: TerminalKind) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .claude:
            return ClaudeStateDetector.isClaudeProcess(trimmed)
                || URL(fileURLWithPath: trimmed).lastPathComponent == "claude"
        case .codex:
            return URL(fileURLWithPath: trimmed).lastPathComponent == "codex"
        case .shell:
            return false
        }
    }

    private func preferredAgentKind() async throws -> TerminalKind {
        try await db.config.get().primaryAgentPreference.terminalKind
    }

    private func terminal(_ terminal: Terminal, matches kind: TerminalKind) -> Bool {
        switch kind {
        case .codex:
            return terminal.isCodexTerminal
        case .claude:
            return !terminal.isCodexTerminal
                && (terminal.kind == .claude || terminal.label == TerminalLabel.claudeCode)
        case .shell:
            return false
        }
    }

    /// Post a shift wrap-up prompt to the desk session and fire a completion notification.
    /// Called when daywatch/nightwatch mode is turned OFF to gracefully end the shift.
    /// Sends the wrap-up prompt via tmux (non-destructive), fires a notification, and leaves
    /// the desk active for the user to review/hibernate manually.
    /// - Parameter worktreeID: The Watch Desk worktree ID
    public func postShiftWrapUp(worktreeID: UUID) async {
        await gateAcquire()
        defer { gateRelease() }

        do {
            // Worktree first: resolving a live terminal needs the tmux server to query.
            guard let worktree = try await db.worktrees.get(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found: \(worktreeID, privacy: .public)")
                return
            }

            guard let (agentTerminal, _, _) = try await leasedJudgeTerminal(
                worktree: worktree
            ) else {
                logger.warning("No uniquely owned live terminal in Watch Desk; skipping wrap-up prompt")
                return
            }

            // Request row before the paste; the paste and the Enter are one
            // send. Fail-closed: an unrecordable wrap-up is not posted — and
            // says so, like every other refusal on this path.
            let actuationID: String
            do {
                actuationID = try await recordDeskSend(
                    worktreeID: worktreeID,
                    terminalID: agentTerminal.id,
                    message: NightwatchDeskPrompts.wrapUpPrompt)
            } catch {
                logger.warning("Skipping Watch Desk wrap-up prompt: \(error, privacy: .public)")
                return
            }

            do {
                // Paste the wrap-up prompt text
                try await tmux.pasteText(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    bytes: Data(NightwatchDeskPrompts.wrapUpPrompt.utf8)
                )

                // Send Enter to submit
                try await tmux.sendKey(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    key: "Enter"
                )
            } catch {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed, error: "\(error)")
                throw error
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

            // Fire a completion notification
            _ = try await db.notifications.create(
                worktreeID: worktreeID,
                type: .taskComplete,
                message: "Daywatch ended — shift summary posted to the Watch Desk."
            )

            logger.info("Posted shift wrap-up prompt to Watch Desk: \(worktreeID, privacy: .public)")
        } catch {
            logger.error("Failed to post shift wrap-up: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Nudge the desk session to process queued judgment items.
    /// Uses pasteText + sendKey pattern (mirrors handleTerminalSend).
    /// M2: nudge-overlap guard — skips if last nudge was < 10 min ago (prevent overlapping judge runs).
    /// Phase B upgrade: implement claim-file (queue/claims) single-driver enforcement to replace time-based guard.
    /// - Parameters:
    ///   - worktreeID: The Watch Desk worktree ID
    ///   - act: true for nightwatch (auto-act), false for daywatch (dry-run/batch only)
    public func nudgeDeskSession(worktreeID: UUID, act: Bool) async {
        // Same FIFO gate as ensure/close: the overlap-guard's check-then-act
        // (lastNudgeTime read → awaits → write) is not atomic under actor
        // reentrancy without it.
        await gateAcquire()
        defer { gateRelease() }
        // M2: Skip nudge if previous nudge was < 10 min ago (prevent overlapping judge runs)
        if let last = lastNudgeTime {
            let elapsed = now().timeIntervalSince(last)
            if elapsed < 10 * 60 {
                logger.debug("Skipping nudge: last nudge was \(Int(elapsed))s ago (< 10 min)")
                return
            }
        }

        let mode: NightwatchMode = act ? .nightwatch : .daywatch

        do {
            // Worktree first: resolving a live terminal needs the tmux server to query.
            guard let worktree = try await db.worktrees.get(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found: \(worktreeID, privacy: .public)")
                return
            }

            var preferredKind = try await preferredAgentKind()
            var judge = try await leasedJudgeTerminal(worktree: worktree)
            if judge == nil,
               try await liveJudgeCandidates(worktree: worktree).isEmpty {
                // A terminal row can survive a process/pane exit. Recover in the
                // nudge path itself so one failed launch does not turn into a
                // silent all-night outage waiting for a mode toggle or daemon
                // restart. spawnPrimaryTerminals uses the same configured
                // primary-agent preference and production launch path as normal
                // worktrees.
                logger.notice("No live \(preferredKind.rawValue, privacy: .public) Watch Desk terminal; retrying spawn before nudge")
                do {
                    try await spawnDeskTerminal(worktree: worktree, mode: mode)
                    // Re-read in case the preference changed while spawning.
                    preferredKind = try await preferredAgentKind()
                    judge = try await leasedJudgeTerminal(worktree: worktree)
                } catch {
                    logger.warning("Failed to recover Watch Desk terminal before nudge: \(error.localizedDescription, privacy: .public)")
                }
            }

            guard let (agentTerminal, lease, credentialFile) = judge else {
                // Deliberately does NOT stamp lastNudgeTime: a nudge that never
                // reached a pane must not start the 10-minute overlap cooldown,
                // or one dead desk would suppress the next recovery attempt.
                logger.warning("No live \(preferredKind.rawValue, privacy: .public) terminal in Watch Desk after retry; skipping nudge")
                return
            }

            // The ~5 KB instructions go to a file; only the one-line pointer goes
            // into the session. Rewritten every tick rather than once at spawn
            // because it is mode-specific and a local write costs nothing — that
            // also makes the file self-healing across daemon restarts, mode
            // switches, and a desk whose directory was cleaned out under it.
            //
            // Fallback, deliberately: if the write fails there is no file to point
            // at, so we paste the full prompt exactly as before. A judge holding
            // stale instructions is a bad night; a judge holding a pointer to
            // nothing is a silent one.
            let prompt: String
            if let instructionsPath = writeJudgeInstructions(
                deskPath: worktree.path, mode: mode, lease: lease,
                credentialFile: credentialFile) {
                // A mode flip rewrites the file under a judge that was told to read
                // it once. Nothing on the judge's side can see that happen, so the
                // daemon — the only party that knows both the old and new mode —
                // has to say so. First nudge (nil) counts as changed: a judge that
                // has read nothing must read.
                prompt = NightwatchDeskPrompts.judgeNudge(
                    mode: mode,
                    instructionsPath: instructionsPath,
                    instructionsChanged: lastNudgedMode != mode
                )
            } else {
                logger.warning("Could not write judge instructions to \(worktree.path, privacy: .public); falling back to the inline prompt")
                prompt = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: skillDir)
            }

            // Request row before the paste; the paste and the Enter are one
            // send. Fail-closed: an unrecordable nudge is not sent, and
            // `lastNudgeTime` below is left alone so the next tick retries.
            let actuationID: String
            do {
                actuationID = try await recordDeskSend(
                    worktreeID: worktreeID,
                    terminalID: agentTerminal.id,
                    message: prompt)
            } catch {
                logger.warning("Skipping Watch Desk nudge: \(error, privacy: .public)")
                return
            }

            do {
                // Paste the prompt text (matches handleTerminalSend pattern for reliability)
                try await tmux.pasteText(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    bytes: Data(prompt.utf8)
                )

                // Send Enter to submit
                try await tmux.sendKey(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    key: "Enter"
                )
            } catch {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed, error: "\(error)")
                throw error
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

            // Record nudge time for overlap guard. `lastNudgedMode` is set only
            // here, after the paste actually went out — a nudge that failed to
            // reach the session must not count as "the judge has seen this mode",
            // or the next tick would tell it nothing changed when everything did.
            lastNudgeTime = now()
            lastNudgedMode = mode

            logger.debug("Nudged Watch Desk session: act=\(act, privacy: .public)")
        } catch {
            logger.error("Failed to nudge desk session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One request row for a desk paste, carrying the payload verbatim.
    /// Returns the minted id; throws when the record is unwritable even after
    /// the writer's reopen-retry, in which case the caller must not paste.
    private func recordDeskSend(
        worktreeID: UUID, terminalID: UUID, message: String
    ) async throws -> String {
        var row = ActuationRow(
            actor: .daemon(rail: ActuationRail.nightwatchDesk), kind: .send)
        row.target = .local(worktree: worktreeID, terminal: terminalID)
        row.message = message
        row.submit = true
        return try await actuationLog.appendRequest(row)
    }

    /// Gracefully close the desk session (archive it).
    /// Direct archive (vs. promote-and-close) is intentional: desk sessions are transient scratch spaces
    /// scoped to a single mode run. Archiving preserves the session history on disk while removing it
    /// from active management. The next mode change (off→on) will detect the archived desk and exclude it
    /// from recovery (ensuring a fresh session if desired). Promotion not applicable here since desk is
    /// never user-facing as a persistent worktree.
    public func closeDeskSession() async {
        await gateAcquire()
        defer { gateRelease() }
        guard let worktreeID = deskWorktreeID else { return }

        do {
            guard let wt = try await db.worktrees.get(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found during close: \(worktreeID, privacy: .public)")
                deskWorktreeID = nil
                return
            }

            // Kill tmux windows
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for t in terminals {
                try? await tmux.killWindow(server: wt.tmuxServer, windowID: t.tmuxWindowID)
            }

            // Delete terminal rows
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.tabs.deleteForWorktree(worktreeID: wt.id)

            // Archive the worktree (preserve the folder on disk)
            try await db.worktrees.archive(id: wt.id)

            // Mirror handleScratchArchive: tell connected clients immediately.
            subscriptions?.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: wt.id)))

            logger.info("Archived Watch Desk session: \(wt.id, privacy: .public)")
        } catch {
            logger.error("Failed to close desk session: \(error.localizedDescription, privacy: .public)")
        }

        deskWorktreeID = nil
    }

    public func releaseJudgeLease(worktreeID: UUID) async {
        do {
            guard let lease = try await db.watchDeskLeases.status(worktreeID: worktreeID) else { return }
            try await db.watchDeskLeases.release(
                worktreeID: worktreeID, terminalID: lease.terminalID,
                token: lease.token, generation: lease.generation)
            WatchDeskLeaseCredentialFile.remove(terminalID: lease.terminalID)
            notifiedContentionGeneration = nil
            subscriptions?.broadcast(delta: .watchDeskRolesChanged(
                WorktreeIDDelta(worktreeID: worktreeID)))
            logger.info("Released Watch Desk judge lease generation \(lease.generation)")
        } catch {
            logger.error("Failed to release Watch Desk judge lease: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fifteen-minute scheduler heartbeat. It renews/reconciles ownership
    /// without sending a model prompt, so the lease cannot expire behind the
    /// ten-minute nudge overlap guard during an otherwise quiet shift.
    public func maintainJudgeLease(worktreeID: UUID) async {
        await gateAcquire()
        defer { gateRelease() }
        do {
            guard let worktree = try await db.worktrees.get(id: worktreeID) else { return }
            _ = try await leasedJudgeTerminal(worktree: worktree)
        } catch {
            logger.error("Failed to maintain Watch Desk judge lease: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private Helpers

    /// Write the mode-specific judge instructions into the desk worktree.
    ///
    /// Returns the absolute path on success, `nil` on any failure — callers treat
    /// `nil` as "fall back to the inline prompt" rather than proceeding with a
    /// pointer to a file that may not exist. Deliberately non-throwing: a desk
    /// that cannot write a file must still get nudged.
    private func writeJudgeInstructions(
        deskPath: String, mode: NightwatchMode, lease: WatchDeskLease? = nil,
        credentialFile: String? = nil
    ) -> String? {
        let url = URL(fileURLWithPath: deskPath)
            .appendingPathComponent(NightwatchDeskPrompts.judgeInstructionsFileName)
        var body = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: skillDir)
        if let lease, let credentialFile {
            body += """


            ## Exclusive judge lease (mandatory)

            You are the sole mutable judge only while this lease validates:
            - worktree: `\(lease.worktreeID.uuidString)`
            - terminal: `\(lease.terminalID.uuidString)`
            - generation: `\(lease.generation)`
            - capability file: `\(credentialFile)`

            Immediately before every merge/enqueue, infrastructure apply, archive,
            wake/nudge, or worker spawn, renew the lease. Renewal also validates
            the exact terminal, token, generation, and unexpired authority:

            `tbd nightwatch lease renew --credential-file \(credentialFile)`

            If renewal fails, stop mutating. Read-only inspection and reporting remain allowed.
            """
        }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            logger.warning("Failed to write judge instructions: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Spawn the configured primary agent in the desk worktree using
    /// lifecycle.spawnPrimaryTerminals.
    /// This reuses the production spawn path which handles trust seeding, overlay injection, etc.
    /// Note: Model selection (daywatch=Sonnet, nightwatch=Opus) requires per-profile configuration.
    /// The resolved profile's model is what gets used; mode affects behavior (conservative vs. free-acting),
    /// not the LLM model directly (that's a user's profile choice).
    private func spawnDeskTerminal(worktree: Worktree, mode: NightwatchMode) async throws {
        // Get initial prompt for mode (includes absolute skillDir paths and field learnings)
        let initialPrompt = NightwatchDeskPrompts.initialPrompt(mode: mode, skillDir: skillDir)

        // A new session has read nothing, so nothing it could have memorized is
        // still valid. `lastNudgedMode` is keyed on the MODE, not on which session
        // is running, so without this reset a crash-respawn with the mode
        // unchanged computes `lastNudgedMode != mode` == false and tells a
        // brand-new judge "you already read the instructions — don't re-read".
        // It hasn't. It doesn't. (Caught in review of PR #551.)
        //
        // `lastNudgeTime` goes with it for the same reason: a rate-limit window
        // opened by a session that no longer exists should not silence the first
        // tick of its replacement. Both are per-session facts that were living on
        // the actor, and this is the one chokepoint both spawn paths — fresh
        // create and crash recovery — pass through.
        //
        // Reset unconditionally, before the spawn can throw: over-signalling
        // costs one extra file Read, under-signalling costs a judge running an
        // unattended shift on instructions it never opened.
        lastNudgedMode = nil
        lastNudgeTime = nil

        // Lay the instructions down before the session exists, so a judge that
        // reads them on its own initiative — before its first tick ever fires —
        // finds them there. Best-effort: the nudge path rewrites this every tick
        // and falls back to the inline prompt if it can't.
        writeJudgeInstructions(deskPath: worktree.path, mode: mode).map { path in
            logger.debug("Wrote judge instructions to \(path, privacy: .public)")
        }

        // Use production spawn path which handles trust, overlay, and all lifecycle concerns
        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: worktree,
            repo: nil,
            skipClaude: false,
            initialPrompt: initialPrompt,
            preSessionTerminalID: nil
        )
        // Model follows the profile spawnPrimaryTerminals resolves internally —
        // resolving here too would just double the keychain-backed lookup.
        logger.info("Spawned desk terminal in \(worktree.id, privacy: .public)")
    }

}
