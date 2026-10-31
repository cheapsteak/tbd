/// Why archive refused a local worktree whose folder may hold uncommitted
/// work: what `WorktreeArchiveError.uncommittedChanges` carries.
///
/// Archiving renames the folder into the deletion queue and unlinks it, and a
/// revive rebuilds the folder from the branch, so modified tracked files and
/// untracked files that are not ignored are the one thing an archive destroys
/// for good. Committed work survives on the branch, pushed or not, which is
/// why unpushed commits are not checked. The exception is commits made inside
/// a submodule of a linked worktree: they live in
/// `<repo>/.git/worktrees/<wt>/modules/<name>`, which phase 2's
/// `git worktree prune` deletes, so they are lost unless pushed, and this
/// guard does not check for that.
///
/// `message` states the fact alone and names no remedy, because the remedy
/// differs by surface: the CLI appends its `--force` hint, and the app offers
/// to archive anyway with `discardUncommittedChanges`. `kind` is what callers
/// branch on, never the prose.
public struct UncommittedArchiveRefusal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `git status` listed `count` changes.
        case dirty(count: Int)
        /// `git status` failed or timed out. An unreadable status is not
        /// evidence of a clean tree, so it refuses as a dirty one does.
        case unverifiable
    }

    public let kind: Kind
    public let message: String
}
