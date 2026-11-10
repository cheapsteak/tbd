import Foundation

/// Why each of the last few `worktree.create` calls failed, by worktree id.
///
/// `worktree.create` returns its pending row at once and runs git in the
/// background, so the reason a creation failed never travels down that RPC.
/// The app hears it on the failure delta; `tbd worktree create`, which polls
/// `worktree.list` until the row turns active or disappears, asks
/// `worktree.createFailure` for it here once the row is gone.
///
/// In memory and bounded: it keeps the newest `capacity` reasons and drops the
/// oldest past that, and a daemon restart forgets them all. A CLI waiting on a
/// create asks within moments of the failure, so nothing older is worth
/// keeping, and nothing durable is created that a reconciler would have to
/// reclaim.
actor WorktreeCreateFailureLog {
    static let defaultCapacity = 64

    private let capacity: Int
    private var reasons: [UUID: String] = [:]
    /// Ids oldest first, for eviction.
    private var order: [UUID] = []

    init(capacity: Int = WorktreeCreateFailureLog.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    /// Record why `worktreeID`'s creation failed. Recording an id again
    /// replaces its reason and makes it the newest.
    func record(worktreeID: UUID, reason: String) {
        if reasons.updateValue(reason, forKey: worktreeID) != nil {
            order.removeAll { $0 == worktreeID }
        }
        order.append(worktreeID)
        while order.count > capacity {
            reasons.removeValue(forKey: order.removeFirst())
        }
    }

    /// The recorded reason, or nil when none is held for `worktreeID`.
    func reason(for worktreeID: UUID) -> String? {
        reasons[worktreeID]
    }
}
