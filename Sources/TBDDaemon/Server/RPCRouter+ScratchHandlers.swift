import Foundation
import os
import TBDShared

private let scratchLogger = Logger(subsystem: "com.tbd.daemon", category: "scratchHandlers")

extension RPCRouter {

    func handleScratchCreate(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(ScratchCreateParams.self, from: paramsData)
        let fm = FileManager.default
        let base = TBDConstants.scratchDir
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        var name = (params.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = NameGenerator.generate() }
        var dir = base.appendingPathComponent(name)
        var attempts = 0
        // Regenerate on filesystem or DB-path collision.
        while true {
            let existsOnDisk = fm.fileExists(atPath: dir.path)
            let existsInDB = try await db.worktrees.findByPath(path: dir.path) != nil
            if !existsOnDisk && !existsInDB { break }
            name = NameGenerator.generate()
            dir = base.appendingPathComponent(name)
            attempts += 1
            if attempts > 50 { return RPCResponse(error: "Could not allocate a unique scratch name") }
        }
        // withIntermediateDirectories: false is deliberate: it makes this mkdir
        // fail (rather than silently no-op) if `dir` already exists, which is
        // exactly the case when a concurrent scratch.create raced us to the
        // same name — the base directory above is already guaranteed to exist,
        // so `false` here is safe. That failure surfaces before the DB insert,
        // so the loser never reaches the orphan-cleanup catch below and can
        // never delete a directory it didn't create (i.e. the race winner's).
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)

        let tmuxServer = TmuxManager.serverName(forRepoPath: base.path)
        let wt: Worktree
        do {
            wt = try await db.worktrees.createScratch(
                name: name, displayName: name, path: dir.path, tmuxServer: tmuxServer)
        } catch {
            // Don't leave an orphan directory with no DB row behind — it
            // would permanently block this name via the existsOnDisk check
            // above with nothing to show for it.
            try? fm.removeItem(at: dir)
            throw error
        }

        // The same lifecycle spawn `worktree.create` and `worktree.revive`
        // reach, so it gets the same row: one per call, naming the scratch
        // space, with no terminal (those are minted inside the spawn). The
        // folder and the DB row above are not actuations — nothing there
        // reaches a process — so the row still precedes the first acting step.
        // An unwritable record refuses the spawn and fails the call; the scratch
        // space itself stays on disk and usable, which is the same state a
        // failed spawn already leaves (add a terminal by hand).
        let actuationID = try await beginActuation(
            .scratchCreate, actor: actor,
            target: ActuationTarget(worktree: wt.id.uuidString))

