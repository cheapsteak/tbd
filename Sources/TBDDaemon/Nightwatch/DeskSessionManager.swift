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

    // MARK: - Init

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        skillDir: String,
        subscriptions: StateSubscriptionManager? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.subscriptions = subscriptions
        self.skillDir = skillDir
        self.now = now
        self.deskWorktreeID = nil
    }

    // MARK: - Public API

    /// Idempotent: ensure a Watch Desk scratch space exists.
    /// Returns existing desk worktree if already created, otherwise creates one.
    /// On recovery, respawns a Claude terminal if one doesn't exist (H1 fix: desk dead after off→on cycle).
    /// - Parameter mode: The current nightwatch mode (daywatch or nightwatch)
    /// - Returns: The Worktree for the desk session
    public func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree {
        await gateAcquire()
        defer { gateRelease() }
        // Validate cached desk session: must be active AND have a live Claude terminal
        if let cachedID = deskWorktreeID,
           let existing = try await db.worktrees.get(id: cachedID),
           existing.status == .active {
            // Check if it has a live Claude terminal
            let terminals = try await db.terminals.list(worktreeID: existing.id)
            if terminals.first(where: { $0.label == TerminalLabel.claudeCode }) != nil {
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

            // Ensure the recovered desk has a live Claude terminal; respawn if missing
            let terminals = try await db.terminals.list(worktreeID: existing.id)
            if terminals.first(where: { $0.label == TerminalLabel.claudeCode }) == nil {
                logger.info("Recovered Watch Desk \(existing.id, privacy: .public) but no Claude terminal; respawning")
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

        // Spawn a Claude terminal configured for nightwatch operations
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

    /// Resolve the Watch Desk's *live* Claude terminal, newest first.
    ///
    /// `TerminalStore.list` orders by `createdAt` ascending, so the previous
    /// `terminals.first(where: { $0.label == .claudeCode })` deterministically returned
    /// the OLDEST Claude row — not a race, a guarantee. Desk terminal rows outlive their
    /// panes: a session that dies, or is killed out-of-band (the nightwatch judge handoff
    /// `kill-window`s its predecessor directly, so the daemon never removes the row),
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
    /// - Returns: The newest Claude terminal whose tmux window is still alive, or nil.
    private func liveClaudeTerminal(worktreeID: UUID, server: String) async throws -> Terminal? {
        let candidates = try await db.terminals.list(worktreeID: worktreeID)
            .filter { $0.label == TerminalLabel.claudeCode }
            // Secondary key on id: Swift's sort is not stable, and two rows can share a
            // createdAt, so without it the winner between same-instant rows is arbitrary.
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }

        for terminal in candidates {
            if await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID) {
                return terminal
            }
            logger.notice("""
                Skipping stale Watch Desk terminal \(terminal.id, privacy: .public): \
                window \(terminal.tmuxWindowID, privacy: .public) no longer exists
                """)
        }
        return nil
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

            guard let claudeTerminal = try await liveClaudeTerminal(
                worktreeID: worktreeID, server: worktree.tmuxServer
            ) else {
                logger.warning("No live Claude terminal in Watch Desk; skipping wrap-up prompt")
                return
            }

            // Paste the wrap-up prompt text
            try await tmux.pasteText(
                server: worktree.tmuxServer,
                paneID: claudeTerminal.tmuxPaneID,
                bytes: Data(NightwatchDeskPrompts.wrapUpPrompt.utf8)
            )

            // Send Enter to submit
            try await tmux.sendKey(
                server: worktree.tmuxServer,
                paneID: claudeTerminal.tmuxPaneID,
                key: "Enter"
            )

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

            guard let claudeTerminal = try await liveClaudeTerminal(
                worktreeID: worktreeID, server: worktree.tmuxServer
            ) else {
                // Deliberately does NOT stamp lastNudgeTime: a nudge that never reached a
                // pane must not start the 10-minute overlap cooldown, or one dead desk
                // would suppress the retry that recovers it.
                logger.warning("No live Claude terminal in Watch Desk; skipping nudge")
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
            if let instructionsPath = writeJudgeInstructions(deskPath: worktree.path, mode: mode) {
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

            // Paste the prompt text (matches handleTerminalSend pattern for reliability)
            try await tmux.pasteText(
                server: worktree.tmuxServer,
                paneID: claudeTerminal.tmuxPaneID,
                bytes: Data(prompt.utf8)
            )

            // Send Enter to submit
            try await tmux.sendKey(
                server: worktree.tmuxServer,
                paneID: claudeTerminal.tmuxPaneID,
                key: "Enter"
            )

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

    // MARK: - Private Helpers

    /// Write the mode-specific judge instructions into the desk worktree.
    ///
    /// Returns the absolute path on success, `nil` on any failure — callers treat
    /// `nil` as "fall back to the inline prompt" rather than proceeding with a
    /// pointer to a file that may not exist. Deliberately non-throwing: a desk
    /// that cannot write a file must still get nudged.
    private func writeJudgeInstructions(deskPath: String, mode: NightwatchMode) -> String? {
        let url = URL(fileURLWithPath: deskPath)
            .appendingPathComponent(NightwatchDeskPrompts.judgeInstructionsFileName)
        let body = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: skillDir)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            logger.warning("Failed to write judge instructions: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Spawn a Claude terminal in the desk worktree using lifecycle.spawnPrimaryTerminals.
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
