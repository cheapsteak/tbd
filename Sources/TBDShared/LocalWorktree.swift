import Foundation

/// A `Worktree` proven to have files on this machine.
///
/// Local-only subsystems — terminal spawn, hibernation, archive, the file
/// viewer, reconcile — take this instead of a bare `Worktree`, so a remote row
/// cannot reach them. The guard is the compiler, not a check someone
/// remembered to write: `WorktreeStore.listLocal` simply does not return one.
///
/// Reads forward to the wrapped value through `@dynamicMemberLookup`, so
/// handler bodies keep saying `worktree.id` and `worktree.branch` unchanged.
/// Forwarding is read-only by construction; code that MUTATES a fetched row
/// reaches through `.worktree` explicitly.
@dynamicMemberLookup
public struct LocalWorktree: Equatable, Sendable {
    /// The wrapped row. Use for mutation, or to pass a bare `Worktree` on to
    /// location-neutral code.
    public let worktree: Worktree

    /// Non-optional: a `LocalWorktree` cannot exist without one.
    public let path: String

    /// Non-optional for the same reason as `path`. A remote row has no tmux
    /// server, and reconcile's canonicalization loop must never see one.
    public let tmuxServer: String

    /// Fails when the worktree is remote, or when it is local but has no
    /// directory yet (the `.creating` placeholder writes `path: ""`).
    public init?(_ worktree: Worktree) {
        // `worktree.path` becomes `worktree.localPath` when the stored path is
        // renamed — both reads below move together.
        guard worktree.location.isLocal, !worktree.path.isEmpty else { return nil }
        self.worktree = worktree
        self.path = worktree.path
        self.tmuxServer = worktree.tmuxServer
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Worktree, T>) -> T {
        worktree[keyPath: keyPath]
    }
}
