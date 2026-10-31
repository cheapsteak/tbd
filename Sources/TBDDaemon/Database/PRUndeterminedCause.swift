/// Why an attempt to learn a worktree's PR state produced no answer.
///
/// Deliberately a small closed vocabulary of *failure classes*, never the
/// underlying tool's message: these strings reach a tooltip, and a forge error
/// routinely names a host, an organization, a repository, or an account. A
/// class says what went wrong without carrying any of that.
enum PRUndeterminedCause {
    /// No forge CLI could be launched at all.
    static let cliUnavailable = "the forge CLI was unavailable"
    /// The CLI ran but the query did not produce an answer for this worktree.
    static let queryFailed = "the forge query failed"
    /// An answer came back in a shape this build could not read.
    static let unparseableResponse = "the forge response did not parse"
    /// Every branch this worktree is known by came back without a pull
    /// request, yet a pull request is already cached for it — so the cached one
    /// lives on a branch the query could not name (a fork head, a rename-push)
    /// and this attempt settles nothing. Not `.none`: the branch list is a
    /// guess at where to look, and its silence is not the forge saying "there
    /// is no pull request here".
    static let branchQueryFoundNothing = "no pull request was found on any branch this worktree is known by"
    /// The pull request resolved, but its check state could not be read, so the
    /// value on hand was kept rather than recomputed from partial data.
    static let checkQueryFailed = "the forge check query failed"
    /// A recorded outcome was on the row but could not be read back — a
    /// truncated or malformed blob. Not the absence of a record: an attempt was
    /// made, and only what it concluded is lost.
    static let unreadableRecord = "the recorded outcome could not be read"
    /// The CLI ran and reached the host, which refused the credentials. Named
    /// separately from `cliUnavailable` because the remedy differs: a token
    /// expired, and only re-authenticating that specific host fixes it. A
    /// personal access token has no refresh, so a host that answered yesterday
    /// starts refusing today — and letting that read as "there is no merge
    /// request here" is the silent degradation this whole vocabulary exists to
    /// prevent.
    ///
    /// The host is the one piece of forge detail this vocabulary does carry,
    /// and deliberately: the remedy is `glab auth login --hostname <host>`, so
    /// a report that withheld the host would name a fix nobody could apply.
    static func forgeAuthFailed(host: String) -> String {
        "the forge rejected the credentials for \(host)"
    }
}
