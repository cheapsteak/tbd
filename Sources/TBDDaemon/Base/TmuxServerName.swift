/// The tmux server name a repo's worktree rows carry in `tmuxServer`.
///
/// TBD starts no tmux server. The name stays on every row because a terminal
/// row still on the tmux transport is found through it: the leftover-server
/// probe connects to the socket of that name, and the app's notice names it in
/// `tmux -L <server> kill-server`. A new worktree takes the name its repo's
/// earlier worktrees have, so the column holds one value per repo.
enum TmuxServerName {
    /// `tbd-` and the low 32 bits of a djb2 hash of the repo path, in
    /// lowercase hex. djb2 rather than Swift's `Hasher`, which is seeded per
    /// process: the name has to come out the same in every daemon that ever
    /// computes it.
    static func forRepoPath(_ path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) // hash * 33 + byte
        }
        let hex = String(hash & 0xFFFFFFFF, radix: 16, uppercase: false)
        return "tbd-\(hex)"
    }
}
