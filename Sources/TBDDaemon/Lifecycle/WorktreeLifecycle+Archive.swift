import Foundation
import os
import TBDShared

private let archiveLogger = Logger(subsystem: "com.tbd.daemon", category: "archive")

/// Result of `beginReviveWorktree`. Mirrors `WorktreeCreateCompletion`: the
/// pre-session path defers the primary terminal spawn to a detached task so
/// the revive RPC isn't blocked for the duration of the hook.
public enum WorktreeReviveCompletion: Sendable {
    /// All terminals were spawned inline; the worktree is `.active`.
    case ready(Worktree)
    /// A blocking `preSession` hook terminal was spawned and the row flipped
    /// to `.creating` (the app gates its pre-session UI on that status).
    /// `phase3` awaits the hook, spawns the primary terminals, and finishes
    /// the revive (status `.active`, `archivedAt`/session clearing).
    case preSessionPending(worktree: Worktree, phase3: Task<Void, Never>)

    /// The worktree row as of the moment the call returned (`.active` when
    /// ready, `.creating` while the pre-session hook runs).
    public var worktree: Worktree {
        switch self {
        case .ready(let worktree): return worktree
        case .preSessionPending(let worktree, _): return worktree
        }
    }
}

/// Why archive refused a local worktree whose folder may hold uncommitted
/// work: what `WorktreeArchiveError.uncommittedChanges` carries.
///
/// Archiving renames the folder into the deletion queue and unlinks it, and a
/// revive rebuilds the folder from the branch, so modified tracked files and
/// untracked files that are not ignored are the one thing an archive destroys
/// for good. Committed work survives on the branch, pushed or not, which is
/// why unpushed commits are not checked. The exception is commits made inside
/// a submodule of a linked worktree: they live in
/// `<repo>/.git/worktrees/<wt>/modules/<name>`, which phase 2's
/// `git worktree prune` deletes, so they are lost unless pushed, and this
/// guard does not check for that.
///
/// `message` states the fact alone and names no remedy, because the remedy
/// differs by surface: the CLI appends its `--force` hint, and the app offers
/// to archive anyway with `discardUncommittedChanges`. `kind` is what callers
/// branch on, never the prose.
public struct UncommittedArchiveRefusal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `git status` listed `count` changes.
        case dirty(count: Int)
        /// `git status` failed or timed out. An unreadable status is not
        /// evidence of a clean tree, so it refuses as a dirty one does.
        case unverifiable
    }

    public let kind: Kind
    public let message: String

    /// The most porcelain lines a dirty refusal lists before summarizing the
    /// rest as "… and N more".
    static let listedChangeLimit = 5

    /// The refusal for a folder at `path` whose `git status --porcelain` run
    /// produced `status`, or `nil` when the status lists nothing archiving
    /// would lose. Pure, so the wording and the line cap are unit-tested
    /// without git; `WorktreeLifecycle.uncommittedArchiveRefusal(for:)` runs
    /// the status and decides that a missing folder needs no check at all.
    public static func evaluate(
        displayName: String, path: String, status: Result<String, any Error>
    ) -> UncommittedArchiveRefusal? {
        let output: String
        switch status {
        case .failure(let error):
            return UncommittedArchiveRefusal(
                kind: .unverifiable,
                message: """
                    Could not check \(path) for uncommitted changes \
                    (\(statusFailureDetail(error))). Archiving deletes the directory.
                    """)
        case .success(let porcelain):
            output = porcelain
        }
        // Leading spaces are part of the porcelain status code (" M file"),
        // so a line is skipped only when it is blank, never trimmed.
        let changes = output.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !changes.isEmpty else { return nil }
        let shown = changes.prefix(listedChangeLimit).map { "  \($0)" }.joined(separator: "\n")
        let more = changes.count > listedChangeLimit
            ? "\n  … and \(changes.count - listedChangeLimit) more"
            : ""
        return UncommittedArchiveRefusal(
            kind: .dirty(count: changes.count),
            message: """
                \(displayName) has \(changes.count) uncommitted change(s) that archiving \
                would delete:
                \(shown)\(more)
                Commit or remove them first.
                """)
    }

    /// A one-line account of why the status could not be read. `GitError`'s
    /// own description spans lines and repeats the whole command, which reads
    /// badly inside the sentence; its exit code and stderr are what say why.
    static func statusFailureDetail(_ error: any Error) -> String {
        if let gitError = error as? GitError {
            let stderr = gitError.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git status exited \(gitError.exitCode)" + (stderr.isEmpty ? "" : ": \(stderr)")
        }
        return "\(error)"
    }
}

