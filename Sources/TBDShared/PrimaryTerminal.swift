import Foundation

/// Which of a worktree's terminal rows is its primary agent, and whether one is
/// still on its way.
///
/// Both questions are asked on both sides of the socket: the daemon decides
/// whether a first message can be parked for a spawn that has not happened yet,
/// and the app decides whether to tell the operator that message is still
/// coming. Two copies of the rule would eventually disagree, and the shape that
/// disagreement takes is a banner promising delivery over a refusal that
/// already threw the text away — so the rule lives here, once, beside the
/// labels it reads.
public enum PrimaryTerminal {
    /// The worktree's primary agent terminal, or `nil` when none has spawned.
    ///
    /// `TerminalStore.list` returns rows oldest-first and the spawn path
    /// creates the primary before the setup tab, so the first agent-kind row is
    /// it. That ordering is the store's, not a property of any `[Terminal]` —
    /// pass a list in creation order, never one sorted into tab order. A row
    /// with no kind recorded reads as a shell, which is what such a row is.
    public static func agent(in terminals: [Terminal]) -> Terminal? {
        terminals.first { ($0.kind ?? .shell) != .shell }
    }

    /// Whether this worktree has no primary agent **yet** and a spawn is still
    /// coming — true exactly when every row it has is the blocking `preSession`
    /// hook's tab.
    ///
    /// "Not yet" and "not ever" are opposite answers that look alike from a
    /// list of terminals, and this label is what separates them. A create or a
    /// revive gated on a `preSession` hook holds exactly one row for as long as
    /// that hook runs — the hook's tab, made before the RPC returns — and its
    /// primary agent spawns the moment the hook exits. A worktree whose spawn
    /// already happened and produced a plain shell has a row carrying no such
    /// label, and no later spawn is coming for it.
    ///
    /// **Every row, not merely some row.** A hook tab can also sit *beside*
    /// live ones: a manual re-run (`worktree.rerunPreSession`) appends one to a
    /// worktree that already has its primaries, and a hook that failed or timed
    /// out keeps its tab next to the primary phase 3 then spawns anyway. Those
    /// worktrees have had their spawn — only a worktree holding nothing *but*
    /// hook tabs still has one ahead of it, which is why this reads every row
    /// rather than asking whether a hook tab is present.
    ///
    /// An empty list is vacuously still-coming, and that is the point: it is
    /// the pre-spawn shape (and, in the app, a worktree whose terminals have
    /// not loaded yet), which wants the same answer for the same reason rather
    /// than a second rule beside this one.
    ///
    /// Keyed on the label rather than on `worktree.status == .creating`
    /// deliberately: the status is a coarser fact that also covers moments this
    /// rule should not speak about, while the label names the actual cause —
    /// and it is the same fact whether a create or a revive spawned the tab.
    public static func spawnIsStillComing(terminals: [Terminal]) -> Bool {
        terminals.allSatisfy { $0.label == TerminalLabel.preSession }
    }
}
