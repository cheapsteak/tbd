import Foundation

/// Serializes per-repo background work so concurrent `git fetch` / `git worktree add`
/// invocations don't queue on git's `.git/index.lock`. Different repos still run
/// in parallel; each repo gets a chained `Task` lane that awaits its predecessor
/// before invoking the next body.
public actor RepoSerializer {
    private var lanes: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Schedule `work` to run after any in-flight work for `repoID` completes.
    /// Returns immediately with the chained task; callers normally don't await it.
    @discardableResult
    public func submit(repoID: UUID, work: @Sendable @escaping () async -> Void) -> Task<Void, Never> {
        let predecessor = lanes[repoID]
        let task = Task { [predecessor] in
            await predecessor?.value
            await work()
        }
        lanes[repoID] = task
        return task
    }

    /// Test-only inspection: number of repos currently tracked.
    var trackedRepoCount: Int { lanes.count }

    /// Test-only: await completion of the current tail for a given repo.
    public func waitForRepo(_ repoID: UUID) async {
        await lanes[repoID]?.value
    }
}
