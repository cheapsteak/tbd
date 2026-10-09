import Foundation

/// Which checkout, if any, an in-flight create has made on disk.
///
/// A create inserts its row first and runs `git worktree add` later, so when
/// the create fails the rollback sees a row and a path but cannot tell whether
/// the directory there is the one this create produced. It cannot infer it
/// either: after a name collision the checkout lives at a different path than
/// the row's, and a foreign tree may sit at the row's own path. So the create
/// records the fact when it becomes true, and the rollback reads it.
///
/// The entry is the path of the checkout, plus whether its contents came from
/// a fork's PR head, set once `git worktree add` has succeeded (on every leg)
/// and dropped when the create finishes. Rollback uses it to hand TBD's own
/// checkout back to the lifecycle as a tracked worktree rather than leave an
/// untracked tree behind.
///
/// Memory only, on purpose. After a daemon restart an interrupted create is
/// resolved by `recoverCreatingWorktrees` under its own rules, which never
/// need this.
///
/// An actor because one `WorktreeLifecycle` value is copied per call and every
/// copy must read the same entries, the same reason `conflictSweepCache` is one.
public actor CreatedCheckoutLedger {
    /// What a create made: where, and whether its contents are foreign-authored.
    public struct Checkout: Sendable, Equatable {
        public let path: String
        /// The checkout is a fork's PR head. Carried here as well as on the
        /// row because the row's own stamp is written after the checkout, by a
        /// write that can fail; a rollback must not lose the fact with it.
        public let foreignHead: Bool
    }

    private var checkouts: [UUID: Checkout] = [:]

    public init() {}

    /// Record that the create for `worktreeID` has produced a checkout at `path`.
    public func record(worktreeID: UUID, path: String, foreignHead: Bool = false) {
        checkouts[worktreeID] = Checkout(path: path, foreignHead: foreignHead)
    }

    /// Remove and return the recorded checkout, if any.
    public func take(worktreeID: UUID) -> Checkout? {
        checkouts.removeValue(forKey: worktreeID)
    }

    /// Drop the entry because the create finished and the row owns the checkout.
    public func discard(worktreeID: UUID) {
        checkouts.removeValue(forKey: worktreeID)
    }
}
