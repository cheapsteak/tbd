import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Creates a test repo row in the DB and overrides its `worktreeRoot` to a
/// `.tbd/worktrees/` subdirectory of the test temp dir, so the canonical
/// layout doesn't leak into the user's real `~/tbd/worktrees/`. Returns the
/// re-fetched repo with the override applied.
public func makeTestRepo(
    db: TBDDatabase, tempDir: URL, repoDir: URL
) async throws -> Repo {
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let override = tempDir.appendingPathComponent(".tbd/worktrees").path
    try await db.repos.updateWorktreeRoot(id: repo.id, path: override)
    return try await db.repos.get(id: repo.id)!
}
