import Foundation
import os
import TBDShared

extension RPCRouter {

    /// Relocate a repo to a new on-disk path.
    ///
    /// 1. Validate new path exists and is a git repo (no origin-URL check; design §6).
    /// 2. Update repo.path in the DB.
    /// 3. For every legacy worktree (path inside the OLD legacy prefix
    ///    `<oldRepo>/.tbd/worktrees/`), rewrite the recorded path to sit
    ///    under the NEW legacy prefix. The synthetic main worktree row
    ///    (status .main) gets its path updated to match the new repo root.
    /// 4. Run `git -C <new-worktree-path> worktree repair` for each non-main
    ///    worktree. If repair errors for one, mark it .failed and continue —
    ///    do NOT abort the relocate.
    /// 5. Set repo.status = .ok.
    /// 6. Broadcast a delta so the app refreshes the sidebar.
    func handleRepoRelocate(_ paramsData: Data) async throws -> RPCResponse {
        let logger = Logger(subsystem: "com.tbd.daemon", category: "repoHealth")
        let params = try decoder.decode(RepoRelocateParams.self, from: paramsData)

        guard var repo = try await db.repos.get(id: params.repoID) else {
            return RPCResponse(error: "Repository not found: \(params.repoID)")
        }

        let newPath = (params.newPath as NSString).standardizingPath

        // 1. Validate.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newPath, isDirectory: &isDir), isDir.boolValue else {
            return RPCResponse(error: "Path does not exist or is not a directory: \(newPath)")
        }
        guard await git.isGitRepo(path: newPath) else {
            return RPCResponse(error: "Not a git repository: \(newPath)")
        }

        let oldPath = repo.path
        // LEGACY-WORKTREE-LOCATION: remove after 2026-06-01
        // Reads worktrees from <repo>/.tbd/worktrees/ for backward compatibility with
        // worktrees created before the canonical-location switch. New worktrees are
        // always created under ~/tbd/worktrees/<repo>/<name>. After 2026-06-01, all
        // pre-switch worktrees will have archived naturally and this path can be deleted.
        let oldLegacyPrefix = (oldPath as NSString).appendingPathComponent(".tbd/worktrees/")
        let newLegacyPrefix = (newPath as NSString).appendingPathComponent(".tbd/worktrees/")

        // 2. Update repo.path.
        try await db.repos.updatePath(id: repo.id, path: newPath)
        repo.path = newPath

        // 3 + 4. Rewrite worktree paths and repair git bookkeeping.
        let activeWorktrees = try await db.worktrees.list(repoID: repo.id, status: .active)
        let mainWorktrees = try await db.worktrees.list(repoID: repo.id, status: .main)
        let allWorktrees = activeWorktrees + mainWorktrees

        var worktreesRepaired: [UUID] = []
        var worktreesFailed: [UUID] = []

        for wt in allWorktrees {
            // Synthetic main worktree row points at the repo root, not a real
            // git worktree dir. No `git worktree repair` needed.
            if wt.status == .main {
                if wt.path == oldPath {
                    try? await db.worktrees.updatePath(id: wt.id, path: newPath)
                }
                continue
            }

            var rewrittenPath = wt.path
            if wt.path.hasPrefix(oldLegacyPrefix) {
                let suffix = String(wt.path.dropFirst(oldLegacyPrefix.count))
                rewrittenPath = newLegacyPrefix + suffix
                try? await db.worktrees.updatePath(id: wt.id, path: rewrittenPath)
            }

            let repairedOK = await runGitWorktreeRepair(worktreePath: rewrittenPath, logger: logger)
            if repairedOK {
                worktreesRepaired.append(wt.id)
            } else {
                logger.error("git worktree repair failed for \(wt.name, privacy: .public) at \(rewrittenPath, privacy: .public); marking .failed")
                try? await db.worktrees.updateStatus(id: wt.id, status: .failed)
                worktreesFailed.append(wt.id)
            }
        }

        // 5. Reset health status.
        try await db.repos.updateStatus(id: repo.id, status: .ok)
        repo.status = .ok

        // 6. Broadcast a delta so the app refreshes. RepoDelta is the coarse
        //    refresh signal — no .repoUpdated variant exists yet.
        subscriptions.broadcast(delta: .repoAdded(RepoDelta(
            repoID: repo.id, path: repo.path, displayName: repo.displayName
        )))

        return try RPCResponse(result: RepoRelocateResult(
            repo: repo,
            worktreesRepaired: worktreesRepaired,
            worktreesFailed: worktreesFailed
        ))
    }

    /// Run `git -C <path> worktree repair`. Returns true on success.
    private func runGitWorktreeRepair(worktreePath: String, logger: Logger) async -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["git", "-C", worktreePath, "worktree", "repair"]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return true
            }
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? "<no stderr>"
            logger.error("git worktree repair (\(worktreePath, privacy: .public)) exited \(task.terminationStatus): \(err, privacy: .public)")
            return false
        } catch {
            logger.error("git worktree repair (\(worktreePath, privacy: .public)) failed to launch: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
