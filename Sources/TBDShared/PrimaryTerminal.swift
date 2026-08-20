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
    /// Terminals list oldest-first and the spawn path creates the primary
    /// before the setup tab, so the first agent-kind row is it. A row with no
    /// kind recorded reads as a shell, which is what such a row is.
    public static func agent(in terminals: [Terminal]) -> Terminal? {
        terminals.first { ($0.kind ?? .shell) != .shell }
    }

    /// Whether this worktree has no primary agent **yet** and a spawn is still
    /// coming — true exactly when every row it has is the blocking `preSession`
    /// hook's tab.
    ///
    /// "Not yet" and "not ever" are opposite answers that look alike from a
    /// list of terminals, and this label is what separates them. A worktree
    /// whose `preSession` hook is still running has exactly one row — that
    /// hook's tab, created before `worktree.create` returns — and its primary
    /// agent spawns the moment the hook exits. A worktree whose spawn already
    /// happened and produced a plain shell has a row carrying no such label,
    /// and no later spawn is coming for it.
    ///
    /// An empty list is vacuously still-coming, and that is the point: it is
    /// the pre-spawn shape (and, in the app, a worktree whose terminals have
    /// not loaded yet), which wants the same answer for the same reason rather
    /// than a second rule beside this one.
    ///
    /// Keyed on the label rather than on `worktree.status == .creating`
    /// deliberately: the status is a coarser fact that also covers moments this
    /// rule should not speak about, while the label names the actual cause. The
    /// label also covers the revive path for free — a revive spawns the same
    /// hook tab ahead of the same primaries, and is still-coming for exactly
    /// the reason a create is.
    public static func spawnIsStillComing(terminals: [Terminal]) -> Bool {
        terminals.allSatisfy { $0.label == TerminalLabel.preSession }
    }
}
