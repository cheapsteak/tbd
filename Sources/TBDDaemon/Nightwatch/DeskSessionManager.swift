import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch.desk")

/// Protocol for dependency injection in testing. Allows mocking DeskSessionManager
/// for testing DaywatchRunner's desk-gated branches (ensure-on-start, nudge-on-tick-10, close-on-stop, etc).
public protocol DeskSessionManaging: Sendable {
    func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree
    func nudgeDeskSession(worktreeID: UUID, act: Bool) async
    func closeDeskSession() async
    func wrapUpDeskSession(pollIntervalSeconds: TimeInterval, startupWindowSeconds: TimeInterval, settleDelaySeconds: TimeInterval, maxWaitSeconds: TimeInterval) async
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
    private let hibernationCoordinator: HibernationCoordinator?

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

    /// Monotonically-incrementing epoch to track desk reactivations.
    /// MEDIUM 2: prevents uncancellable wrap-up from parking a just-reactivated desk.
    /// When a wrap-up is scheduled, it captures the current epoch. If the desk is
    /// reactivated (ensureDeskSession reuses it), the epoch bumps. The wrap-up's
    /// delayed park step checks if the epoch changed and no-ops if it did.
    private var deskWorktreeEpoch: Int = 0

    /// Timestamp of the last nudge; used to skip overlapping nudges (< 10 min apart).
    /// M2: nudge-overlap guard. Phase B upgrade: claim-file (queue/claims) single-driver enforcement.
    private var lastNudgeTime: Date?

    // MARK: - Init

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        skillDir: String,
        subscriptions: StateSubscriptionManager? = nil,
        hibernationCoordinator: HibernationCoordinator? = nil
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.subscriptions = subscriptions
        self.skillDir = skillDir
        self.hibernationCoordinator = hibernationCoordinator
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
                // The desk is NOT respawned on mode switch because the per-tick judgePrompt (via nudgeDeskSession)
                // carries the current mode/act flag each cycle. Initial frame is one-time; steady-state mode is driven per-tick.
                // MEDIUM 2: Bump epoch to supersede any pending wrap-up task.
                deskWorktreeEpoch += 1
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

