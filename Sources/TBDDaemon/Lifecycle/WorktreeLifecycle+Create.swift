import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeLifecycle")
private let timingLogger = Logger(subsystem: "com.tbd.daemon", category: "worktreeTiming")

/// Result of `completeCreateWorktree`. The pre-session path defers the
/// primary terminal spawn to a background task so the caller's serializer
/// lane isn't blocked for the duration of the hook (e.g. an `npm install`).
public enum WorktreeCreateCompletion: Sendable {
    /// All terminals were spawned inline; the worktree is `.active` and the
    /// caller should broadcast `.worktreeCreated` (today's behavior).
    case ready
    /// A blocking `preSession` hook terminal was spawned. The lifecycle has
    /// already broadcast `.worktreeCreated` + `.terminalCreated`; `phase3`
    /// awaits the hook, spawns the primary terminals, and flips the worktree
    /// to `.active`. The worktree stays `.creating` until it finishes.
    case preSessionPending(phase3: Task<Void, Never>)
}

/// Carries an archived conversation onto a freshly created worktree.
///
/// Deliberately carries no prompt: a carryover spawn opens idle at the
/// composer, exactly like an ordinary resume. An earlier revision passed a
/// "you have been moved" context prompt as the spawn's trailing argument,
/// which Claude answered immediately — an unwanted turn on every revive.
/// Provenance lives solely in `notesSeed`, which seeds the Notes tab.
public struct ConversationCarryover: Sendable {
    let sourceSessionID: String
    let notesSeed: String

    init(sourceSessionID: String, notesSeed: String) {
        self.sourceSessionID = sourceSessionID
        self.notesSeed = notesSeed
    }
}

extension WorktreeLifecycle {
    // MARK: - Create

