import ArgumentParser
import Foundation

/// CLI-level position enum for `tbd worktree create --position`.
///
/// Names the new worktree's location in the worktree tree *relative to the
/// caller* (the worktree identified by `TBD_WORKTREE_ID`):
///
/// - `child` (default): the new worktree is a child of the caller. This is
///   the orchestrator-spawns-workers fan-out case.
/// - `sibling`: the new worktree is a peer of the caller (same parent).
/// - `root`: the new worktree has no parent (top-level).
///
/// This enum is purely a CLI input concept. It maps to the four
/// `WorktreeCreateParams` parenting fields the daemon already understands.
public enum WorktreePosition: String, CaseIterable, ExpressibleByArgument {
    case child
    case sibling
    case root

    /// Default value used by ArgumentParser's pretty-printed help.
    public static var defaultValueDescription: String { "child" }

    /// Resolved RPC fields for `WorktreeCreateParams`.
    public struct RPCFields: Equatable {
        public let parentWorktreeID: UUID?
        public let siblingOfWorktreeID: UUID?
        public let callerWorktreeID: UUID?
        public let suppressAutoParent: Bool?
    }

    /// Translate `(position, TBD_WORKTREE_ID)` into the four parenting fields
    /// the daemon's `ParentResolver` consumes.
    ///
    /// `child` and `sibling` are caller-relative; when the caller is unset
    /// they degrade gracefully:
    /// - `child` with no caller: passes nil for every field, so the daemon
    ///   creates a top-level worktree (same fallback as the old default).
    /// - `sibling` with no caller: there is no reference point to spawn a
    ///   peer of, so the new worktree is also created top-level (same
    ///   behavior as the old `--sibling` flag, whose `siblingOf` field was
    ///   nil and which resolved to nil in `ParentResolver`).
    public func rpcFields(callerEnvID: UUID?) -> RPCFields {
        switch self {
        case .child:
            return RPCFields(
                parentWorktreeID: nil,
                siblingOfWorktreeID: nil,
                callerWorktreeID: callerEnvID,
                suppressAutoParent: nil
            )
        case .sibling:
            return RPCFields(
                parentWorktreeID: nil,
                siblingOfWorktreeID: callerEnvID,
                callerWorktreeID: nil,
                suppressAutoParent: nil
            )
        case .root:
            return RPCFields(
                parentWorktreeID: nil,
                siblingOfWorktreeID: nil,
                callerWorktreeID: nil,
                suppressAutoParent: true
            )
        }
    }

    /// Returns a stderr warning string when the requested position cannot be
    /// fulfilled because the caller environment is missing, otherwise nil.
    ///
    /// Only `.sibling` warns: a sibling has no reference point without a
    /// caller and silently degrades to a top-level worktree, which is exactly
    /// the silent-misbehavior pattern this flag exists to prevent.
    ///
    /// `.child` and `.root` both treat "no caller" as their documented
    /// graceful fallback (top-level), so neither warns.
    public func unmetIntentWarning(callerEnvID: UUID?) -> String? {
        switch self {
        case .sibling where callerEnvID == nil:
            return "warning: --position=sibling has no caller (TBD_WORKTREE_ID unset); creating top-level worktree"
        case .child, .sibling, .root:
            return nil
        }
    }
}
