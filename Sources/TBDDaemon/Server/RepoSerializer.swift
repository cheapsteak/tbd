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
        // Prune the lane once this task finishes — but only if no later submit
        // has replaced it. Without this, `lanes` would accumulate one entry per
        // unique repoID ever seen by the daemon.
        Task { [weak self] in
            await task.value
            await self?.removeIfTail(repoID: repoID, task: task)
        }
        return task
    }

    private func removeIfTail(repoID: UUID, task: Task<Void, Never>) {
        if lanes[repoID] == task {
            lanes[repoID] = nil
        }
    }

    /// Test-only inspection: number of repos currently tracked.
    var trackedRepoCount: Int { lanes.count }

    /// Test-only: await completion of the current tail for a given repo.
    func waitForRepo(_ repoID: UUID) async {
        await lanes[repoID]?.value
    }
}
