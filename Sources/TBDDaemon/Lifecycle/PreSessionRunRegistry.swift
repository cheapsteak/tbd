import Foundation

/// Tracks which worktrees currently have a `preSession` hook run in flight.
///
/// `WorktreeLifecycle` is a struct, so this must be a reference type for every
/// copy of the struct to share one set — the same reasoning as
/// `ConflictSweepCache`.
///
/// Deliberately daemon-local and NOT mirrored into app state. After the hook
/// tab became ephemeral-on-success, a lingering `pre-session` tab means "the
/// last run failed", not "a run is in progress", so the app cannot infer
/// running-ness from the tab it already tracks. Surfacing this would need a new
/// `StateDelta` case plus a transient worktree-snapshot field to survive an app
/// relaunch mid-run — real state-sync plumbing for a grey menu row the user
/// would rarely see. The RPC rejects the second run with a clear message instead.
public actor PreSessionRunRegistry {
    private var inFlight: Set<UUID> = []

    public init() {}

    /// Claims `id`. Returns false when a run is already in flight for it.
    public func begin(_ id: UUID) -> Bool {
        inFlight.insert(id).inserted
    }

    /// Releases the claim. Idempotent.
    public func end(_ id: UUID) {
        inFlight.remove(id)
    }

    public func isRunning(_ id: UUID) -> Bool {
        inFlight.contains(id)
    }
}
