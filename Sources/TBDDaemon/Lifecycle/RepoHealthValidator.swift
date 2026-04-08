import Foundation
import os
import TBDShared

/// Validates repo health: does the path still exist, is it a git repo,
/// does HEAD resolve. Used on daemon startup and after every reconcile.
///
/// This is the recovery surface for the latent "user moved the repo on disk"
/// bug — see docs/worktree-location-design.md §4b.
public struct RepoHealthValidator: Sendable {
    private let git: GitManager
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "repoHealth")

    public init(git: GitManager) {
        self.git = git
    }

    /// Returns the status the repo *should* have based on filesystem reality.
    /// Does not write to the database — caller is responsible for persisting
    /// any change. The conductors pseudo-repo is hard-coded to `.ok` because
    /// it isn't a real git repo.
    public func validate(repo: Repo) async -> RepoStatus {
        if repo.id == TBDConstants.conductorsRepoID {
            return .ok
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            logger.debug("Repo \(repo.displayName, privacy: .public) at \(repo.path, privacy: .public) is missing on disk")
            return .missing
        }
        if await !git.isGitRepo(path: repo.path) {
            logger.debug("Repo \(repo.displayName, privacy: .public) at \(repo.path, privacy: .public) exists but is not a git repo")
            return .missing
        }
        do {
            _ = try await git.detectDefaultBranch(repoPath: repo.path)
        } catch {
            logger.debug("Repo \(repo.displayName, privacy: .public) HEAD did not resolve: \(error.localizedDescription, privacy: .public)")
            return .missing
        }
        return .ok
    }

    /// Validates every repo in the database, persisting status changes only
    /// when the value actually changes. Logs transitions at info level.
    /// Errors are swallowed and logged — this method must never throw because
    /// it is called from daemon startup and a missing repo must not block
    /// the daemon from coming up.
    public func validateAll(db: TBDDatabase) async {
        let repos: [Repo]
        do {
            repos = try await db.repos.list()
        } catch {
            logger.error("validateAll: failed to list repos: \(error.localizedDescription, privacy: .public)")
            return
        }
        for repo in repos {
            let observed = await validate(repo: repo)
            if observed != repo.status {
                do {
                    try await db.repos.updateStatus(id: repo.id, status: observed)
                    logger.info("Repo \(repo.displayName, privacy: .public) transitioned \(repo.status.rawValue, privacy: .public) → \(observed.rawValue, privacy: .public)")
                } catch {
                    logger.error("validateAll: failed to update status for \(repo.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
