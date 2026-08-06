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

    /// What one probe of a repo observed: the status it *should* have, and the
    /// default branch git currently reports (nil when it could not be read).
    struct Observation {
        let status: RepoStatus
        let defaultBranch: String?
    }

    /// Returns the status the repo *should* have based on filesystem reality.
    /// Does not write to the database — caller is responsible for persisting
    /// any change.
    public func validate(repo: Repo) async -> RepoStatus {
        await observe(repo: repo).status
    }

    /// The full probe. `validate` keeps its narrower signature for callers that
    /// only act on status; `validateAll` uses this one so the default branch the
    /// HEAD probe already resolved is persisted instead of discarded.
    func observe(repo: Repo) async -> Observation {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            logger.debug("Repo \(repo.displayName, privacy: .public) at \(repo.path, privacy: .public) is missing on disk")
            return Observation(status: .missing, defaultBranch: nil)
        }
        if await !git.isGitRepo(path: repo.path) {
            logger.debug("Repo \(repo.displayName, privacy: .public) at \(repo.path, privacy: .public) exists but is not a git repo")
            return Observation(status: .missing, defaultBranch: nil)
        }
        // detectDefaultBranch doubles as the HEAD-resolution probe: a repo whose
        // HEAD does not resolve is `.missing`. If this ever grows network calls
        // (e.g. ls-remote), swap to a purpose-built local-only health probe.
        let detected: String
        do {
            detected = try await git.detectDefaultBranch(repoPath: repo.path)
        } catch {
            logger.debug("Repo \(repo.displayName, privacy: .public) HEAD did not resolve: \(error.localizedDescription, privacy: .public)")
            return Observation(status: .missing, defaultBranch: nil)
        }
        return Observation(status: .ok, defaultBranch: detected)
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
            let observation = await observe(repo: repo)
            if observation.status != repo.status {
                do {
                    try await db.repos.updateStatus(id: repo.id, status: observation.status)
                    logger.info("Repo \(repo.displayName, privacy: .public) transitioned \(repo.status.rawValue, privacy: .public) → \(observation.status.rawValue, privacy: .public)")
                } catch {
                    logger.error("validateAll: failed to update status for \(repo.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            // Keep the stored default branch honest. It is best-effort at
            // `repo.add` time (detection failure falls back to "main") and goes
            // stale when a project renames its default branch — and PR matching
            // uses it to tell a tracked base from a rename-push target.
            if let detected = observation.defaultBranch, detected != repo.defaultBranch {
                do {
                    try await db.repos.updateDefaultBranch(id: repo.id, defaultBranch: detected)
                    logger.info("Repo \(repo.displayName, privacy: .public) default branch \(repo.defaultBranch, privacy: .public) → \(detected, privacy: .public)")
                } catch {
                    logger.error("validateAll: failed to update default branch for \(repo.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