        // Spawn the default primary agent terminal (Claude/Codex/shell per the
        // global primary-agent preference), mirroring what repo worktrees get on
        // creation. Best-effort: a spawn failure must not fail scratch creation —
        // the row + folder already exist and the user can add a terminal manually.
        var createdTerminals: [(id: UUID, label: String)] = []
        do {
            createdTerminals = try await lifecycle.spawnPrimaryTerminals(
                worktree: wt, repo: nil, skipClaude: false, preSessionTerminalID: nil)
            await finishActuation(actuationID, .dispatched)
        } catch {
            scratchLogger.warning("scratch.create: primary terminal spawn failed for \(wt.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // The RPC still succeeds (pre-existing contract — the row and the
            // folder exist and the user can add a terminal by hand), but the
            // record must not claim a spawn that failed inside tmux.
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
        }

        subscriptions.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: wt.id, repoID: nil, name: wt.name, path: wt.localPath, status: wt.status)))
        for terminal in createdTerminals {
            subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
                terminalID: terminal.id, worktreeID: wt.id, label: terminal.label)))
        }
        scratchLogger.info("scratch.create: \(wt.id, privacy: .public) at \(wt.localPath, privacy: .public)")
        return try RPCResponse(result: wt)
    }

    /// Close out a scratch space's terminals: kill tmux windows, delete terminals
    /// + tabs, clear pending questions + per-session overlays (mirrors
    /// forgetWorktree). Shared by `scratch.delete` and `scratch.archive` — both
    /// tear down the terminal/tab state identically before mutating the row
    /// itself (delete removes it, archive flips its status).
    ///
    /// Deliberately writes no row: both callers record one worktree-named row of
    /// their own before calling this, and a row here would double-count every
    /// teardown (the same reason `captureThenKillWindow` stays silent).
    private func closeScratchTerminals(_ wt: Worktree) async throws {
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        for t in terminals {
            try? await tmux.killWindow(server: wt.tmuxServer, windowID: t.tmuxWindowID)
        }
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)
        try await db.tabs.deleteForWorktree(worktreeID: wt.id)
        for t in terminals {
            await pendingQuestions.clear(terminalID: t.id)
            await broadcastPendingQuestions(terminalID: t.id)
            ClaudeHookOverlay.removePerSessionOverlay(sessionKey: t.id.uuidString)
        }
    }

    func handleScratchDelete(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(ScratchDeleteParams.self, from: paramsData)
        guard let wt = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Scratch space not found: \(params.worktreeID)")
        }
        guard wt.isScratch else {
            return RPCResponse(error: "Not a scratch space: \(params.worktreeID)")
        }

        // One row per call naming the scratch space, ahead of the first kill —
        // the same shape `worktree.archive` uses, and for the same reason: the
        // per-terminal kills inside the teardown are sub-steps of one intent.
        // The trashing and the row deletion below touch no process and confirm
        // nothing, so the outcome lands as soon as the teardown returns.
        let actuationID = try await beginActuation(
            .scratchDelete, actor: actor,
            target: ActuationTarget(worktree: wt.id.uuidString))
        try await actuating(actuationID) { try await closeScratchTerminals(wt.worktree) }
        await finishActuation(actuationID, .dispatched)

        // Move the folder to Trash — never rm -rf. Promoted rows already had
        // their folder moved by promotion (handleScratchPromote sets
        // promotedToRepoID when it retires the row), so skip the trash for
        // them: `wt.path` now names the promoted repo's location and trashing
        // it would delete the user's real repo.
        if wt.promotedToRepoID == nil, FileManager.default.fileExists(atPath: wt.path) {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: wt.path), resultingItemURL: &resulting)
            } catch {
                scratchLogger.warning("scratch.delete: trashItem failed for \(wt.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return RPCResponse(error: "Could not move folder to Trash: \(error.localizedDescription)")
            }
        }

        // The folder at `wt.path` is now gone — trashed just above, already
        // relocated by promotion (skip-trash branch), or never existed — so
        // this is the last moment anything can attribute a leftover Claude
        // Code scratchpad to this row: once it's deleted below, the sweep's
        // reconciliation has no path left to resolve it by. Scratch spaces
        // have no owning repo, so repoPath is "" — the same
        // unresolvable-repo convention `OrphanGC`'s own reconciliation uses.
        // `scratchpadCleanup` re-verifies the directory is gone and is
        // gated by `gcEnabled` internally, so this is safe to call
        // unconditionally.
        if let orphanGC {
            await orphanGC.scratchpadCleanup(forRemovedWorktreePath: wt.path, repoPath: "")
        }

        // Hard delete: closed-terminal history (rows + captured files) goes
        // too. Archive (below) deliberately keeps it.
        try? await db.terminalHistory.deleteForWorktree(worktreeID: wt.id)
        try await db.worktrees.delete(id: wt.id)
        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: wt.id)))
        return .ok()
    }

    /// Archive a scratch space: close its terminals (same teardown as delete)
    /// and flip its status to `.archived`, but leave the folder on disk —
    /// unlike delete, nothing is moved to Trash.
    func handleScratchArchive(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(ScratchArchiveParams.self, from: paramsData)
        return try await archiveScratchSpace(
            worktreeID: params.worktreeID, surface: .scratchArchive, actor: actor)
    }

    /// The body of `scratch.archive`, shared with `worktree.archive`'s scratch
    /// branch (`handleWorktreeArchive`). Extracted rather than duplicated so
    /// the two RPC doors share one implementation: the repo-worktree archive
    /// path must never run against a scratch space, because its phase 2
    /// removes the directory. (`DeskSessionManager.closeDeskSession` still
    /// carries a third, drifted copy of this teardown; folding it in is
    /// tracked separately.)
    ///
    /// `surface` is the door the request came through, so the actuation row
    /// records the method the caller actually called. Both surfaces carry the
    /// same `kind` (`.dispose`), so this needs no `ActuationBranch`: the act is
    /// identical and only the door differs.
    func archiveScratchSpace(
        worktreeID: UUID, surface: ActuationSurface, actor: ActuationActor?
    ) async throws -> RPCResponse {
        guard let wt = try await db.worktrees.getLocal(id: worktreeID) else {
            return RPCResponse(error: "Scratch space not found: \(worktreeID)")
        }
        guard wt.isScratch else {
            return RPCResponse(error: "Not a scratch space: \(worktreeID)")
        }

        // The Watch Desk is a scratch row (`isNightwatchDesk` is `isScratch`
        // plus its display name), so the routing above reaches it. Its teardown
        // is not this one: `DeskSessionManager.closeDeskSession` also clears the
        // in-memory desk pointer and is paired with `releaseJudgeLease`, which
        // drops the lease row and unlinks the lease credential file. Neither
        // resource has a reconciler, so retiring the desk through the generic
        // body would leak both with nothing to reclaim them. Refused rather
        // than half-torn-down.
        guard !wt.isNightwatchDesk else {
            return RPCResponse(
                error: "This is the Nightwatch Watch Desk; it is retired by the desk's own "
                    + "teardown, not by archiving. Stop the desk instead.")
        }

        // Idempotent on an already-archived row, and deliberately not a
        // re-archive: `WorktreeStore.archive` re-stamps `archivedAt`
        // unconditionally, and that timestamp is the GC grace clock
        // `OrphanProcessCollector` reaps from. A *sequential* retry (a hook
        // firing twice, a sweep re-issuing the call, a user repeating it) would
        // otherwise push the reap of a wedged agent out by another
        // `gcGraceSeconds` each time, and re-broadcast an archive delta for a
        // row every client has already filed away.
        //
        // This is a read in its own transaction, so it does not close the
        // window where two calls overlap in flight; the durable fix is a status
        // check inside `WorktreeStore.archive`'s write block beside the
        // `.main`/`.creating` refusals, which would cover the repo path and the
        // direct callers (reconcile, the Watch Desk) at the same time.
        guard wt.status != .archived else {
            scratchLogger.info(
                "\(surface.method, privacy: .public): \(wt.id, privacy: .public) is already archived; no-op")
            return .ok()
        }

        // The same refusal the repo path gives, and for the same reason: a
        // scratch space CAN be a parent. `ParentResolver`'s `caller` arm
        // rejects only `.main` and `.archived`, so `tbd worktree new` run from
        // inside a scratch space mints a repo worktree whose
        // `parentWorktreeID` is this row, and `worktree.move` permits the same
        // by hand. Archiving the parent out from under a live child leaves the
        // child rendering nowhere until reconcile nulls the pointer.
        //
        // Unconditional, and deliberately NOT gated on the caller's `force`:
        // `handleWorktreeArchive` does not forward `force` to
        // `beginArchiveWorktree` either, so this assertion always runs for a
        // repo worktree arriving through the same door. `force` bypasses it
        // only for the in-process cascade flows that call the lifecycle
        // directly (`repo.remove`), and no cascade reaches a repo-less row.
        // Honouring `force` here would have made one flag mean opposite things
        // on the two branches of one RPC.
        try await db.worktrees.assertArchivable(id: worktreeID)

        // Same teardown as `scratch.delete`, so the same row: one per call,
        // worktree-named, written before the first kill.
        let actuationID = try await beginActuation(
            surface, actor: actor,
            target: ActuationTarget(worktree: wt.id.uuidString))
        try await actuating(actuationID) { try await closeScratchTerminals(wt.worktree) }
        await finishActuation(actuationID, .dispatched)
        try await db.worktrees.archive(id: wt.id)

        // Same delta `scratch.delete` broadcasts — deliberate: from the
        // client's perspective the row leaves the active section identically
        // whether archived or deleted.
        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: wt.id)))
        scratchLogger.info(
            "\(surface.method, privacy: .public): \(wt.id, privacy: .public) at \(wt.path, privacy: .public)")
        return .ok()
    }

    /// Revive an archived scratch space: flip its status back to `.active`.
    /// Requires the folder to still exist on disk — scratch spaces have no
    /// git-worktree machinery to recreate a missing directory, unlike
    /// repo-scoped revive.
    func handleScratchRevive(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ScratchReviveParams.self, from: paramsData)
        switch try await reviveScratchSpace(worktreeID: params.worktreeID) {
        case .revived:
            // `scratch.revive`'s result shape is unchanged: its GUI caller
            // refreshes from the delta rather than reading a returned row.
            return .ok()
        case .refused(let message):
            return RPCResponse(error: message)
        }
    }

    /// Outcome of `reviveScratchSpace`. The two callers disagree on the
    /// success payload: `scratch.revive` answers `.ok()`, while
    /// `worktree.revive` must answer with the row, because both its CLI and
    /// its app client decode a `Worktree` from the result. So the shared
    /// helper hands back the row and lets each caller shape its response.
    enum ScratchReviveOutcome {
        case revived(Worktree)
        case refused(String)
    }

    /// The body of `scratch.revive`, shared with `worktree.revive`'s scratch
    /// branch (`handleWorktreeRevive`).
    func reviveScratchSpace(
        worktreeID: UUID, method: String = RPCMethod.scratchRevive
    ) async throws -> ScratchReviveOutcome {
        guard let wt = try await db.worktrees.getLocal(id: worktreeID) else {
            return .refused("Scratch space not found: \(worktreeID)")
        }
        guard wt.isScratch else {
            return .refused("Not a scratch space: \(worktreeID)")
        }
        // The mirror of the archive guard, and the reason it has to exist
        // separately: `DeskSessionManager.closeDeskSession` archives the desk's
        // row through `db.worktrees.archive` directly, changing neither
        // `repoID` nor the display name, so the archived row still satisfies
        // `isNightwatchDesk` and passes every other guard below. Reviving it
        // here would flip it `.active` and broadcast a revive while the desk
        // actor's in-memory pointer, judge lease row, lease credential file and
        // terminals stay gone: an active desk with nothing behind it.
        //
        // Refusing costs nothing, because nothing legitimately revives a desk
        // row. `ensureDeskSession`'s recovery path excludes archived worktrees
        // deliberately, so the desk mints a fresh session instead.
        guard !wt.isNightwatchDesk else {
            return .refused(
                "This is the Nightwatch Watch Desk; it is not revived by hand. The desk opens a "
                    + "fresh session itself when it next runs.")
        }
        guard wt.status == .archived else {
            return .refused("Scratch space is already active: \(wt.id)")
        }
        // A promoted row is retired, not archived-and-revivable: promotion sets
        // `promotedToRepoID` and leaves `repoID` NULL, so `isScratch` and the
        // status check both still pass and only the stale `wt.path` (whose
        // folder promotion moved away) incidentally stops this today. Both
        // sibling verbs guard on it explicitly (`scratch.promote` refuses a
        // second promotion, `scratch.delete` skips the trash), so revive does
        // too, rather than resting on a filesystem coincidence that anything
        // recreating the old directory would undo.
        guard wt.promotedToRepoID == nil else {
            return .refused("Scratch space was promoted to a repo and cannot be revived: \(wt.id)")
        }
        guard FileManager.default.fileExists(atPath: wt.path) else {
            return .refused("Scratch directory missing on disk: \(wt.path)")
        }

        try await db.worktrees.revive(id: wt.id)

        // Re-read BEFORE broadcasting, and return the stored row rather than a
        // mutated snapshot: the caller that answers with a row must answer with
        // the post-revive `status`/`archivedAt`, and the store owns how those
        // are cleared. Ordering it ahead of the broadcast keeps the one
        // mutating failure honest: if a concurrent delete removed the row, no
        // subscriber is told the revive happened before the caller is told it
        // did not.
        guard let revived = try await db.worktrees.get(id: wt.id) else {
            return .refused("Scratch space vanished while reviving: \(wt.id)")
        }

        subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
            worktreeID: wt.id, repoID: nil, name: wt.name, path: wt.path)))
        scratchLogger.info(
            "\(method, privacy: .public): \(wt.id, privacy: .public) at \(wt.path, privacy: .public)")
        return .revived(revived)
    }

    func handleScratchPromote(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ScratchPromoteParams.self, from: paramsData)
        guard let wt = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Scratch space not found")
        }
        guard wt.isScratch else { return RPCResponse(error: "Not a scratch space") }
        guard wt.promotedToRepoID == nil else { return RPCResponse(error: "Scratch space already promoted") }

        let fm = FileManager.default
        let dest = (params.destPath as NSString).standardizingPath

        // Reject a dest inside TBD's own scratch area — same canonicalization
        // + boundary check as the repo.add scratch guard (Task 7), so a
        // symlink can't be used to bypass it either.
        let canonDest = URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
        let canonScratchBase = URL(fileURLWithPath: TBDConstants.scratchDir.path).resolvingSymlinksInPath().path
        guard canonDest != canonScratchBase, !canonDest.hasPrefix(canonScratchBase + "/") else {
            return RPCResponse(error: "Destination is inside TBD's scratch area. Choose a location outside \(TBDConstants.scratchDir.path).")
        }

        guard !fm.fileExists(atPath: dest) else { return RPCResponse(error: "Destination already exists: \(dest)") }
        guard fm.fileExists(atPath: wt.path) else { return RPCResponse(error: "Scratch directory missing on disk: \(wt.path)") }
        guard await git.isGitRepo(path: wt.path) else {
            return RPCResponse(error: "Scratch space is not a git repository. Run `git init` and commit before promoting.")
        }
        guard await git.hasCommits(path: wt.path) else {
            return RPCResponse(error: "Scratch space has no commits. Commit your work before promoting.")
        }

        // Move the folder (same-volume rename keeps the running cwd valid).
        do {
            try fm.createDirectory(at: URL(fileURLWithPath: dest).deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(atPath: wt.path, toPath: dest)
        } catch {
            return RPCResponse(error: "Failed to move scratch space to \(dest): \(error.localizedDescription)")
        }

        // Display-name priority: explicit flag > renamed-scratch-name > folder name.
        let displayNameOverride: String?
        if let explicit = params.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            displayNameOverride = explicit
        } else if !wt.hasDefaultDisplayName {   // reuse stop-rename-check's default detection
            displayNameOverride = wt.displayName
        } else {
            displayNameOverride = nil
        }

        let repo: Repo
        do {
            repo = try await addRepo(path: dest, displayNameOverride: displayNameOverride)
        } catch {
            // The folder already moved but registration failed — best-effort
            // move it back so the row (still un-promoted) and the filesystem
            // agree on where the scratch space lives. If even that fails, the
            // error says exactly where the folder ended up so it isn't lost.
            do {
                try fm.moveItem(atPath: dest, toPath: wt.path)
                return RPCResponse(error: "Failed to register \(dest) as a repo: \(error.localizedDescription). Moved the folder back to \(wt.path); nothing was promoted.")
            } catch let moveBackError {
                scratchLogger.error("scratch.promote: move-back failed after addRepo failure for \(wt.id, privacy: .public): \(moveBackError.localizedDescription, privacy: .public)")
                return RPCResponse(error: "Failed to register \(dest) as a repo: \(error.localizedDescription). The folder could NOT be moved back to \(wt.path) (\(moveBackError.localizedDescription)) — it currently still lives at \(dest); the scratch row was not marked promoted.")
            }
        }
        // ---- Metadata migration (DB rows + project-dir snapshot only) ----
        // The promote RPC is typically issued BY a live Claude session running
        // in one of this scratch space's panes; the folder move above is a
        // same-volume rename so those processes keep working. Everything below
        // must therefore never suspend/kill/respawn a session and never
        // rewrite a live terminal's transcriptPath — it only re-points DB rows
        // and copies files.
        let migratedTerminals = try await db.terminals.list(worktreeID: wt.id)
        // addRepo just created the repo's main worktree; fetch it. Defensive
        // guard only — addRepo unconditionally calls createMain, so the else
        // branch is unreachable short of DB corruption.
        if let mainWorktree = try await db.worktrees.listLocal(repoID: repo.id, status: .main).first {
            // ALL row mutations in ONE transaction (terminals re-parented, tab
            // state migrated, main worktree inheriting the scratch tmux server
            // so the live panes stay reachable, scratch row retired with its
            // promotion pointer). A mid-sequence failure rolls everything back
            // — the scratch row stays un-promoted and retryable, and no
            // half-migrated state can leave `scratch.delete` free to tmux-kill
            // live un-reparented terminals.
            do {
                if let failureHook = scratchPromoteMigrationFailureHook { try await failureHook() }
                try await db.worktrees.promoteScratchMigration(
                    scratchID: wt.id,
                    mainWorktreeID: mainWorktree.id,
                    repoID: repo.id,
                    tmuxServer: wt.tmuxServer
                )
            } catch {
                scratchLogger.error("scratch.promote: row migration failed for \(wt.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // The migration transaction itself rolled back atomically (the
                // scratch row is still active + un-promoted, terminals still
                // parented to it — see promoteScratchMigration). But two non-DB
                // side effects already happened: the folder moved to `dest` and
                // addRepo registered it. Mirror the addRepo-failure branch
                // above and undo both — otherwise a retry trips the
                // "Destination already exists" guard against a half-promoted
                // repo whose scratch row points at a dead path.
                //
                // Unregister first: addRepo created exactly a repo row plus its
                // synthetic main worktree row, so tear down both (the same
                // store calls handleRepoRemove uses) before touching the
                // filesystem.
                var unregisterError: (any Error)?
                do {
                    try await db.worktrees.deleteForRepo(repoID: repo.id)
                    try await db.repos.remove(id: repo.id)
                    subscriptions.broadcast(delta: .repoRemoved(RepoIDDelta(repoID: repo.id)))
                } catch let repoRemoveError {
                    unregisterError = repoRemoveError
                    scratchLogger.error("scratch.promote: could not unregister repo \(repo.id, privacy: .public) after migration failure: \(repoRemoveError.localizedDescription, privacy: .public)")
                }
                let repoNote = unregisterError.map {
                    " The repo registration at \(dest) could NOT be removed (\($0.localizedDescription)) — remove it manually with `tbd repo remove`."
                } ?? " Unregistered the repo again."
                do {
                    try fm.moveItem(atPath: dest, toPath: wt.path)
                    return RPCResponse(error: "Migrating the scratch space's sessions failed: \(error.localizedDescription).\(repoNote) Moved the folder back to \(wt.path); the scratch row and its terminals were left unchanged, so promoting again is safe.")
                } catch let moveBackError {
                    scratchLogger.error("scratch.promote: move-back failed after migration failure for \(wt.id, privacy: .public): \(moveBackError.localizedDescription, privacy: .public)")
                    return RPCResponse(error: "Migrating the scratch space's sessions failed: \(error.localizedDescription).\(repoNote) The folder could NOT be moved back to \(wt.path) (\(moveBackError.localizedDescription)) — it currently still lives at \(dest); the scratch row was not marked promoted.")
                }
            }
            // File copies stay OUTSIDE the transaction: idempotent
            // copy-if-newer snapshots, safe to redo and useless to roll back.
            await migrateClaudeProjectDirs(
                oldPath: wt.path, newPath: repo.path, terminals: migratedTerminals)

            // .repoAdded was already broadcast by addRepo. Announce the moved
            // terminals under their new worktree, then the scratch row's exit
            // from the active section — same delta scratch.archive/delete use.
            for terminal in migratedTerminals {
                subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
                    terminalID: terminal.id, worktreeID: mainWorktree.id, label: terminal.label)))
            }
            subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: wt.id)))
        } else {
            // Set the promotion pointer even though nothing migrated: the
            // folder DID move and the repo IS registered, so the row must not
            // be promotable again (and scratch.delete must not trash the
            // moved folder).
            try await db.worktrees.setPromotedToRepoID(id: wt.id, repoID: repo.id)
            scratchLogger.error("scratch.promote: no main worktree found for repo \(repo.id, privacy: .public) — terminals left on scratch row \(wt.id, privacy: .public)")
        }

        scratchLogger.info("scratch.promote: \(wt.id, privacy: .public) -> repo \(repo.id, privacy: .public) at \(dest, privacy: .public)")
        return try RPCResponse(result: ScratchPromoteResult(
            worktreeID: wt.id, repoID: repo.id, repoPath: repo.path, repoDisplayName: repo.displayName))
    }

    /// Snapshot the promoted scratch space's Claude project directories into
    /// the new path's derived directories. For every projects root involved —
    /// the ambient host claude dir plus each distinct terminal profile's config
    /// dir — copy the OLD munged dir's contents (session JSONLs,
    /// `<id>/subagents/`, `memory/`, …) into the NEW munged dir with
    /// copy-if-newer semantics, so `claude --resume` under the new cwd finds
    /// the conversations. Best-effort by design: live sessions keep appending
    /// to their old transcript files, and the lazy Stop-hook / pre-resume sync
    /// converges anything written after this snapshot.
    private func migrateClaudeProjectDirs(
        oldPath: String, newPath: String, terminals: [Terminal]
    ) async {
        var roots: [URL] = []
        var seen = Set<String>()
        func addRoot(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { roots.append(url) }
        }
        addRoot(configDirManager.ambientConfigDirectory
            .appendingPathComponent("projects", isDirectory: true))
        for terminal in terminals {
            guard let profileID = terminal.profileID else { continue }
            addRoot(configDirManager.configDirectory(forProfileID: profileID)
                .appendingPathComponent("projects", isDirectory: true))
        }
        // Detached: both the resolve (content scans) and the recursive copy
        // are synchronous filesystem walks that must not block this handler's
        // executor; the await preserves ordering for the caller.
        await Task.detached {
            for root in roots {
                guard let oldDir = ClaudeProjectDirectory.resolve(
                    worktreePath: oldPath, projectsBase: root) else { continue }
                let newDir = TranscriptProjectDirSync.derivedProjectDir(
                    worktreePath: newPath, projectsRoot: root)
                TranscriptProjectDirSync.syncDirectoryContents(from: oldDir, to: newDir)
                scratchLogger.info("scratch.promote: snapshotted Claude project dir \(oldDir.path, privacy: .public) -> \(newDir.path, privacy: .public)")
            }
        }.value
    }
}
