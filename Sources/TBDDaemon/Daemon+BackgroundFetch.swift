import Foundation

/// What one repo's tick of the periodic git fetch amounted to.
enum BackgroundFetchOutcome {
    /// `git fetch origin <branch>` succeeded.
    case fetched
    /// The fetch failed and the repo has no `origin` remote at all (a
    /// legitimate local-only repo), so there was nothing to fetch.
    case skippedNoOrigin
    /// The fetch failed for any other reason; carries the fetch's own error.
    case failed(any Error)
}

extension Daemon {
    /// Runs one repo's periodic fetch and classifies the result.
    ///
    /// The remote listing runs only after a failed fetch, so healthy repos pay
    /// nothing extra. It asks git live rather than reading `repo.remoteURL`,
    /// which is captured once when the repo is added and goes stale when an
    /// `origin` is added later. If the listing itself throws, the fetch's error
    /// is reported: we could not show the repo lacks an origin.
    static func backgroundFetch(
        repoPath: String,
        branch: String,
        git: GitManager
    ) async -> BackgroundFetchOutcome {
        do {
            try await git.fetch(repoPath: repoPath, branch: branch)
            return .fetched
        } catch {
            if let remotes = try? await git.remoteNames(repoPath: repoPath),
               !remotes.contains("origin") {
                return .skippedNoOrigin
            }
            return .failed(error)
        }
    }
}
