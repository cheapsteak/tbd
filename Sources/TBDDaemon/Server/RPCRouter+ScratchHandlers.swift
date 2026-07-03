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
}
