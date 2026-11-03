import Foundation
import TBDShared

// Keeps the Changes list of the worktree on screen fresh, so the Changes
// toggle shows only while the worktree has changes
// (`TabRowEdgeControls.showsChanges`). Spec:
// docs/specs/2026-11-03-side-panel-toggle-pills-design.md, "The Changes pill".

// MARK: - ChangesListPollerHost

/// What `ChangesListPoller` polls: the worktrees on screen, whether each one's
/// Changes list needs reading, and the load that reads it. `AppState` is the
/// host; a test hands in its own.
@MainActor
protocol ChangesListPollerHost: AnyObject {
    /// The worktrees whose Changes toggle is on screen now.
    var changesPollWorktreeIDs: Set<UUID> { get }
    /// Whether a poll reads `worktreeID`'s Changes list now: not while the
    /// cached list is fresh, and not while a load of it is reading git.
    func changesPollNeedsLoad(worktreeID: UUID) -> Bool
    /// Reads `worktreeID`'s Changes list into the cache.
    func changesPollLoad(worktreeID: UUID) async
}

// MARK: - ChangesListPoller

/// Loads the Changes list of each worktree on screen while TBD is active:
/// when TBD becomes active (`appBecameActive`), when another worktree comes on
/// screen (`worktreesOnScreenChanged`), and every `interval` after the last
/// poll's loads finish. Each poll loads only the lists its host says need it,
/// so one the cache holds fresh is not read again, and it never starts a
/// second load of a list one of its own loads is still reading. While TBD is
/// inactive nothing polls (`appResignedActive`).
///
/// It polls only the worktrees on screen, never every worktree the window
/// keeps mounted, because the host names them from the selection rather than
/// from which views exist.
@MainActor
final class ChangesListPoller {
    /// Polled for the worktrees on screen and their loads. Weak, because the
    /// host owns this poller.
    weak var host: (any ChangesListPollerHost)?

    /// Whether TBD is active, so the poller polls.
    private var isActive = false
    /// Whether a polling loop is running: from activation to resignation.
    var isPolling: Bool { loop != nil }

    private let interval: Duration
    private let clock: any Clock<Duration>
    /// The worktrees a load this poller started is reading.
    private var loading: Set<UUID> = []
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: how long after a poll's loads finish the next poll
    ///     runs; the cache's freshness window by default, so each poll finds
    ///     the last one's lists just old enough to read again.
    ///   - clock: what the poller sleeps on.
    init(
        interval: Duration = .seconds(ChangesSnapshotCache.maxAge),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.interval = interval
        self.clock = clock
    }

    /// TBD became active: poll now, then every `interval`.
    func appBecameActive() {
        isActive = true
        restart()
    }

    /// TBD is no longer active: stop polling. A load already reading git
    /// finishes and stores its list.
    func appResignedActive() {
        isActive = false
        loop?.cancel()
        loop = nil
    }

    /// Another worktree is on screen: while TBD is active, poll now, and
    /// count the next poll's interval from this one.
    func worktreesOnScreenChanged() {
        guard isActive else { return }
        restart()
    }

    /// Replaces the polling loop with one that polls at once and then after
    /// each `interval`. A poll waits for its own loads before sleeping, so
    /// the interval runs from when they finish.
    private func restart() {
        loop?.cancel()
        let clock = clock
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let loads = self?.startLoads() else { return }
                for load in loads {
                    await load.value
                }
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Starts a load of each worktree on screen that its host says needs
    /// one and no load of this poller is reading, and returns them.
    private func startLoads() -> [Task<Void, Never>] {
        guard let host else { return [] }
        var started: [Task<Void, Never>] = []
        for worktreeID in host.changesPollWorktreeIDs
        where !loading.contains(worktreeID) && host.changesPollNeedsLoad(worktreeID: worktreeID) {
            loading.insert(worktreeID)
            started.append(Task { [weak self] in
                await self?.load(worktreeID)
            })
        }
        return started
    }

    private func load(_ worktreeID: UUID) async {
        await host?.changesPollLoad(worktreeID: worktreeID)
        loading.remove(worktreeID)
    }
}

// MARK: - AppState as the host

extension AppState: ChangesListPollerHost {
    /// The selected worktree, while exactly one with files on this machine is
    /// selected: the workspace tab bar and the side region, which draw the
    /// Changes toggle, show for a single selection only.
    var changesPollWorktreeIDs: Set<UUID> {
        guard selectedWorktreeIDs.count == 1, let worktree = selectedLocalWorktree else { return [] }
        return [worktree.id]
    }

    /// While no load of the list is reading git and the cached one is missing
    /// or old (`changesSnapshotNeedsLoad`).
    func changesPollNeedsLoad(worktreeID: UUID) -> Bool {
        !changesLoadInFlight(worktreeID: worktreeID)
            && changesSnapshotNeedsLoad(worktreeID: worktreeID, refresh: false)
    }

    /// `loadChangesSnapshot`, for the worktree if it still has files here.
    func changesPollLoad(worktreeID: UUID) async {
        guard let worktree = findWorktree(id: worktreeID).flatMap(LocalWorktree.init) else { return }
        _ = await loadChangesSnapshot(worktree: worktree)
    }
}
