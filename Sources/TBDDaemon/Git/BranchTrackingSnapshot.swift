import Foundation

/// Every local branch's PR-matching facts — the branch it tracks
/// (`branch.<b>.merge`) and where it would push (`@{push}`) — read from one
/// repository in two subprocesses instead of two per branch.
///
/// Both facts belong to the repository, not to a checkout: branch config lives
/// in the common config every worktree of the repo reads, and refs are shared.
/// `RPCRouter.pollWorkingDirectory` rests remote rows on the same fact. So one
/// snapshot answers every row of a repo, and a fleet of N rows costs two
/// subprocesses per repo per cache window rather than 2N. The exception is a
/// repo that sets `extensions.worktreeConfig` and puts branch config in one
/// worktree's `config.worktree`; git itself writes tracking config to the
/// common file (`git push -u`, `git branch --set-upstream-to`), so only a
/// hand-edited per-worktree override is read differently.
///
/// Every answer must equal the per-branch call's — `GitManager.upstreamBranchName`
/// and `GitManager.pushBranchName` — and `BranchTrackingSnapshotTests`
/// holds the two equal against real git over every branch shape the PR matcher
/// distinguishes. One step is more than a parse: `git rev-parse <b>@{push}`
/// fails when the destination's remote-tracking ref does not exist (a branch
/// configured to track a remote branch that was never fetched), while
/// `for-each-ref`'s `%(push)` names the destination anyway. So a destination
/// resolves here only when that ref appears in the same listing.
struct BranchTrackingSnapshot: Sendable, Equatable {
    /// Raw `branch.<b>.merge` value per branch name. The last value wins, as it
    /// does for `git config --get`.
    let mergeRefs: [String: String]
    /// `%(push)` per local branch name; empty when git names no destination.
    let pushRefs: [String: String]
    /// Every ref in the repository, for the existence check above.
    let refNames: Set<String>

    /// What `GitManager.upstreamBranchName` answers for `branch`.
    func upstreamBranchName(branch: String) -> String? {
        mergeRefs[branch].flatMap(GitManager.upstreamBranchName(fromMergeRef:))
    }

    /// What `GitManager.pushBranchName` answers for `branch`, given that its
    /// subprocess ran. A branch that does not exist, one with no destination,
    /// and one whose destination ref is absent all make `rev-parse` exit
    /// non-zero, which that call reads as `.noPushDestination`.
    func pushBranch(branch: String) -> GitManager.PushBranchResolution {
        guard let push = pushRefs[branch], !push.isEmpty, refNames.contains(push) else {
            return .noPushDestination
        }
        guard let name = GitManager.pushBranchShortName(fromFullRef: push) else {
            return .lookupFailed
        }
        return .resolved(name)
    }

    /// Parse the two reads `GitManager.branchTrackingSnapshot` runs.
    ///
    /// - Parameters:
    ///   - mergeConfig: `git config -z --get-regexp '^branch\..*\.merge$'` —
    ///     NUL-terminated records of `key` LF `value`. git prints a key's
    ///     section and variable lowercased and its subsection (the branch name)
    ///     as written, so `branch.` and `.merge` can be stripped literally and a
    ///     branch name containing dots survives. A key with no value has no LF.
    ///   - refListing: `git for-each-ref --format=%(refname)%00%(push)` — one
    ///     line per ref, the ref name and its `%(push)` separated by NUL.
    static func parse(mergeConfig: String, refListing: String) -> BranchTrackingSnapshot {
        var mergeRefs: [String: String] = [:]
        let keyPrefix = "branch.", keySuffix = ".merge"
        for record in mergeConfig.components(separatedBy: "\0") where !record.isEmpty {
            let key: Substring, value: String
            if let newline = record.firstIndex(of: "\n") {
                key = record[..<newline]
                value = String(record[record.index(after: newline)...])
            } else {
                key = Substring(record)
                value = ""
            }
            guard key.hasPrefix(keyPrefix), key.hasSuffix(keySuffix),
                  key.count > keyPrefix.count + keySuffix.count else { continue }
            let branch = String(key.dropFirst(keyPrefix.count).dropLast(keySuffix.count))
            mergeRefs[branch] = value
        }

        var pushRefs: [String: String] = [:]
        var refNames: Set<String> = []
        let headsPrefix = "refs/heads/"
        for line in refListing.components(separatedBy: "\n") where !line.isEmpty {
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            let refName = String(fields[0])
            guard !refName.isEmpty else { continue }
            refNames.insert(refName)
            if refName.hasPrefix(headsPrefix) {
                pushRefs[String(refName.dropFirst(headsPrefix.count))] =
                    fields.count > 1 ? String(fields[1]) : ""
            }
        }
        return BranchTrackingSnapshot(mergeRefs: mergeRefs, pushRefs: pushRefs, refNames: refNames)
    }
}