            // Check recovered desk terminals: if parked/hibernated, wake them; otherwise respawn if missing
            let terminals = try await db.terminals.list(worktreeID: existing.id)
            if let claudeTerminal = terminals.first(where: { $0.label == TerminalLabel.claudeCode }) {
                // Terminal exists; check if it's parked (hibernated)
                var shouldRespawn = false
                if claudeTerminal.isHibernated, let coordinator = hibernationCoordinator {
                    logger.info("Recovered Watch Desk \(existing.id, privacy: .public) with parked terminal; waking...")
                    let wakeResult = await coordinator.wake(terminalID: claudeTerminal.id)
                    switch wakeResult {
                    case .ok:
                        logger.info("Successfully woke parked desk terminal \(claudeTerminal.id, privacy: .public)")
                    case .notHibernated:
                        logger.debug("Desk terminal already awake: \(claudeTerminal.id, privacy: .public)")
                    case .inFlight:
                        // Another wake is in progress; don't spawn duplicate, just wait for that one to complete
                        logger.info("Wake already in flight for desk terminal \(claudeTerminal.id, privacy: .public); skipping respawn")
                    default:
                        logger.warning("Failed to wake parked desk terminal: \(String(describing: wakeResult))")
                        shouldRespawn = true
                    }
                }

                // If wake failed, respawn instead
                if shouldRespawn {
                    logger.info("Wake failed for desk terminal; respawning new terminal")
                    do {
                        _ = try await spawnDeskTerminal(worktree: existing, mode: mode)
                    } catch {
                        logger.warning("Failed to respawn terminal after failed wake: \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Terminal exists and is live (or wake succeeded or respawn attempted); use worktree as-is
            } else {
                // No Claude terminal found; respawn one
                logger.info("Recovered Watch Desk \(existing.id, privacy: .public) but no Claude terminal; respawning")
                do {
                    _ = try await spawnDeskTerminal(worktree: existing, mode: mode)
                } catch {
                    logger.warning("Failed to respawn terminal on recovery: \(error.localizedDescription, privacy: .public)")
                    // Best-effort; don't fail the recovery
                }
            }

            logger.info("Reusing existing Watch Desk session: \(existing.id, privacy: .public)")
            // MEDIUM 2: Bump epoch to supersede any pending wrap-up task.
            deskWorktreeEpoch += 1
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

    /// Gracefully end the shift: send wrap-up prompt, wait for agent to START and FINISH, then park the desk.
    /// Called when daywatch/nightwatch mode turns OFF. Preserves the desk worktree and transcript
    /// for reuse on the next ON cycle (off→park→on round-trip keeps the same desk).
    /// Two-phase design: (A) wait for agent to START working (activityState → .working), bounded by
    /// startupWindow to absorb async hook latency; (B) wait for agent to FINISH (activityState → idle),
    /// bounded by maxWait. This avoids both the instant-park-on-stale-idle race and the fixed-timer race.
    /// Does NOT delete the worktree (unlike closeDeskSession).
    /// - Parameter pollIntervalSeconds: How often to check terminal activity state (default ~2s)
    /// - Parameter startupWindowSeconds: Max time to wait for agent to START (absorb hook latency; ~15s default)
    /// - Parameter settleDelaySeconds: Min delay if agent never starts, before proceeding to phase B (~10s default)
    /// - Parameter maxWaitSeconds: Max time in phase B to wait for idle before giving up (default ~3min)
    public func wrapUpDeskSession(
        pollIntervalSeconds: TimeInterval = 2,
        startupWindowSeconds: TimeInterval = 15,
        settleDelaySeconds: TimeInterval = 10,
        maxWaitSeconds: TimeInterval = 180
    ) async {
        var terminalIDs: [UUID] = []
        var claudeTerminalID: UUID? = nil
        var worktreeID: UUID? = nil
        var capturedEpoch: Int = 0

        // Step 1: Hold gate, grab worktree/terminals, send prompt, then release gate
        await gateAcquire()
        do {
            guard let deskID = deskWorktreeID else {
                gateRelease()
                logger.info("No active desk session to wrap up")
                return
            }

            guard let wt = try await db.worktrees.get(id: deskID) else {
                gateRelease()
                logger.warning("Watch Desk worktree not found during wrap-up: \(deskID, privacy: .public)")
                deskWorktreeID = nil
                return
            }

            // Get terminals and send prompt (while holding gate)
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            guard let claudeTerminal = terminals.first(where: { $0.label == TerminalLabel.claudeCode }) else {
                gateRelease()
                logger.warning("No Claude terminal found in Watch Desk during wrap-up; skipping prompt")
                return
            }

            // Send wrap-up prompt
            let wrapUpPrompt = NightwatchDeskPrompts.wrapUpPrompt()
            do {
                try await tmux.pasteText(
                    server: wt.tmuxServer,
                    paneID: claudeTerminal.tmuxPaneID,
                    bytes: Data(wrapUpPrompt.utf8)
                )
                try await tmux.sendKey(
                    server: wt.tmuxServer,
                    paneID: claudeTerminal.tmuxPaneID,
                    key: "Enter"
                )
                logger.info("Sent wrap-up prompt to Watch Desk session: \(wt.id, privacy: .public)")
            } catch {
                logger.warning("Failed to send wrap-up prompt to desk: \(error.localizedDescription, privacy: .public)")
            }

            // Capture terminal IDs, epoch, and worktree for later hibernation
            terminalIDs = terminals.map { $0.id }
            claudeTerminalID = claudeTerminal.id
            worktreeID = wt.id
            capturedEpoch = deskWorktreeEpoch

            // Release gate BEFORE polling (don't block ON→ during the wait)
            gateRelease()
        } catch {
            gateRelease()
            logger.error("Failed to send wrap-up prompt: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Step 2A: Wait for agent to START working (absorb async UserPromptSubmit hook latency)
        // The terminal starts at .idle; we need to observe it flip to .working/.waitingForUser
        // before proceeding to phase B. This prevents the race: "stale idle at t≈0 → park instantly".
        let startupStart = Date()
        var agentStartedWorking = false

        while Date().timeIntervalSince(startupStart) < startupWindowSeconds {
            // Check if epoch changed — abort entire wrap-up
            if capturedEpoch != self.deskWorktreeEpoch {
                logger.info("Wrap-up startup aborted: epoch changed (desk reactivated)")
                return
            }

            do {
                if let claudeID = claudeTerminalID,
                   let terminal = try await db.terminals.get(id: claudeID) {
                    // Flip to .working or .waitingForUser means agent picked up the prompt
                    if terminal.activityState == .working || terminal.activityState == .waitingForUser {
                        agentStartedWorking = true
                        logger.info("Agent started working; proceeding to phase B (wait for idle)")
                        break
                    }
                }
            } catch {
                logger.warning("Failed to poll terminal state in phase A: \(error.localizedDescription, privacy: .public)")
            }

            try? await Task.sleep(for: .seconds(pollIntervalSeconds))
        }

        // If agent never started working within startup window, apply minimum settle delay
        // before phase B. Don't proceed instantly (that would still be a race).
        if !agentStartedWorking {
            logger.info("Agent did not start working within startup window; applying settle delay before phase B")
            try? await Task.sleep(for: .seconds(settleDelaySeconds))
        }

        // Step 2B: Wait for agent to FINISH (return to idle state)
        // Poll until terminal.activityState becomes idle (not .working/.waitingForUser).
        let idleStart = Date()
        var idleObserved = false

        while Date().timeIntervalSince(idleStart) < maxWaitSeconds {
            // Check if epoch changed (desk was reactivated) — abort wait
            if capturedEpoch != self.deskWorktreeEpoch {
                logger.info("Wrap-up phase B aborted: epoch changed (desk reactivated)")
                return
            }

            // Poll terminal activity state
            do {
                if let claudeID = claudeTerminalID,
                   let terminal = try await db.terminals.get(id: claudeID) {
                    // Check if idle: not .working and not .waitingForUser
                    if terminal.activityState != .working && terminal.activityState != .waitingForUser {
                        idleObserved = true
                        logger.info("Desk terminal idle, proceeding to park (state: \(String(describing: terminal.activityState)))")
                        break
                    }
                }
            } catch {
                logger.warning("Failed to poll terminal state in phase B: \(error.localizedDescription, privacy: .public)")
            }

            // Sleep before next poll
            try? await Task.sleep(for: .seconds(pollIntervalSeconds))
        }

        if !idleObserved {
            logger.warning("Wrap-up phase B timeout: desk terminal did not go idle within \(Int(maxWaitSeconds))s; leaving desk running (protect against mid-write park)")
            return
        }

        // Step 3: Re-acquire gate and park terminals via HibernationCoordinator
        await gateAcquire()
        defer { gateRelease() }

        // Check if epoch changed during the idle wait (final guard)
        if capturedEpoch != self.deskWorktreeEpoch {
            logger.info("Wrap-up superseded: epoch changed during idle wait; skipping park")
            return
        }

        guard let coordinator = hibernationCoordinator else {
            logger.warning("HibernationCoordinator not available; cannot park desk terminals")
            return
        }

        // Use real hibernation path: calls manualHibernate which does polite exit, tmux respawn, etc.
        // Track ALL terminals: only clear deskWorktreeID if ALL successfully hibernated
        var allParked = true
        for terminalID in terminalIDs {
            let result = await coordinator.manualHibernate(terminalID: terminalID)
            switch result {
            case .ok:
                logger.info("Hibernated desk terminal \(terminalID, privacy: .public) via coordinator")
            case .alreadyHibernated:
                logger.debug("Desk terminal already hibernated: \(terminalID, privacy: .public)")
            default:
                logger.warning("Failed to park desk terminal \(terminalID, privacy: .public): \(String(describing: result)); park incomplete, will retry on next cycle")
                allParked = false
                // Continue (don't break early) so we attempt all terminals
            }
        }

        // Only mark parked if ALL terminals successfully hibernated
        if allParked, let wid = worktreeID {
            deskWorktreeID = nil
            logger.info("Wrapped up Watch Desk session: \(wid, privacy: .public); all terminals parked for reuse on next ON cycle")
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
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 10 * 60 {
                logger.debug("Skipping nudge: last nudge was \(Int(elapsed))s ago (< 10 min)")
                return
            }
        }

        let mode: NightwatchMode = act ? .nightwatch : .daywatch
        let prompt = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: skillDir)

        do {
            let terminals = try await db.terminals.list(worktreeID: worktreeID)
            guard let claudeTerminal = terminals.first(where: { $0.label == TerminalLabel.claudeCode }) else {
                logger.warning("No Claude terminal found in Watch Desk; skipping nudge")
                return
            }

            guard let worktree = try await db.worktrees.get(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found: \(worktreeID, privacy: .public)")
                return
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

            // Record nudge time for overlap guard
            lastNudgeTime = Date()

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

    /// Spawn a Claude terminal in the desk worktree using lifecycle.spawnPrimaryTerminals.
    /// This reuses the production spawn path which handles trust seeding, overlay injection, etc.
    /// Note: Model selection (daywatch=Sonnet, nightwatch=Opus) requires per-profile configuration.
    /// The resolved profile's model is what gets used; mode affects behavior (conservative vs. free-acting),
    /// not the LLM model directly (that's a user's profile choice).
    private func spawnDeskTerminal(worktree: Worktree, mode: NightwatchMode) async throws {
        // Get initial prompt for mode (includes absolute skillDir paths and field learnings)
        let initialPrompt = NightwatchDeskPrompts.initialPrompt(mode: mode, skillDir: skillDir)

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
