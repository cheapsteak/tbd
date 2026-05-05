import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Repos")

extension AppState {
    // MARK: - Repo Actions

    /// Add a repository by path.
    func addRepo(path: String) async {
        do {
            let repo = try await daemonClient.addRepo(path: path)
            repos.append(repo)
            isConnected = true
        } catch {
            logger.error("Failed to add repo: \(error)")
            handleConnectionError(error)
        }
    }

    /// Remove a repository.
    func removeRepo(repoID: UUID, force: Bool = false) async {
        do {
            try await daemonClient.removeRepo(repoID: repoID, force: force)
            repos.removeAll { $0.id == repoID }
            worktrees.removeValue(forKey: repoID)
        } catch {
            logger.error("Failed to remove repo: \(error)")
            handleConnectionError(error)
        }
    }

    /// Relocate a repository to a new on-disk path.
    func relocateRepo(id: UUID, newPath: String) async {
        do {
            let result = try await daemonClient.relocateRepo(repoID: id, newPath: newPath)
            if !result.worktreesFailed.isEmpty {
                logger.warning("Relocate completed with \(result.worktreesFailed.count, privacy: .public) worktree(s) failed to repair")
                alertMessage = "Relocated, but \(result.worktreesFailed.count) worktree(s) failed to repair. Check the daemon log for details."
                alertIsError = true
            }
            await refreshRepos()
        } catch {
            logger.error("Failed to relocate repo: \(error)")
            // Surface the failure so the user knows why the repo is still dimmed
            // (e.g. they picked a directory that isn't a git repo).
            alertMessage = "Couldn't relocate repo: \(error.localizedDescription)"
            alertIsError = true
            handleConnectionError(error)
        }
    }

    /// Rename a repo's display name. Updates local state optimistically before issuing the RPC.
    func renameRepo(id: UUID, displayName: String) async {
        if let idx = repos.firstIndex(where: { $0.id == id }) {
            var repo = repos[idx]
            repo.displayName = displayName
            repos[idx] = repo
        }
        do {
            try await daemonClient.renameRepo(id: id, displayName: displayName)
        } catch {
            logger.error("Failed to rename repo: \(error)")
            handleConnectionError(error)
        }
    }

    /// Update per-repo instruction fields. Returns true on success.
    @discardableResult
    func updateRepoInstructions(repoID: UUID, renamePrompt: String?, customInstructions: String?) async -> Bool {
        do {
            _ = try await daemonClient.repoUpdateInstructions(
                repoID: repoID, renamePrompt: renamePrompt, customInstructions: customInstructions
            )
            await refreshRepos()
            return true
        } catch {
            logger.error("Failed to update instructions: \(error)")
            handleConnectionError(error)
            return false
        }
    }
}
