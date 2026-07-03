import Foundation
import os
import TBDShared

private let scratchLogger = Logger(subsystem: "com.tbd.daemon", category: "scratchHandlers")

extension RPCRouter {

    func handleScratchCreate(_ paramsData: Data) async throws -> RPCResponse {
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

        subscriptions.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: wt.id, repoID: nil, name: wt.name, path: wt.path, status: wt.status)))
        scratchLogger.info("scratch.create: \(wt.id, privacy: .public) at \(wt.path, privacy: .public)")
        return try RPCResponse(result: wt)
    }

    func handleScratchDelete(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ScratchDeleteParams.self, from: paramsData)
        guard let wt = try await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Scratch space not found: \(params.worktreeID)")
        }
        guard wt.isScratch else {
            return RPCResponse(error: "Not a scratch space: \(params.worktreeID)")
        }

        // Close terminals: kill tmux windows, delete terminals + tabs, clear
        // pending questions + per-session overlays (mirrors forgetWorktree).
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        for t in terminals {
            try? await tmux.killWindow(server: wt.tmuxServer, windowID: t.tmuxWindowID)
        }
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)
        try await db.tabs.deleteForWorktree(worktreeID: wt.id)
        for t in terminals {
            await pendingQuestions.clear(terminalID: t.id)
            ClaudeHookOverlay.removePerSessionOverlay(sessionKey: t.id.uuidString)
        }

        // Move the folder to Trash — never rm -rf. Promoted rows already had
        // their folder moved by promotion, so skip when promotedToRepoID != nil.
        // (promotedToRepoID is nil for every row today — Task 8 introduces
        // `scratch promote`, which will start setting it — so this branch is
        // currently dead but load-bearing once promotion lands.)
        if wt.promotedToRepoID == nil, FileManager.default.fileExists(atPath: wt.path) {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: wt.path), resultingItemURL: &resulting)
            } catch {
                scratchLogger.warning("scratch.delete: trashItem failed for \(wt.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return RPCResponse(error: "Could not move folder to Trash: \(error.localizedDescription)")
            }
        }

        try await db.worktrees.delete(id: wt.id)
        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: wt.id)))
        return .ok()
    }

    func handleScratchPromote(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ScratchPromoteParams.self, from: paramsData)
        guard let wt = try await db.worktrees.get(id: params.worktreeID) else {
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
        try await db.worktrees.setPromotedToRepoID(id: wt.id, repoID: repo.id)
        // .repoAdded (broadcast by addRepo) prompts the app to refresh state; the
        // scratch row's promotedToRepoID surfaces on the next worktree poll.
        scratchLogger.info("scratch.promote: \(wt.id, privacy: .public) -> repo \(repo.id, privacy: .public) at \(dest, privacy: .public)")
        return try RPCResponse(result: ScratchPromoteResult(
            worktreeID: wt.id, repoID: repo.id, repoPath: repo.path, repoDisplayName: repo.displayName))
    }
}