/// Reorders `stored` so `preferred` is first, preserving the relative order of
/// the rest. Returns `stored` unchanged when `preferred` is nil, when `stored`
/// is nil, or when `stored` does not contain `preferred`.
internal func reorderSessions(stored: [String]?, preferred: String?) -> [String]? {
    guard let preferred, let stored, stored.contains(preferred) else { return stored }
    return [preferred] + stored.filter { $0 != preferred }
}

extension WorktreeLifecycle {
    // MARK: - Archive

    /// Archives a worktree, cleaning up tmux windows and removing the git worktree.
    ///
    /// Phase 1 (fast): Validates, updates DB status, kills tmux windows.
    /// Returns the worktree and repo for phase 2.
    ///
    /// Refuses, before it changes anything, a worktree whose folder holds
    /// uncommitted changes or whose `git status` cannot be read, by throwing
    /// `WorktreeArchiveError.uncommittedChanges`. Phase 2 deletes the folder
    /// and a revive restores only the branch, so the guard lives here, where
    /// every caller passes through it: the RPC from the app and the CLI,
    /// auto-archive on merge, and any script or client that sends the RPC.
    ///
    /// - Parameters:
    ///   - worktreeID: The worktree to archive.
    ///   - force: If true, skip the active-children check, for cascade flows
    ///     like repo removal. The archive hook is phase 2's decision, made by
    ///     `completeArchiveWorktree`'s own `force`.
    ///   - discardUncommittedChanges: If true, skip the uncommitted-changes
    ///     check and archive whatever the folder holds. Off by default, so a
    ///     caller that names neither flag is guarded.
    public func beginArchiveWorktree(
        worktreeID: UUID, force: Bool = false, discardUncommittedChanges: Bool = false
    ) async throws -> (Worktree, Repo) {
        guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        if worktree.status == .main {
            throw WorktreeLifecycleError.invalidOperation("Cannot archive the main branch worktree")
        }

        // Refuse to archive a worktree whose direct children are still active
        // or being created. `force` bypasses the check for cascade flows like
        // repo deletion. Performed before any tmux/disk work.
        if !force {
            try await db.worktrees.assertArchivable(id: worktreeID)
        }

        // Split deliberately: a repo-less row and a row naming a missing repo
        // are different failures, and the combined guard reported the first as
        // the second with the worktree's own id substituted for the repo's.
        // Repo-less rows are scratch spaces; the router routes those to the
        // `scratch.*` path, so reaching this throw means an internal
        // inconsistency and the message should say which one.
        guard let rid = worktree.repoID else {
            throw WorktreeLifecycleError.worktreeHasNoRepo(worktreeID)
        }
        guard let repo = try await db.repos.get(id: rid) else {
            throw WorktreeLifecycleError.repoNotFound(rid)
        }

        // The last refusal, and the only one that runs a subprocess: after
        // the cheap DB-only guards, ahead of the branch sync, the SHA capture,
        // the status flip, the dev-server stop and the session teardown, so a
        // refused archive leaves the worktree exactly as it found it.
        if !discardUncommittedChanges,
           let refusal = await uncommittedArchiveRefusal(for: worktree) {
            archiveLogger.notice("""
                archive refused for \(worktreeID, privacy: .public) \
                (\(String(describing: refusal.kind), privacy: .public)): \
                \(refusal.message, privacy: .public)
                """)
            throw WorktreeArchiveError.uncommittedChanges(refusal)
        }

        // Collect Claude session IDs before archiving so they survive terminal deletion
        let terminals = try await db.terminals.list(worktreeID: worktreeID)
        let oldestFirst = terminals.sorted(by: { $0.createdAt < $1.createdAt })
        // Each id is resumed when the worktree is revived, so the list is what
        // `claudeResumeDecision` would let a wake resume — never a shell tab's.
        let claudeSessionIDs = oldestFirst
            .compactMap(\.claudeResumeDecision.resumableSessionID)
        // The plugin folders and settings overlay each of those sessions'
        // terminal carried, keyed by session id, so a revive restores every
        // session with its own. Read from the same terminals as the list; when
        // two terminals name one session, the oldest that carries values wins.
        let claudeSpawnExtras = Dictionary(
            oldestFirst.compactMap { terminal -> (String, ClaudeSpawnExtras)? in
                guard let sessionID = terminal.claudeResumeDecision.resumableSessionID,
                      let extras = terminal.claudeSpawnExtras?.nonEmpty else { return nil }
                return (sessionID, extras)
            },
            uniquingKeysWith: { oldest, _ in oldest })

        // Sync the branch in DB with what git reports for the worktree path,
        // so a rename done inside the worktree (e.g. `git branch -m`) is
        // captured before we lose the live worktree. Without this, revive
        // would later try to check out a stale branch that no longer exists.
        // git canonicalizes worktree paths (e.g. /var → /private/var on macOS),
        // so compare resolved-symlink forms when matching against `worktree.localPath`.
        let resolvedWtPath = (URL(fileURLWithPath: worktree.localPath).resolvingSymlinksInPath()).path
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path),
           let gitWt = gitWorktrees.first(where: {
               let resolvedGitPath = (URL(fileURLWithPath: $0.path).resolvingSymlinksInPath()).path
               return resolvedGitPath == resolvedWtPath
           }),
           !gitWt.branch.isEmpty,
           gitWt.branch != worktree.branch {
            do {
                try await db.worktrees.updateBranch(id: worktreeID, branch: gitWt.branch)
                archiveLogger.info("archive: updated branch for \(worktreeID, privacy: .public) from '\(worktree.branch, privacy: .public)' to '\(gitWt.branch, privacy: .public)' (git worktree list)")
            } catch {
                archiveLogger.warning("archive: failed to update branch for \(worktreeID, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Capture HEAD SHA from the live worktree directory while it still
        // exists on disk. Persisted as a fallback for revive when the branch
        // has been renamed or deleted.
        var capturedSHA: String? = nil
        if FileManager.default.fileExists(atPath: worktree.localPath) {
            do {
                capturedSHA = try await git.headSHA(worktreePath: worktree.localPath)
            } catch {
                archiveLogger.warning("archive: failed to capture HEAD SHA for \(worktreeID, privacy: .public) at \(worktree.localPath, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Status flip, session save, and SHA persist all in one transaction —
        // a crash mid-archive can't leave the row half-updated.
        try await db.worktrees.archive(
            id: worktreeID,
            claudeSessionIDs: claudeSessionIDs,
            claudeSpawnExtras: claudeSpawnExtras,
            archivedHeadSHA: capturedSHA
        )

        // Dev servers TBD started in its tabs stop first, while those tabs'
        // processes are alive to be signalled, and before the archive hook
        // runs. Archive can fire with no user gesture, so this only signals
        // tab process groups: no declared `stop` or `status` command runs,
        // and no pid a running file names is signalled. After the
        // status flip, so a concurrent `server.start` is
        // refused rather than racing the teardown. A failure is logged and
        // the archive continues: the tab teardown below still ends what TBD
        // started.
        await stopDevServersForArchive(worktree: worktree)

        // Capture each terminal's scrollback into Closed Terminals history,
        // then kill its tmux window, reaping any wedged agent that survives
        // kill-window's SIGHUP. The archived worktree row and its history rows
        // survive, so the captured output stays readable later.
        var sessions = SessionTeardownTally()
        for terminal in terminals {
            // A holder row takes the holder teardown instead. Its rows are
            // deleted below just as a tmux row's are, so refusing here would
            // leak rather than protect, and `captureThenKillWindow` would
            // capture, kill and reap against empty coordinates while the holder
            // and its job outlive the only record of their pids. Its Closed
            // Terminals entry is written before the disposal releases the
            // reader it is captured from.
            let stopped: Bool
            if terminal.transport == .holder {
                await Self.recordHolderClosedTerminal(
                    terminal, registry: holderRegistry, resolver: holderScreenResolver,
                    history: db.terminalHistory)
                if let failure = await disposeHolder(for: terminal) {
                    archiveLogger.warning(
                        "archive left a holder running: \(failure, privacy: .public)")
                    stopped = false
                } else {
                    stopped = true
                }
            } else {
                stopped = await captureThenKillWindow(
                    terminal: terminal, server: worktree.tmuxServer)
            }
            sessions.record(terminal, teardownStoppedIt: stopped)
        }

        // Each ended session's directory goes, draft included, unless another
        // row naming the same session may still be running. The teardown
        // above waited for each pane's process to exit, escalating to SIGKILL,
        // or SIGKILLed the holder's job. When the login shell execs Claude, as
        // zsh does for the spawn command's `-c`, that process is Claude and
        // the mod's final write on `session.end` lands before the removal;
        // otherwise a late write can recreate the directory, and `OrphanGC`'s
        // session-directory arm reclaims it after `gcGraceSeconds`.
        removeSessionDirectories(for: sessions)

        // Delete terminals from db
        try await db.terminals.deleteForWorktree(worktreeID: worktreeID)
        await sessionTitles.forget(worktreeID: worktreeID)
        try await db.tabs.deleteForWorktree(worktreeID: worktreeID)
        // No server may read *Exited* after archive.
        // A holder server's exit — including the one archive's own stop
        // caused — is stamped only while its terminal row exists, so after
        // the delete above nothing can re-attach an entry this clears.
        await detachDevServerOutputsForArchive(worktreeID: worktreeID)
        for terminal in terminals {
            await pendingQuestions.clear(terminalID: terminal.id)
            await subscriptions?.broadcastPendingPrompts(
                terminalID: terminal.id, from: pendingQuestions)
        }

        return (worktree.worktree, repo)
    }

    /// The uncommitted-changes refusal `beginArchiveWorktree` throws, or `nil`
    /// when archiving would lose nothing. A folder that is already gone has
    /// nothing to lose, so it is not checked. Otherwise this runs
    /// `GitManager.uncommittedStatus` and lets
    /// `UncommittedArchiveRefusal.evaluate` judge the output, a failed run
    /// included.
    func uncommittedArchiveRefusal(for worktree: LocalWorktree) async -> UncommittedArchiveRefusal? {
        let path = worktree.localPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let status: Result<String, any Error>
        do {
            status = .success(try await git.uncommittedStatus(worktreePath: path))
        } catch {
            status = .failure(error)
        }
        return UncommittedArchiveRefusal.evaluate(
            displayName: worktree.displayName, path: path, status: status)
    }

    /// Archive's dev-server stop, shared by `beginArchiveWorktree` and
    /// reconcile's archive of a vanished worktree: signals the process groups
    /// of servers running in TBD tabs only (no repo command runs, no running
    /// file's pid is signalled), and a server that did not stop or was left
    /// running is logged while the archive continues. A no-op when no
    /// operations are wired.
    func stopDevServersForArchive(worktree: LocalWorktree) async {
        guard let devServerOperations else { return }
        for report in await devServerOperations.stopAllForArchive(worktree: worktree)
        where !report.succeeded {
            archiveLogger.warning("""
                archive: dev server \(report.name, privacy: .public) in \
                \(worktree.id, privacy: .public) did not stop: \
                \(report.message ?? "unknown", privacy: .public)
                """)
        }
    }

    /// Archive's last dev-server step, run once the worktree's terminal rows
    /// are deleted: no saved output may make a server read *Exited* after a
    /// revive. Never throws; a no-op when no operations are wired.
    func detachDevServerOutputsForArchive(worktreeID: UUID) async {
        guard devServerOperations != nil else { return }
        await db.terminalHistory.detachAllServerOutputs(worktreeID: worktreeID)
    }

    /// Phase 2 (slow, fire-and-forget): Runs archive hook and removes git worktree.
    public func completeArchiveWorktree(worktree: Worktree, repo: Repo, force: Bool = false) async {
        // Run archive hook
        if !force {
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: worktree.localPath,
                appHookPath: worktree.repoID.map {
                    TBDConstants.hookPath(repoID: $0, eventName: HookEvent.archive.rawValue)
                }
            )
            if let hookPath = archiveHookPath {
                _ = try? await hooks.execute(
                    hookPath: hookPath,
                    cwd: worktree.localPath,
                    env: [
                        "TBD_EVENT": "archive",
                        "TBD_WORKTREE_ID": worktree.id.uuidString,
                        "TBD_WORKTREE_NAME": worktree.name,
                        "TBD_WORKTREE_PATH": worktree.localPath,
                        "TBD_REPO_PATH": repo.path,
                        "TBD_BRANCH": worktree.branch,
                    ],
                    timeout: 60
                )
            }
        }

        // Hand the directory to the deletion queue rather than removing it in
        // place. `git worktree remove` must unlink every file, which for a
        // dependency-heavy worktree runs past any subprocess deadline; when the
        // deadline killed it, the result was a half-deleted directory that was
        // still registered with git and still occupied its pool slot, while the
        // row already read `.archived`. The rename is one syscall, so the
        // archive completes regardless of tree size and the bytes are reclaimed
        // afterwards with no clock attached.
        do {
            let queued = try deletionQueue.enqueue(worktreePath: worktree.localPath)

            // The directory no longer sits at the registered path, so git's
            // administrative entry is stale — drop it. A failure here is
            // logged, not fatal: the next GC sweep prunes, because
            // `OrphanGC.pruneStaleRegistrations` looks for exactly this
            // wreckage — an archived row whose directory is gone while git
            // still lists a worktree at its path. Without that, a registration
            // outliving its directory would be permanent, since revive's
            // preflight refuses a path git still has registered.
            do {
                try await git.worktreePrune(repoPath: repo.path)
            } catch {
                archiveLogger.error("""
                archive: prune failed for \(repo.path, privacy: .public) \
                after queueing \(worktree.localPath, privacy: .public): \(error, privacy: .public)
                """)
            }

            // The rename above is the commit point (design spec "The commit
            // point"): the directory has already left its pool slot, so the
            // callback's precondition — the path is gone — holds here, before
            // the bytes are actually reclaimed by the drain below. Firing now
            // rather than after drain matches the design's ordering and keeps
            // the event-driven cleanup this callback exists to trigger — the
            // scratchpad and the composer attachments — prompt even when the
            // drain that follows is slow.
            if let onWorktreeRemoved {
                await onWorktreeRemoved(worktree.id, worktree.localPath, repo.path)
            }

            // Reclaim the bytes inline, with no deadline attached. Every
            // production caller that reaches this method through an RPC —
            // `worktree.archive`, `repo.remove`'s cascade, and auto-archive on
            // merge — invokes it from a detached task, so draining here blocks
            // nothing an RPC is waiting on. The synchronous
            // `archiveWorktree(worktreeID:)` wrapper (tests, and any
            // future CLI use) deliberately blocks until the drain finishes —
            // archive completion is meant to mean "the bytes are gone" there.
            // An interrupted drain leaves a queue entry the GC sweep finishes.
            // The unlink itself runs on the queue's own serial dispatch queue,
            // so a multi-minute removal neither holds a cooperative-pool
            // thread nor races another archive's drain for the disk.
            await deletionQueue.drain(queued)
        } catch {
            archiveLogger.error("""
            archive: could not queue \(worktree.localPath, privacy: .public) for deletion \
            (\(error, privacy: .public)) — falling back to in-place removal
            """)
            do {
                try await git.worktreeRemove(
                    repoPath: repo.path,
                    worktreePath: worktree.localPath,
                    timeout: GitManager.worktreeRemoveFallbackTimeout
                )
                // Only claim the directory is gone when it actually is. This
                // callback drives scratchpad reclamation, whose consumer
                // previously had to re-check the path itself because this
                // fired unconditionally after a swallowed failure.
                let removed = !FileManager.default.fileExists(atPath: worktree.localPath)
                if removed, let onWorktreeRemoved {
                    await onWorktreeRemoved(worktree.id, worktree.localPath, repo.path)
                }
            } catch {
                archiveLogger.error("""
                archive: in-place removal of \(worktree.localPath, privacy: .public) \
                also failed: \(error, privacy: .public) — the GC sweep will retry
                """)
            }
        }
    }

    /// Legacy all-in-one archive, used by tests. Its flags mean what
    /// `worktree.archive`'s do — `force` lifts the uncommitted-changes guard
    /// and skips the archive hook, while `discardUncommittedChanges` lifts
    /// only the uncommitted-changes guard, so the hook still runs — with one
    /// addition: `force` here also skips the active-children check, as the
    /// cascade flows do.
    public func archiveWorktree(
        worktreeID: UUID, force: Bool = false, discardUncommittedChanges: Bool = false
    ) async throws {
        let (worktree, repo) = try await beginArchiveWorktree(
            worktreeID: worktreeID, force: force,
            discardUncommittedChanges: force || discardUncommittedChanges)
        await completeArchiveWorktree(worktree: worktree, repo: repo, force: force)
    }

    // MARK: - Revive

    /// Revives an archived worktree, re-creating the git worktree and tmux windows.
    ///
    /// Legacy synchronous contract (CLI + tests): the returned worktree is
    /// fully set up and `.active`. When a `preSession` hook gates the primary
    /// terminals, this awaits the detached phase-3 task INLINE — mirroring
    /// `createWorktree`'s relationship to `completeCreateWorktree`.
    ///
    /// - Parameters:
    ///   - worktreeID: The archived worktree to revive.
    ///   - skipClaude: If true, skip launching the primary agent in the first terminal window.
    /// - Returns: The revived worktree.
    public func reviveWorktree(worktreeID: UUID, skipClaude: Bool = false, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) async throws -> Worktree {
        let completion = try await beginReviveWorktree(
            worktreeID: worktreeID, skipClaude: skipClaude,
            cols: cols, rows: rows, preferredSessionID: preferredSessionID
        )
        if case .preSessionPending(_, let phase3) = completion {
            await phase3.value
        }
        guard let revived = try await db.worktrees.getLocal(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return revived.worktree
    }

    /// Non-blocking revive. Validates, re-adds the git worktree, then:
    ///
    /// - No `preSession` hook → spawns all terminals inline, flips the row to
    ///   `.active`, and returns `.ready` (today's behavior, unchanged).
    /// - `preSession` hook resolves → spawns ONLY the hook terminal, flips the
    ///   row to `.creating` (the app gates its pre-session UI on that status),
    ///   and returns `.preSessionPending` promptly. The detached phase-3 task
    ///   awaits the hook's completion marker, spawns the primary terminals,
    ///   and finishes with `db.worktrees.revive(id:clearSessions:)` so the
    ///   archivedClaudeSessions-clearing semantics match the inline path.
    ///
    /// If the daemon restarts mid-wait, the row sits in `.creating` with a
    /// pre-session terminal record; `recoverCreatingWorktrees()` resumes the
    /// wait at next startup. The recovery sweep detects the interrupted
    /// revive (the row still carries `archivedClaudeSessions`) and resumes
    /// with revive semantics: the archived sessions are restored into
    /// terminals and the row finishes via `.revive(clearSessions: true)`.
    public func beginReviveWorktree(worktreeID: UUID, skipClaude: Bool = false, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) async throws -> WorktreeReviveCompletion {
        guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }

        guard worktree.status == .archived else {
            throw WorktreeLifecycleError.worktreeAlreadyActive(worktreeID)
        }

        // Split deliberately: a repo-less row and a row naming a missing repo
        // are different failures, and the combined guard reported the first as
        // the second with the worktree's own id substituted for the repo's.
        // Repo-less rows are scratch spaces; the router routes those to the
        // `scratch.*` path, so reaching this throw means an internal
        // inconsistency and the message should say which one.
        guard let rid = worktree.repoID else {
            throw WorktreeLifecycleError.worktreeHasNoRepo(worktreeID)
        }
        guard let repo = try await db.repos.get(id: rid) else {
            throw WorktreeLifecycleError.repoNotFound(rid)
        }

        // Create parent directory if needed
        let parentDir = (worktree.localPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // Preflight: ensure nothing exists at the target path on disk.
        if FileManager.default.fileExists(atPath: worktree.localPath) {
            throw WorktreeLifecycleError.worktreePathAlreadyExists(worktree.localPath)
        }

        // Preflight: ensure git does not already have a worktree registered at this path.
        let existing = (try? await git.worktreeList(repoPath: repo.path)) ?? []
        if existing.contains(where: { $0.path == worktree.localPath }) {
            throw WorktreeLifecycleError.worktreeAlreadyRegistered(worktree.localPath)
        }

        // Re-add the git worktree. Prefer the existing branch; fall back to
        // a new branch pointing at the captured archived HEAD SHA when the
        // branch is no longer present (renamed/deleted before archive ran).
        //
        // Both legs can fail with a directory half-written, and the recreate
        // leg is a `-b` call site: git creates the branch first and can fail
        // afterwards (a failing `post-checkout` hook leaves the branch, the
        // directory AND the worktree registration standing — verified against
        // git 2.50), so a bare rethrow leaks all three.
        let branchExists = await git.refExists(repoPath: repo.path, ref: worktree.branch)
        if branchExists {
            do {
                try await git.worktreeAddExisting(
                    repoPath: repo.path,
                    worktreePath: worktree.localPath,
                    branch: worktree.branch
                )
            } catch {
                // Directory only, and deliberately not `cleanUpFailedWorktreeAdd`.
                // This leg runs *because* the branch is already there: it checks
                // out a ref the user owns and creates nothing, so there is no
                // branch of ours to withdraw and no argument that would make
                // deleting one correct. Routing it through the shared helper —
                // treating both legs alike — is the one mistake that turns this
                // fix into data loss, so the branch-deleting code is not on this
                // path at all.
                //
                // Git also leaves the worktree registration standing here, and
                // removing the directory only turns it prunable (git 2.50).
                // It is left alone: `worktree prune` is repo-wide and drops any
                // registration whose directory is missing — including a healthy
                // worktree on an unmounted volume — so the helper runs it only
                // when it has a branch of ours to delete and git's refusal to
                // touch a claimed branch forces its hand. A retry is blocked
                // either way until the user prunes, as it was before this fix.
                try? FileManager.default.removeItem(atPath: worktree.localPath)
                throw error
            }
        } else if let sha = worktree.archivedHeadSHA, !sha.isEmpty {
            archiveLogger.info("revive: branch '\(worktree.branch, privacy: .public)' missing for \(worktreeID, privacy: .public), recreating from archived SHA \(sha, privacy: .public)")
            // Probed independently rather than reusing `branchExists`, even
            // though this leg runs only when that said "absent". `refExists` is
            // non-throwing and answers `false` for *any* failure, collapsing
            // "the branch is gone" and "the probe itself failed" into one
            // value — and telling those apart is the whole reason the cleanup
            // takes a tri-state. `localBranchExists` fails closed (only git's
            // "no such ref" exit 1 becomes `false`), so a broken probe lands on
            // `nil` and blocks deletion instead of authorizing it.
            let branchPreExisted: Bool? = try? await git.localBranchExists(
                repoPath: repo.path, name: worktree.branch
            )
            // The expected tip needs no sampling on this leg and cannot go
            // stale: `-b <branch> <sha>` points the new ref at exactly this
            // argument, so the archived SHA *is* what this attempt would have
            // put there. A branch that stands at any other commit afterwards is
            // not the one this recreate made.
            let attempted = AttemptedBranch(
                name: worktree.branch, preExisted: branchPreExisted, expectedTip: sha
            )
            do {
                try await git.worktreeAddNewBranch(
                    repoPath: repo.path,
                    worktreePath: worktree.localPath,
                    branch: worktree.branch,
                    sha: sha
                )
            } catch {
                // Removes the partial directory, then the branch `-b` made —
                // the latter only if all four of the helper's gates hold.
                await cleanUpFailedWorktreeAdd(
                    repoPath: repo.path,
                    worktreePath: worktree.localPath,
                    attempted: attempted,
                    branchNameWasAlreadyTaken: gitRefusedToCreateBranch(error)
                )
                throw error
            }
        } else {
            archiveLogger.error("revive: branch '\(worktree.branch, privacy: .public)' missing for \(worktreeID, privacy: .public) and no archivedHeadSHA — cannot recover")
            throw WorktreeLifecycleError.branchMissingNoFallback(branch: worktree.branch)
        }

        // If the caller asked to prefer a specific session, float it to the
        // front of the stored list and persist the new order so a subsequent
        // re-archive preserves last-resumed-first ordering.
        let sessions = reorderSessions(
            stored: worktree.archivedClaudeSessions,
            preferred: preferredSessionID
        )
        if let sessions, sessions != worktree.archivedClaudeSessions {
            try await db.worktrees.setArchivedClaudeSessions(id: worktreeID, sessions: sessions)
        }

        // Gated path: a preSession hook must finish before the primary
        // terminals spawn. Mirrors completeCreateWorktree's 5a branch.
        if let preSession = try await spawnPreSessionTerminal(
            worktree: worktree.worktree, repo: repo,
            worktreePath: worktree.localPath,
            cols: cols, rows: rows
        ) {
            subscriptions?.broadcast(delta: .terminalCreated(TerminalDelta(
                terminalID: preSession.terminalID,
                worktreeID: worktree.id,
                label: TerminalLabel.preSession
            )))
            // Flip to .creating AFTER the pre-session terminal exists so a
            // daemon crash in between leaves the row .archived (re-revivable)
            // rather than a terminal-less .creating row the recovery sweep
            // would discard.
            try await db.worktrees.updateStatus(id: worktreeID, status: .creating)
            let phase3 = Task.detached { [self] in
                await runPreSessionPhase3(
                    preSession: preSession,
                    worktree: worktree.worktree, repo: repo,
                    worktreePath: worktree.localPath,
                    skipClaude: skipClaude,
                    archivedClaudeSessions: sessions,
                    archivedClaudeSpawnExtras: worktree.archivedClaudeSpawnExtras,
                    cols: cols, rows: rows,
                    // Only clear archivedClaudeSessions if Claude was actually
                    // restored — otherwise preserve them so a subsequent
                    // revive (without skipClaude) can use them.
                    completionAction: .revive(clearSessions: !skipClaude)
                )
            }
            guard let pending = try await db.worktrees.getLocal(id: worktreeID) else {
                throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
            }
            return .preSessionPending(worktree: pending.worktree, phase3: phase3)
        }

        // No preSession hook → spawn all terminals inline (today's behavior).
        _ = try await spawnPrimaryTerminals(
            worktree: worktree.worktree, repo: repo,
            worktreePath: worktree.localPath,
            skipClaude: skipClaude,
            archivedClaudeSessions: sessions,
            archivedClaudeSpawnExtras: worktree.archivedClaudeSpawnExtras,
            cols: cols, rows: rows,
            preSessionTerminalID: nil
        )

        // Update status to active.
        // Only clear archivedClaudeSessions if Claude was actually restored —
        // otherwise preserve them so a subsequent revive (without skipClaude) can use them.
        try await db.worktrees.revive(id: worktreeID, clearSessions: !skipClaude)

        // Deliberate revive: disarm auto-archive AND auto-hibernate so a
        // still-merged PR doesn't immediately re-archive or re-park the
        // worktree the user just revived.
        do {
            try await db.worktrees.setAutoArchiveOnMerge(id: worktreeID, value: false)
        } catch {
            archiveLogger.warning("failed to disarm auto-archive for \(worktreeID, privacy: .public): \(error, privacy: .public)")
        }
        do {
            try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: false)
        } catch {
            archiveLogger.warning("failed to disarm auto-hibernate for \(worktreeID, privacy: .public): \(error, privacy: .public)")
        }

        // Return updated worktree
        guard let revived = try await db.worktrees.getLocal(id: worktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
        }
        return .ready(revived.worktree)
    }
}