    /// Creates a new worktree for the given repository (synchronous, blocking).
    ///
    /// This is the legacy all-in-one method. Prefer `beginCreateWorktree` +
    /// `completeCreateWorktree` for non-blocking creation.
    public func createWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false, initialPrompt: String? = nil, cols: Int? = nil, rows: Int? = nil, parentWorktreeID: UUID? = nil, siblingOfWorktreeID: UUID? = nil, callerWorktreeID: UUID? = nil, suppressAutoParent: Bool = false, useExistingBranch: Bool = false, prNumber: Int? = nil, checkoutPRHead: Bool = false, primaryAgentPreference: PrimaryAgentPreference? = nil, claudeSettingsOverlay: String? = nil) async throws -> Worktree {
        let pending = try await beginCreateWorktree(repoID: repoID, folder: folder, branch: branch, displayName: displayName, skipClaude: skipClaude, parentWorktreeID: parentWorktreeID, siblingOfWorktreeID: siblingOfWorktreeID, callerWorktreeID: callerWorktreeID, suppressAutoParent: suppressAutoParent, useExistingBranch: useExistingBranch, prNumber: prNumber)
        // Pass the original branch ref (may include `origin/` prefix) through
        // so phase 2 can dispatch to the correct git command.
        let existingBranchRef = useExistingBranch ? branch : nil
        let completion = try await completeCreateWorktree(worktreeID: pending.id, skipClaude: skipClaude, initialPrompt: initialPrompt, userSpecifiedFolder: folder != nil, userSpecifiedBranch: branch != nil, cols: cols, rows: rows, existingBranchRef: existingBranchRef, checkoutPRHead: checkoutPRHead, primaryAgentPreference: primaryAgentPreference, claudeSettingsOverlay: claudeSettingsOverlay)
        // Legacy synchronous contract: the returned worktree is fully set up.
        // Await phase 3 inline when a preSession hook gated the primary spawn.
        if case .preSessionPending(let phase3) = completion {
            await phase3.value
        }
        guard let completed = try await db.worktrees.getLocal(id: pending.id) else {
            throw WorktreeLifecycleError.worktreeNotFound(pending.id)
        }
        return completed.worktree
    }

    // MARK: - Two-Phase Create

    /// Phase 1: Synchronous-fast. Generates a name, inserts a DB row with
    /// `status = .creating`, and returns the worktree immediately.
    /// NO git operations happen here.
    public func beginCreateWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false, parentWorktreeID: UUID? = nil, siblingOfWorktreeID: UUID? = nil, callerWorktreeID: UUID? = nil, suppressAutoParent: Bool = false, useExistingBranch: Bool = false, prNumber: Int? = nil) async throws -> Worktree {
        // 1. Fetch repo
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // 1a. Resolve parent worktree (caller/sibling/explicit → parent id, or nil)
        let resolvedParent = try await ParentResolver.resolve(
            db: db,
            explicitParent: parentWorktreeID,
            siblingOf: siblingOfWorktreeID,
            caller: callerWorktreeID,
            suppressAutoParent: suppressAutoParent
        )

        // A worktree with active children isn't auto-archivable; disarm the parent.
        if let parentID = resolvedParent {
            do {
                try await db.worktrees.setAutoArchiveOnMerge(id: parentID, value: false)
            } catch {
                logger.warning("failed to disarm auto-archive for \(parentID, privacy: .public): \(error, privacy: .public)")
            }
        }

        // 2. Generate name and construct path
        let resolvedName: String
        let resolvedBranch: String
        let layout = WorktreeLayout()
        let canonicalBase = layout.basePath(for: repo)
        // Lazily create the canonical base directory for this slot.
        // (Phase A's v14_worktree_location migration guarantees worktreeSlot is set
        // for every repo, so basePath(for:) won't precondition-fail here.)
        try? FileManager.default.createDirectory(
            atPath: canonicalBase, withIntermediateDirectories: true
        )
        // try? above swallows both "already exists" (fine) and permission
        // errors (not fine). Verify the dir actually exists so a permission
        // failure surfaces here instead of as a misleading `git worktree add`
        // error downstream.
        if !FileManager.default.fileExists(atPath: canonicalBase) {
            logger.error("Failed to create worktree base dir \(canonicalBase, privacy: .public)")
        }

        if useExistingBranch {
            // Existing-branch flow: derive a folder name from the branch's
            // local name (stripping any `origin/` prefix). Never auto-name.
            guard let providedBranch = branch, !providedBranch.isEmpty else {
                throw WorktreeLifecycleError.createFailed(
                    "useExistingBranch requires a branch name"
                )
            }
            let localBranch = providedBranch.hasPrefix("origin/")
                ? String(providedBranch.dropFirst("origin/".count))
                : providedBranch
            let sanitized = WorktreeLayout.sanitize(localBranch)
            let baseFolder = sanitized.isEmpty ? "branch" : sanitized
            // Mirror the global UNIQUE constraint on `worktree.path`: avoid
            // paths already reserved by ANY row (active, archived, creating,
            // main). An archived worktree keeps its `path` even after its
            // directory is deleted, so a filesystem-only check would collide
            // and the insert would throw `UNIQUE constraint failed`. This
            // fetch deliberately stays on the location-neutral `list(...)`:
            // the constraint it mirrors spans every row on the table, so a
            // path withheld from this set is not a harmless omission — the
            // insert below would abort on it.
            let reserved = Set(try await db.worktrees.list().map(\.localPath))
            resolvedName = Self.uniqueFolderName(
                base: baseFolder, in: canonicalBase, reserved: reserved
            )
            // The on-disk local branch ends up as `localBranch` (for remote
            // tracking, `--track -b <localName>` creates it; for plain local,
            // we check out the same branch under the same name).
            resolvedBranch = localBranch
        } else {
            resolvedName = folder ?? NameGenerator.generate()
            resolvedBranch = branch ?? "tbd/\(resolvedName)"
        }
        let worktreePath = (canonicalBase as NSString).appendingPathComponent(resolvedName)
        let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)

        // Creating at this path is an explicit "track it again" — clear any
        // forget tombstone so reconcile resumes treating the path normally.
        // No-op when the path was never forgotten.
        try await db.forgottenWorktrees.delete(path: worktreePath)

        // 3. Insert DB row with status = .creating
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: resolvedName,
            displayName: displayName,
            branch: resolvedBranch,
            path: worktreePath,
            tmuxServer: tmuxServer,
            status: .creating,
            parentWorktreeID: resolvedParent,
            prNumber: prNumber
        )

        return worktree
    }

    /// Returns `<base>`, or `<base>-2`, `<base>-3`, … — the first folder name
    /// under `parentDir` whose absolute path neither exists on disk NOR is
    /// already reserved by an existing worktree row (`reserved`). Caps at -1000
    /// to avoid pathological infinite loops; throws via the underlying
    /// `git worktree add` if every candidate is taken.
    private static func uniqueFolderName(
        base: String, in parentDir: String, reserved: Set<String>
    ) -> String {
        func isTaken(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: path) || reserved.contains(path)
        }
        let firstCandidate = (parentDir as NSString).appendingPathComponent(base)
        if !isTaken(firstCandidate) {
            return base
        }
        for suffix in 2...1000 {
            let candidate = "\(base)-\(suffix)"
            let path = (parentDir as NSString).appendingPathComponent(candidate)
            if !isTaken(path) {
                return candidate
            }
        }
        // Fall through to the original; `git worktree add` will fail loudly.
        return base
    }

    /// Returns `base`, or `base-2`, `base-3`, … — the first name for which no
    /// local `refs/heads/<name>` exists. Mirrors `uniqueFolderName`'s loop but
    /// probes git refs instead of paths: the PR-head fetch uses a `+` force
    /// refspec, so a colliding name would silently rewrite an unrelated branch;
    /// this picks a free name first. Caps at -1000; if every candidate through
    /// `base-1000` is taken it THROWS rather than returning the taken `base` —
    /// returning it would let the force refspec clobber that existing branch.
    private func uniqueLocalBranchName(repoPath: String, base: String) async throws -> String {
        if try await git.localBranchExists(repoPath: repoPath, name: base) == false {
            return base
        }
        for suffix in 2...1000 {
            let candidate = "\(base)-\(suffix)"
            if try await git.localBranchExists(repoPath: repoPath, name: candidate) == false {
                return candidate
            }
        }
        throw WorktreeLifecycleError.createFailed(
            "no free local branch name for '\(base)' after 1000 attempts; refusing to reuse it (the force-fetch refspec would clobber the existing branch)")
    }

    /// Phase 2: Async. Performs git fetch, git worktree add, tmux setup,
    /// then updates status to `.active`. On failure, deletes the DB row.
    ///
    /// When a `preSession` hook resolves, only the hook's terminal is created
    /// here; the primary terminals are spawned by the returned
    /// `.preSessionPending` task once the hook completes (or times out).
    /// Phase-3 failures never delete the DB row — the checkout is valid.
    ///
    /// When `existingBranchRef` is non-nil, the worktree is checked out from
    /// that existing ref (local or `origin/*`) — no fresh branch is created.
    /// Set `retryGeneratedNameOnCollision` to false when callers have already
    /// rendered or persisted the pending row's generated identity.
    @discardableResult
    public func completeCreateWorktree(worktreeID: UUID, skipClaude: Bool = false, initialPrompt: String? = nil, userSpecifiedFolder: Bool = false, userSpecifiedBranch: Bool = false, cols: Int? = nil, rows: Int? = nil, existingBranchRef: String? = nil, checkoutPRHead: Bool = false, overrideProfileID: UUID? = nil, modelOverride: String? = nil, primaryAgentPreference: PrimaryAgentPreference? = nil, claudeSettingsOverlay: String? = nil, carryover: ConversationCarryover? = nil, retryGeneratedNameOnCollision: Bool = true) async throws -> WorktreeCreateCompletion {
        guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        guard let rid = worktree.repoID, let repo = try await db.repos.get(id: rid) else {
            try? await db.worktrees.delete(id: worktreeID)
            throw WorktreeLifecycleError.repoNotFound(worktree.repoID ?? worktreeID)
        }

        do {
            let clock = ContinuousClock()
            let phaseStart = clock.now
            let creationConfig = try await db.config.get()
            let creationPrimaryKind: TerminalKind = carryover == nil
                ? resolvePrimaryTerminalKind(
                    skipClaude: skipClaude,
                    archivedClaudeSessions: nil,
                    configuredPreference:
                        primaryAgentPreference ?? creationConfig.primaryAgentPreference
                )
                : .claude
            // Preflight the full Codex launch before creating a directory,
            // checking out a worktree, or starting a pre-session pane. Passing
            // the prepared values through phase 3 also prevents a second,
            // post-mutation resolution attempt after a long-running hook.
            let preparedCodexLaunch = creationPrimaryKind == .codex
                ? try CodexLaunchPreparation.prepare(
                    executableResolver: codexExecutableResolver,
                    homeEnsurer: codexHomeEnsurer)
                : nil

            // 1. Create parent directory
            let createDirStart = clock.now
            let parentDir = (worktree.path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )
            let createDirElapsedMs = createDirStart.duration(to: clock.now) / .milliseconds(1)
            timingLogger.debug("createdir \(worktreeID.uuidString, privacy: .public) \(Int(createDirElapsedMs))ms")

            // 2. git worktree add (fetch was run beforehand in the RPC handler)
            let worktreeAddStart = clock.now
            let resultPath: String
            // Set by the PR-head branch below: this worktree's contents came
            // from `refs/pull/<n>/head`, which a third-party fork may have
            // authored. Persisted on the row so the five *later* trust-seeding
            // call sites (wake, revive, terminal create, profile swap,
            // extra-session restore) can see it too.
            var checkedOutForeignHead = false
            if let ref = existingBranchRef {
                // Existing-branch flow: check out the chosen ref. Local branches
                // get `git worktree add <path> <branch>`; remote refs get
                // `--track -b <localName> <path> origin/<name>` to create a
                // local tracking branch.
                do {
                    if checkoutPRHead, let prNumber = worktree.prNumber {
                        // Fork-PR checkout: the PR head has no local ref, so
                        // fetch refs/pull/<n>/head into a collision-free local
                        // branch (the `+` refspec force-updates, so reusing an
                        // existing ref name would silently rewrite an unrelated
                        // branch), then check it out via the plain
                        // existing-branch path. No fork remote is ever added.
                        //
                        // Decorated same-repo rows (prNumber set, checkoutPRHead
                        // false) fall through to the else-branches below and
                        // check out the existing branch unchanged — prNumber is
                        // already stamped on the row for status tracking.
                        let localBranch = try await uniqueLocalBranchName(
                            repoPath: repo.path, base: worktree.branch
                        )
                        try await git.fetchPullRequestHead(
                            repoPath: repo.path, number: prNumber, localBranch: localBranch
                        )
                        try await git.worktreeAddExisting(
                            repoPath: repo.path,
                            worktreePath: worktree.path,
                            branch: localBranch
                        )
                        if localBranch != worktree.branch {
                            try await db.worktrees.updateBranch(id: worktreeID, branch: localBranch)
                        }
                        // TBD made this directory but not its contents: stamp
                        // the row so folder-trust is never pre-answered for it.
                        checkedOutForeignHead = true
                        try await db.worktrees.markForeignHead(id: worktreeID)
                    } else if ref.hasPrefix("origin/") {
                        try await git.worktreeAddTrackingRemote(
                            repoPath: repo.path,
                            worktreePath: worktree.path,
                            localBranch: worktree.branch,
                            remoteRef: ref
                        )
                    } else {
                        try await git.worktreeAddExisting(
                            repoPath: repo.path,
                            worktreePath: worktree.path,
                            branch: worktree.branch
                        )
                    }
                    resultPath = worktree.path
                } catch {
                    // Clean up any partially-created directory before bubbling.
                    try? FileManager.default.removeItem(atPath: worktree.path)
                    throw WorktreeLifecycleError.createFailed(
                        "git worktree add failed for existing branch '\(ref)': \(error)"
                    )
                }
            } else {
                let result = try await attemptWorktreeAdd(
                    repo: repo, name: worktree.name, branch: worktree.branch,
                    worktreePath: worktree.path,
                    userSpecifiedFolder: userSpecifiedFolder,
                    userSpecifiedBranch: userSpecifiedBranch,
                    retryGeneratedNameOnCollision: retryGeneratedNameOnCollision
                )

                // 4. If the name changed due to collision, update the DB record
                if result.name != worktree.name {
                    // Update path/branch/name in DB would be complex — for now the retry
                    // names the worktree path differently but we keep the original DB row.
                    // The attemptWorktreeAdd already handles retries.
                }
                resultPath = result.path
            }
            let worktreeAddElapsedMs = worktreeAddStart.duration(to: clock.now) / .milliseconds(1)
            timingLogger.debug("worktree-add \(worktreeID.uuidString, privacy: .public) \(Int(worktreeAddElapsedMs))ms")

            // The spawn paths below take this value rather than re-reading the
            // row, so carry the `foreignHead` stamp onto the in-memory copy —
            // otherwise the very first Claude spawn would still seed trust for
            // a tree it just fetched from a fork.
            var stamped = worktree.worktree
            stamped.foreignHead = stamped.foreignHead || checkedOutForeignHead
            let spawnWorktree = stamped

            // 3. Setup tmux terminals.
            let terminalSpawnStart = clock.now
            // 3a. Blocking preSession hook: spawn its terminal FIRST and gate
            // the primary terminals on its completion marker. The wait runs in
            // a background task so the caller's RepoSerializer lane is freed
            // immediately — never block it for the duration of the hook.
            if let preSession = try await spawnPreSessionTerminal(
                worktree: spawnWorktree, repo: repo,
                worktreePath: resultPath,
                cols: cols, rows: rows
            ) {
                // Broadcast early. `.worktreeCreated` is for non-app clients —
                // the app's handleDelta ignores it (default: break); what makes
                // the app load and show the live hook terminal is the
                // `.terminalCreated` delta below. The RPC handler skips its
                // own `.worktreeCreated` for the `.preSessionPending` result,
                // so this stays a single broadcast.
                subscriptions?.broadcast(delta: .worktreeCreated(WorktreeDelta(
                    worktreeID: worktree.id, repoID: worktree.repoID,
                    name: worktree.name, path: resultPath
                )))
                subscriptions?.broadcast(delta: .terminalCreated(TerminalDelta(
                    terminalID: preSession.terminalID,
                    worktreeID: worktree.id,
                    label: TerminalLabel.preSession
                )))
                let terminalSpawnElapsedMs = terminalSpawnStart.duration(to: clock.now) / .milliseconds(1)
                timingLogger.debug("terminal-spawn-presession \(worktreeID.uuidString, privacy: .public) \(Int(terminalSpawnElapsedMs))ms")
                let phase3 = Task.detached { [self] in
                    await runPreSessionPhase3(
                        preSession: preSession,
                        worktree: spawnWorktree, repo: repo,
                        worktreePath: resultPath,
                        skipClaude: skipClaude,
                        initialPrompt: initialPrompt,
                        cols: cols, rows: rows,
                        completionAction: .markActive,
                        overrideProfileID: overrideProfileID,
                        modelOverride: modelOverride,
                        primaryAgentPreference: primaryAgentPreference,
                        claudeSettingsOverlay: claudeSettingsOverlay,
                        carryover: carryover,
                        preparedCodexLaunch: preparedCodexLaunch
                    )
                    // Fresh creates get an initial note tab, appended after the
                    // primary spawn set the tab order. Create path only — a
                    // revive's surviving note rows re-materialize via the app's
                    // reconcile instead. Best-effort: if the worktree row
                    // vanished mid-wait, the note insert FK-fails and is logged.
                    await createInitialNoteTab(
                        worktreeID: worktree.id,
                        seed: carryover?.notesSeed
                    )
                }
                return .preSessionPending(phase3: phase3)
            }

            // 3b. No preSession hook: spawn primary terminals inline
            // (behavior identical to before the preSession hook existed).
            _ = try await spawnPrimaryTerminals(
                worktree: spawnWorktree, repo: repo,
                worktreePath: resultPath,
                skipClaude: skipClaude,
                initialPrompt: initialPrompt,
                cols: cols,
                rows: rows,
                preSessionTerminalID: nil,
                overrideProfileID: overrideProfileID,
                modelOverride: modelOverride,
                primaryAgentPreference: primaryAgentPreference,
                claudeSettingsOverlay: claudeSettingsOverlay,
                carryover: carryover,
                preparedCodexLaunch: preparedCodexLaunch
            )
            let terminalSpawnElapsedMs = terminalSpawnStart.duration(to: clock.now) / .milliseconds(1)
            timingLogger.debug("terminal-spawn \(worktreeID.uuidString, privacy: .public) \(Int(terminalSpawnElapsedMs))ms")

            // 3c. Fresh repo-backed creates get an initial note tab (appended
            // last; the primary terminal keeps focus).
            await createInitialNoteTab(
                worktreeID: worktreeID,
                seed: carryover?.notesSeed
            )

            // 4. Update status to active
            let markActiveStart = clock.now
            try await db.worktrees.updateStatus(id: worktreeID, status: .active)
            let markActiveElapsedMs = markActiveStart.duration(to: clock.now) / .milliseconds(1)
            timingLogger.debug("mark-active \(worktreeID.uuidString, privacy: .public) \(Int(markActiveElapsedMs))ms")

            let totalElapsedMs = phaseStart.duration(to: clock.now) / .milliseconds(1)
            timingLogger.info("complete-worktree \(worktreeID.uuidString, privacy: .public) total \(Int(totalElapsedMs))ms")
            return .ready

        } catch {
            // On failure, delete the DB row
            try? await db.worktrees.delete(id: worktreeID)
            throw error
        }
    }

    /// Creates the initial "Notes" tab for a freshly created repo-backed
    /// worktree and appends it to the tab order (last; the primary terminal
    /// keeps focus). Ordinary creates leave the note empty; callers may provide
    /// a seed for flows whose initial Notes should carry context. The app
    /// materializes the tab from the note row via its `reconcileNoteTabs` poll
    /// — note tabs use the note row's UUID as the tab ID. Best-effort: a failure
    /// (e.g. the worktree row vanished mid-create, FK-failing the insert) must
    /// never fail the create, whose checkout and terminals are already valid.
    func createInitialNoteTab(worktreeID: UUID, seed: String? = nil) async {
        do {
            let note = try await db.notes.create(worktreeID: worktreeID, title: "Notes")
            if let seed {
                _ = try await db.notes.update(
                    id: note.id,
                    title: note.title,
                    content: seed
                )
            }
            var order = try await db.worktrees.getTabOrder(worktreeID: worktreeID)
            order.append(note.id)
            try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: order)
        } catch {
            logger.warning("failed to create initial note tab for \(worktreeID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Attempts to create a git worktree, trying origin/<default> then falling back
    /// to local <default> as the base branch. Retries once with a new name on collision.
    private func attemptWorktreeAdd(
        repo: Repo, name: String, branch: String,
        worktreePath: String,
        userSpecifiedFolder: Bool,
        userSpecifiedBranch: Bool,
        retryGeneratedNameOnCollision: Bool
    ) async throws -> (name: String, branch: String, path: String) {
        let repoPath = repo.path
        let defaultBranch = repo.defaultBranch
        // Try with origin/<default> first, then local <default>
        let baseBranches = ["origin/\(defaultBranch)", defaultBranch]

        var lastError: Error? = nil

        // A branch the caller NAMED that already exists locally gets checked
        // out, not re-created. `git worktree add -b <branch>` is fatal when the
        // ref exists ("a branch named 'x' already exists"), and every attempt
        // below would hit it — both base branches, then both again after the
        // folder-rename retry, which keeps a user-specified branch. Four
        // failures, one cause.
        //
        // This is the ordinary case, not an edge case: spawning a session onto
        // an existing PR means the branch is already there.
        //
        // Gated on `userSpecifiedBranch` deliberately. An auto-generated
        // `tbd/<name>` that collides means the NAME collided — the right answer
        // there is a fresh name (the retry below), not silently adopting
        // whatever branch happens to hold that name.
        //
        // A failed existence probe falls through to the old path rather than
        // failing creation: not knowing is not the same as knowing it's absent.
        let branchExistsLocally = (try? await git.localBranchExists(repoPath: repoPath, name: branch)) ?? false
        if userSpecifiedBranch && branchExistsLocally {
            do {
                try await git.worktreeAddExisting(
                    repoPath: repoPath,
                    worktreePath: worktreePath,
                    branch: branch
                )
                return (name: name, branch: branch, path: worktreePath)
            } catch {
                try? FileManager.default.removeItem(atPath: worktreePath)
                // No rename retry here: the branch is the caller's and is kept
                // across retries, so a second attempt fails identically. Git's
                // stderr is the useful part — for the common follow-on failure
                // it reads "'x' is already used by worktree at <path>", which
                // names the directory holding it.
                throw WorktreeLifecycleError.createFailed(
                    "could not check out existing branch '\(branch)'\(formatErrorForMessage(error))"
                )
            }
        }

        for baseBranch in baseBranches {
            do {
                try await git.worktreeAdd(
                    repoPath: repoPath,
                    worktreePath: worktreePath,
                    branch: branch,
                    baseBranch: baseBranch
                )
                return (name: name, branch: branch, path: worktreePath)
            } catch {
                lastError = error
                logger.warning("Failed to add worktree with base branch \(baseBranch, privacy: .public): \(String(describing: error), privacy: .public)")
                // Clean up the directory if it was partially created
                try? FileManager.default.removeItem(atPath: worktreePath)
            }
        }

        // Explicit folders and identity-sensitive callers cannot silently
        // switch to a different generated folder and branch.
        if userSpecifiedFolder || !retryGeneratedNameOnCollision {
            let errorDetail = lastError.flatMap { formatErrorForMessage($0) } ?? ""
            throw WorktreeLifecycleError.createFailed(
                "git worktree add failed — the folder or branch may already exist\(errorDetail)"
            )
        }

        // Retry with a fresh folder name. Keep user's branch if they specified it.
        let retryName = NameGenerator.generate()
        let retryBranch = userSpecifiedBranch ? branch : "tbd/\(retryName)"
        let retryCanonicalBase = WorktreeLayout().basePath(for: repo)
        let retryPath = (retryCanonicalBase as NSString).appendingPathComponent(retryName)
        try FileManager.default.createDirectory(
            atPath: retryCanonicalBase,
            withIntermediateDirectories: true
        )

        for baseBranch in baseBranches {
            do {
                try await git.worktreeAdd(
                    repoPath: repoPath,
                    worktreePath: retryPath,
                    branch: retryBranch,
                    baseBranch: baseBranch
                )
                return (name: retryName, branch: retryBranch, path: retryPath)
            } catch {
                lastError = error
                logger.warning("Failed to add worktree with retry path and base branch \(baseBranch, privacy: .public): \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(atPath: retryPath)
            }
        }

        let errorDetail = lastError.flatMap { formatErrorForMessage($0) } ?? ""
        throw WorktreeLifecycleError.createFailed(
            "git worktree add failed after all attempts\(errorDetail)"
        )
    }

    /// Formats an error for inclusion in a user-facing message, truncated to ~500 chars.
    private func formatErrorForMessage(_ error: Error) -> String {
        var detail = ""
        if let gitError = error as? GitError {
            let stderr = gitError.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = stderr
        } else {
            detail = error.localizedDescription
        }
        if detail.isEmpty {
            return ""
        }
        // Truncate to ~500 chars and clean up
        let maxLen = 500
        if detail.count > maxLen {
            detail = String(detail.prefix(maxLen)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return "\nDetails: \(detail)"
    }

    private func resolvePrimaryTerminalKind(
        skipClaude: Bool,
        archivedClaudeSessions: [String]?,
        configuredPreference: PrimaryAgentPreference
    ) -> TerminalKind {
        if skipClaude {
            return .shell
        }
        if let archivedClaudeSessions, !archivedClaudeSessions.isEmpty {
            return .claude
        }
        return configuredPreference.terminalKind
    }

    /// Wraps a command so the user's shell takes over when it exits,
    /// preventing tmux from destroying the window and jumping to another.
    /// If the command is already the user's shell, returns it unchanged.
    private func shellWrapped(_ command: String) -> String {
        if command == defaultShell { return command }
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'; exec \(defaultShell)"
    }

    /// Spawns the primary agent terminal, the parallel `setup` hook terminal,
    /// and any archived-session restores; persists tab order + active tab and
    /// kills the untracked initial tmux window. This is the pre-existing
    /// `setupTerminals` body, parameterized by an optional already-created
    /// pre-session terminal (slotted second in the tab order).
    ///
    /// Returns the created terminals as `(id, label)` pairs so phase 3 can
    /// broadcast `.terminalCreated` for each.
    ///
    /// **It does not read or write `worktree.pending_prompt`.** Its whole
    /// involvement with a queued prompt is one notification, after the primary
    /// terminal row exists, that the pane is up
    /// (`PendingPromptCoordinator.notePrimaryTerminalExists`); the coordinator
    /// owns every decision and every write.
    @discardableResult
    func spawnPrimaryTerminals(
        worktree: Worktree, repo: Repo?,
        worktreePath: String? = nil, skipClaude: Bool,
        archivedClaudeSessions: [String]? = nil,
        initialPrompt: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        preSessionTerminalID: UUID?,
        overrideProfileID: UUID? = nil,
        modelOverride: String? = nil,
        primaryAgentPreference: PrimaryAgentPreference? = nil,
        claudeSettingsOverlay: String? = nil,
        carryover: ConversationCarryover? = nil,
        preparedCodexLaunch: CodexLaunchPreparation? = nil
    ) async throws -> [(id: UUID, label: String)] {
        let worktreeID = worktree.id
        let tmuxServer = worktree.tmuxServer
        let worktreePath = worktreePath ?? worktree.localPath
        let config = try await db.config.get()
        let claudeEnvOverrides = config.envSettingOverrides
        let primaryTerminalKind: TerminalKind = carryover == nil
            ? resolvePrimaryTerminalKind(
                skipClaude: skipClaude,
                archivedClaudeSessions: archivedClaudeSessions,
                configuredPreference: primaryAgentPreference ?? config.primaryAgentPreference
            )
            : .claude
        let archivedSessions = archivedClaudeSessions ?? []
        // Resolve Codex before `ensureServer` creates tmux state. `new-window`
        // can succeed even when its child shell cannot find a bare `codex`
        // command, which would leave a terminal row whose pane already exited.
        let codexLaunch: CodexLaunchPreparation?
        if primaryTerminalKind == .codex {
            if let preparedCodexLaunch {
                codexLaunch = preparedCodexLaunch
            } else {
                codexLaunch = try CodexLaunchPreparation.prepare(
                    executableResolver: codexExecutableResolver,
                    homeEnsurer: codexHomeEnsurer)
            }
        } else {
            codexLaunch = nil
        }
        // Resolve a usable size: prefer caller's value, otherwise fall back to
        // TmuxManager's defaults. tmux's own 80x24 default would let Claude
        // render into hard-wrapped scrollback that can never be reflowed when
        // the user later attaches a wider SwiftTerm view.
        let resolvedCols = cols ?? TmuxManager.defaultCols
        let resolvedRows = rows ?? TmuxManager.defaultRows
        // Ensure tmux server exists — capture initial window ID to kill later
        let initialWindowID = try await tmux.ensureServer(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            cols: resolvedCols,
            rows: resolvedRows
        )
        await controlMode?.enableIfGated(serverName: tmuxServer)

        // Resolve model profile. An explicit per-creation `overrideProfileID`
        // (chosen in the sidebar `+` profile picker) wins over the precedence
        // chain (repo override → global default → none); nil preserves it.
        // Failures here must NOT break worktree creation — fall back to keychain login.
        let needsResolvedClaudeProfile = !skipClaude && (
            primaryTerminalKind == .claude || !archivedSessions.isEmpty
        )
        var resolvedProfile: ResolvedModelProfile? = nil
        if needsResolvedClaudeProfile, let resolver = modelProfileResolver {
            do {
                resolvedProfile = try await resolver.resolve(repoID: repo?.id, override: overrideProfileID)
            } catch {
                logger.warning("model profile resolution failed; falling back to keychain login")
                resolvedProfile = nil
            }
        }

        // Free-form env overrides: global < repo < profile. Applied to both
        // Claude and Codex. For Claude the builder's auth/routing env is layered
        // on top (below), so it can't be clobbered. See docs/env-overrides.md.
        let mergedEnvOverrides = EnvOverrideResolver.merge(
            global: config.envOverrides,
            repo: repo?.envOverrides,
            profile: resolvedProfile?.envOverrides
        )

        // A queued prompt never rides this command line. There is one delivery
        // path — the coordinator pastes it once the pane is up — so nothing
        // here reads or writes `worktree.pending_prompt`, and the only writer
        // that can clear it is the coordinator, after a paste it watched
        // succeed.
        let effectivePrompt = initialPrompt

        // Create terminal 1: primary agent (or shell if skipped).
        let plannedTerminalID1 = UUID()
        var createdTerminalIDs = [plannedTerminalID1]
        let primaryCommand: String
        let primaryEnv: [String: String]
        let primarySensitiveEnv: [String: String]
        let primarySessionID: String?
        let primaryProfileID: UUID?
        let primaryLabel: String
        switch primaryTerminalKind {
        case .shell:
            primaryCommand = defaultShell
            primaryEnv = [
                "TBD_WORKTREE_ID": worktreeID.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID1.uuidString,
            ]
            primarySensitiveEnv = [:]
            primarySessionID = nil
            primaryProfileID = nil
            primaryLabel = TerminalLabel.shell
        case .codex:
            guard let codexLaunch else {
                preconditionFailure(
                    "Codex launch must be prepared before the Codex spawn branch")
            }
            primaryCommand = CodexSpawnCommandBuilder.build(
                initialPrompt: effectivePrompt,
                executablePath: codexLaunch.executablePath)
            primaryEnv = [
                "TBD_WORKTREE_ID": worktreeID.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID1.uuidString,
                "CODEX_HOME": codexLaunch.codexHome.path,
            ]
            // omz-update suppression rides `-e` (process env before .zshrc)
            // so the update prompt can't block the codex command; FORCED over
            // user overrides (matching the claude path) — agent tabs must
            // never block on the interactive prompt.
            primarySensitiveEnv = mergedEnvOverrides
                .merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced }
            primarySessionID = nil
            primaryProfileID = nil
            primaryLabel = TerminalLabel.codex
        case .claude:
            let archivedSession = carryover == nil ? archivedSessions.first : nil
            let sessionUUID = carryover?.sourceSessionID ?? archivedSession ?? UUID().uuidString
            primarySessionID = sessionUUID
            let isResume = archivedSession != nil || carryover != nil
            // `--resume` is what actually restores the prior conversation;
            // `--session-id` is for starting a NEW session with a pre-chosen
            // UUID (used on fresh create). Reviving with `--session-id` on an
            // already-existing session file would lose the transcript.
            let appendPrompt = isResume
                ? nil
                : SystemPromptBuilder.build(
                    repo: repo, worktree: worktree, isResume: false,
                    scratchInstructions: config.scratchInstructions,
                    scratchRenamePrompt: config.scratchRenamePrompt)
            let profileConfigDir = configDirManager.resolveConfigDir(for: resolvedProfile)
            // Pre-accept Claude Code's folder-trust dialog. TBD just created
            // this worktree from a repo the operator registered, so the trust
            // answer is known by construction — and the dialog blocks before
            // SessionStart, so a stall here would be machine-invisible.
            // Scratch always seeds; non-scratch honors the config flag and is
            // skipped entirely when the row is `foreignHead` (PR-head checkout,
            // possibly fork-authored contents). Best-effort, never throws.
            await ClaudeTrustSeeder.ensureTrusted(
                worktree: worktree,
                autoTrustNonScratch: config.autoTrustWorktrees,
                profileConfigDir: profileConfigDir)
            if isResume {
                // Pre-resume freshness: `claude --resume` only looks in the
                // project dir derived from the current cwd. If the archived
                // session's transcript lives elsewhere (worktree moved or
                // promoted since it was written), mirror it in first
                // (copy-if-newer, best-effort). No stored transcript path
                // survives archival (archive deletes terminal rows), so the
                // sync falls back to locating the jsonl by session ID across
                // the projects root. Detached: the copy is synchronous
                // filesystem work; the await keeps it ordered before spawn.
                await TranscriptProjectDirSync.ensureSessionResumableDetached(
                    sessionID: sessionUUID,
                    worktreePath: worktreePath,
                    projectsRoot: claudeProjectsRoot(profileConfigDirPath: profileConfigDir),
                    storedTranscriptPath: nil
                )
            }
            let spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: isResume ? sessionUUID : nil,
                forkSession: carryover != nil,
                freshSessionID: isResume ? nil : sessionUUID,
                appendSystemPrompt: appendPrompt,
                // A carryover spawn sends NO initial prompt — it must open idle
                // at the composer like any other resume. `isResume` is true
                // whenever a carryover is present, so this expression also
                // preserves the pre-existing behavior for plain resumes (never
                // a prompt) and fresh creates (the caller's prompt).
                initialPrompt: isResume ? nil : effectivePrompt,
                profileSecret: resolvedProfile?.secret,
                profileKind: resolvedProfile?.kind,
                profileBaseURL: resolvedProfile?.baseURL,
                // Per-spawn model override (picker model buttons) wins over
                // the profile default for this initial spawn only.
                profileModel: modelOverride ?? resolvedProfile?.model,
                profileAwsRegion: resolvedProfile?.awsRegion,
                profileAwsProfile: resolvedProfile?.awsProfile,
                profileConfigDir: profileConfigDir,
                cmd: nil,
                shellFallback: defaultShell,
                settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                    fallbackModels: resolvedProfile?.fallbackModels,
                    sessionKey: plannedTerminalID1.uuidString,
                    // Repo fragment is file-backed config, read fresh at
                    // spawn time — applies on every spawn path, resume included.
                    repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id),
                    // Per-spawn fragment applies to FRESH primary spawns only;
                    // an archived-session resume must not reapply it. Hooks
                    // overlay still resolves for resumes — only
                    // extraSettingsJSON goes nil.
                    extraSettingsJSON: isResume ? nil : claudeSettingsOverlay
                ),
                pluginDirPath: PluginDirWriter.pluginDirPath,
                envSettingOverrides: claudeEnvOverrides,
                sessionName: worktree.displayName
            )
            primaryCommand = spawn.command
            primaryEnv = [
                "TBD_WORKTREE_ID": worktreeID.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID1.uuidString,
            ]
            // Layer the builder's auth/routing env ON TOP of free-form overrides
            // so auth/routing stays final and free-form vars can't clobber it.
            primarySensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }
            primaryProfileID = resolvedProfile?.profileID
            primaryLabel = TerminalLabel.claudeCode
        }
        let window1 = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: primaryCommand,
            env: primaryEnv,
            sensitiveEnv: primarySensitiveEnv,
            cols: resolvedCols,
            rows: resolvedRows
        )
        _ = try await db.terminals.create(
            id: plannedTerminalID1,
            worktreeID: worktreeID,
            tmuxWindowID: window1.windowID,
            tmuxPaneID: window1.paneID,
            label: primaryLabel,
            claudeSessionID: primarySessionID,
            profileID: primaryProfileID,
            kind: primaryTerminalKind
        )
        if carryover != nil {
            SessionRecaptureScheduler(db: db, tmux: tmux).schedule(
                terminalID: plannedTerminalID1,
                paneID: window1.paneID,
                server: tmuxServer
            )
        }
        var createdTerminals: [(id: UUID, label: String)] = [
            (id: plannedTerminalID1, label: primaryLabel)
        ]

        // The pane a parked prompt was waiting for now exists. This is the
        // whole of the spawn path's involvement: it passes no prompt, reads no
        // column and writes none. The coordinator decides whether it may type,
        // and the readiness ceiling starts here rather than at the park — a
        // `preSession` hook can run for ten minutes, and a ceiling armed at the
        // park would expire before the agent existed.
        await pendingPromptCoordinator?.notePrimaryTerminalExists(
            worktreeID: worktreeID, terminalID: plannedTerminalID1)

        // Create terminal 2: setup hook. Repo-backed worktrees only — scratch
        // spaces (repo == nil) have no repo path/setup hook and get just the
        // primary terminal, so the tab order stays `[primary]`.
        var setupAutoCloseSpawn: PreSessionSpawn?
        if let repo {
            let plannedTerminalID2 = UUID()
            createdTerminalIDs.append(plannedTerminalID2)
            let setupHookPath = hooks.resolve(
                event: .setup,
                repoPath: worktreePath,
                appHookPath: worktree.repoID.map {
                    TBDConstants.hookPath(repoID: $0, eventName: HookEvent.setup.rawValue)
                }
            )
            let setupCommand: String
            var setupMarkerPath: String?
            if config.autoCloseSetupEnabled, let setupHookPath {
                // Auto-close soak flag ON with a resolved hook: wrap so the
                // exit code lands in a marker (the watcher spawned below tears
                // the tab down on exit 0). Delete any stale marker from a
                // previous run of this worktree ID before the pane spawns.
                let markerPath = Self.setupMarkerPath(worktreeID: worktreeID)
                try? FileManager.default.removeItem(atPath: markerPath)
                setupMarkerPath = markerPath
                setupCommand = Self.setupAutoCloseCommand(
                    hookPath: setupHookPath,
                    runtimeDir: Self.setupRuntimeDir,
                    markerPath: markerPath,
                    shell: defaultShell
                )
            } else {
                // Flag off (default) or no hook: today's behavior unchanged.
                setupCommand = shellWrapped(setupHookPath ?? defaultShell)
            }
            // Suppress the omz update prompt only when a setup hook actually
            // resolves — a hook-less "Setup" tab is just a regular shell and must
            // keep oh-my-zsh update checks (see `hookPaneEnv`).
            let setupSensitiveEnv = setupHookPath != nil ? Self.hookPaneEnv : [:]
            // Full hook environment per docs/worktree-hooks.md (matches the
            // preSession and archive hooks). TBD_WORKTREE_NAME uses
            // `worktree.name` for consistency with the archive hook's env.
            let setupEnv: [String: String] = [
                "TBD_WORKTREE_ID": worktreeID.uuidString,
                "TBD_TERMINAL_ID": plannedTerminalID2.uuidString,
                "TBD_EVENT": HookEvent.setup.rawValue,
                "TBD_WORKTREE_NAME": worktree.name,
                "TBD_WORKTREE_PATH": worktreePath,
                "TBD_REPO_PATH": repo.path,
                "TBD_BRANCH": worktree.branch,
            ]
            let window2 = try await tmux.createWindow(
                server: tmuxServer,
                session: "main",
                cwd: worktreePath,
                shellCommand: setupCommand,
                env: setupEnv,
                sensitiveEnv: setupSensitiveEnv,
                cols: resolvedCols,
                rows: resolvedRows
            )
            _ = try await db.terminals.create(
                id: plannedTerminalID2,
                worktreeID: worktreeID,
                tmuxWindowID: window2.windowID,
                tmuxPaneID: window2.paneID,
                label: TerminalLabel.setup,
                kind: .shell
            )
            createdTerminals.append((id: plannedTerminalID2, label: TerminalLabel.setup))
            if let setupMarkerPath, let setupHookPath {
                // The auto-close wrapper lets the pane EXIT on hook success,
                // and tmux destroys the window the instant it does — before
                // the watcher's teardown can capture the scrollback for
                // closed-terminal history. Keep the dead pane around; the
                // teardown's killWindow removes it after capturing.
                // Best-effort: a failure only costs the captured history.
                do {
                    try await tmux.setRemainOnExit(server: tmuxServer, windowID: window2.windowID)
                } catch {
                    logger.warning("setup auto-close: remain-on-exit failed for window \(window2.windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                setupAutoCloseSpawn = PreSessionSpawn(
                    terminalID: plannedTerminalID2,
                    windowID: window2.windowID,
                    paneID: window2.paneID,
                    markerPath: setupMarkerPath,
                    hookPath: setupHookPath
                )
            }
        }

        // Restore any archived Claude sessions that were not consumed by the
        // primary terminal.
        let additionalArchivedClaudeSessions: [String]
        switch primaryTerminalKind {
        case .claude:
            additionalArchivedClaudeSessions = carryover == nil
                ? Array(archivedSessions.dropFirst())
                : archivedSessions
        case .codex:
            additionalArchivedClaudeSessions = archivedSessions
        case .shell:
            additionalArchivedClaudeSessions = []
        }
        if !skipClaude {
            for sessionID in additionalArchivedClaudeSessions {
                let plannedID = UUID()
                createdTerminalIDs.append(plannedID)
                let restoreProfileConfigDir = configDirManager.resolveConfigDir(for: resolvedProfile)
                // Pre-accept the folder-trust dialog so restoring an extra
                // archived session onto a fresh profile dir doesn't re-prompt.
                await ClaudeTrustSeeder.ensureTrusted(
                    worktree: worktree,
                    autoTrustNonScratch: config.autoTrustWorktrees,
                    profileConfigDir: restoreProfileConfigDir)
                // Same pre-resume freshness sync as the primary terminal above.
                await TranscriptProjectDirSync.ensureSessionResumableDetached(
                    sessionID: sessionID,
                    worktreePath: worktreePath,
                    projectsRoot: claudeProjectsRoot(profileConfigDirPath: restoreProfileConfigDir),
                    storedTranscriptPath: nil
                )
                let spawn = ClaudeSpawnCommandBuilder.build(
                    resumeID: sessionID,
                    freshSessionID: nil,
                    appendSystemPrompt: nil,
                    initialPrompt: nil,
                    profileSecret: resolvedProfile?.secret,
                    profileKind: resolvedProfile?.kind,
                    profileBaseURL: resolvedProfile?.baseURL,
                    // No per-spawn model override here: archived-session
                    // restores only happen on revive/recovery, whose callers
                    // never pass one (create never carries archived sessions).
                    profileModel: resolvedProfile?.model,
                    profileAwsRegion: resolvedProfile?.awsRegion,
                    profileAwsProfile: resolvedProfile?.awsProfile,
                    profileConfigDir: restoreProfileConfigDir,
                    cmd: nil,
                    shellFallback: defaultShell,
                    settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                        fallbackModels: resolvedProfile?.fallbackModels,
                        sessionKey: plannedID.uuidString,
                        repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id)
                    ),
                    pluginDirPath: PluginDirWriter.pluginDirPath,
                    envSettingOverrides: claudeEnvOverrides,
                    sessionName: worktree.displayName
                )
                let perTermEnv: [String: String] = [
                    "TBD_WORKTREE_ID": worktreeID.uuidString,
                    "TBD_TERMINAL_ID": plannedID.uuidString,
                ]
                let window = try await tmux.createWindow(
                    server: tmuxServer,
                    session: "main",
                    cwd: worktreePath,
                    shellCommand: spawn.command,
                    env: perTermEnv,
                    // Same free-form-under-auth layering as the primary terminal.
                    sensitiveEnv: mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder },
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                _ = try await db.terminals.create(
                    id: plannedID,
                    worktreeID: worktreeID,
                    tmuxWindowID: window.windowID,
                    tmuxPaneID: window.paneID,
                    label: TerminalLabel.claudeCode,
                    claudeSessionID: sessionID,
                    profileID: resolvedProfile?.profileID,
                    kind: .claude
                )
                createdTerminals.append((id: plannedID, label: TerminalLabel.claudeCode))
            }
        }

        // Tab order: [primary, (preSession), setup, archived restores…],
        // active = primary. Without a pre-session terminal this is exactly
        // the pre-existing [primary, setup, …] order.
        var tabOrder = createdTerminalIDs
        if let preSessionTerminalID {
            tabOrder.insert(preSessionTerminalID, at: 1)
        }
        try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: tabOrder)
        try await db.worktrees.setActiveTabID(worktreeID: worktreeID, tabID: plannedTerminalID1)

        // Kill the untracked initial window that new-session created
        if let windowID = initialWindowID {
            try? await tmux.killWindow(server: tmuxServer, windowID: windowID)
        }

        // Flag-on setup spawn: arm the detached auto-close watcher. Started
        // only AFTER the tab order above is persisted, so its teardown can
        // never race the setTabOrder write and resurrect the closed tab.
        if let setupAutoCloseSpawn {
            let lifecycle = self
            Task.detached {
                await lifecycle.finishAutoCloseSetup(
                    worktree: worktree, setup: setupAutoCloseSpawn
                )
            }
        }

        return createdTerminals
    }
}
