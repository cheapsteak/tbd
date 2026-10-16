import Foundation

/// Every local branch's PR-matching facts — the branch it tracks
/// (`branch.<b>.merge`) and where it would push (`@{push}`) — read from one
/// repository in two subprocesses instead of two per branch.
///
/// Both facts belong to the repository, not to a checkout: branch config lives
/// in the common config every worktree of the repo reads, and refs are shared.
/// `RPCRouter.pollWorkingDirectory` rests remote rows on the same fact. So one
/// snapshot answers every row of a repo, and a fleet of N rows costs two
/// subprocesses per repo per cache window rather than 2N.
///
/// Two kinds of config can still differ between checkouts of one repo, and
/// `answers(checkoutAt:readIn:)` sends a row back to the per-branch reads when
/// either might reach its tracking config: a checkout's own `config.worktree`
/// (read when the repo sets `extensions.worktreeConfig`), and a conditional
/// include (`includeIf`), which git evaluates per checkout. Git writes tracking
/// config to the common file (`git push -u`, `git branch --set-upstream-to`)
/// and sparse checkout's `config.worktree` holds none, so in practice nearly
/// every row is still answered here.
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
    /// Whether every other checkout of the repo reads the tracking config this
    /// snapshot read: no conditional include is visible from the checkout it
    /// was read in, and that checkout's own `config.worktree` sets no tracking
    /// config. When false, the snapshot answers only for its own checkout.
    let holdsForOtherCheckouts: Bool

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

    /// Whether this snapshot, read in the checkout at `readPath`, answers for a
    /// row whose own checkout is `worktreePath`. It always answers for the
    /// checkout it was read in, where the per-branch reads would run too. It
    /// answers for any other checkout only when neither side may carry tracking
    /// config of its own.
    func answers(checkoutAt worktreePath: String, readIn readPath: String) -> Bool {
        if worktreePath == readPath { return true }
        return holdsForOtherCheckouts
            && !Self.checkoutMayHaveOwnTrackingConfig(worktreePath: worktreePath)
    }

    /// The config sections either fact can depend on: `branch` (`merge`,
    /// `remote`, `pushRemote`), `remote` (`push` and `fetch` refspecs,
    /// `pushDefault`), `push` (`default`), and any include, which can bring in
    /// any of them. Section names allow no escapes, so a file that sets one
    /// contains its name.
    private static let trackingConfigSections = ["branch", "remote", "push", "include"]

    /// Whether the checkout at `worktreePath` may read tracking config of its
    /// own: a `config.worktree` in its git directory that mentions any section
    /// either fact depends on. A checkout whose git directory cannot be found,
    /// or whose file cannot be read, counts as yes. A wrong yes costs that row
    /// its two per-branch reads; a wrong no costs a wrong answer.
    ///
    /// This is a plain file read, not `git config`, because it runs for every
    /// local row on every pass, and a subprocess here would spend what the
    /// snapshot saves. It reads the file whether or not the repo sets
    /// `extensions.worktreeConfig`. Git ignores the file without that setting,
    /// so a stray file costs only a fallback.
    static func checkoutMayHaveOwnTrackingConfig(worktreePath: String) -> Bool {
        guard let gitDir = gitDirectory(ofCheckoutAt: worktreePath) else { return true }
        let file = gitDir.appendingPathComponent("config.worktree").path
        guard FileManager.default.fileExists(atPath: file) else { return false }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return true }
        let lowered = text.lowercased()
        return trackingConfigSections.contains { lowered.contains($0) }
    }

    /// The git directory of the checkout at `path`: `.git` itself in a repo's
    /// main checkout, or the directory a linked worktree's `.git` file names
    /// (`gitdir: <path>`, resolved against the checkout when git wrote it
    /// relative). Nil when there is no such directory.
    static func gitDirectory(ofCheckoutAt path: String) -> URL? {
        let checkout = URL(fileURLWithPath: path, isDirectory: true)
        let dotGit = checkout.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        let gitDir: URL
        if isDirectory.boolValue {
            gitDir = dotGit
        } else {
            let prefix = "gitdir: "
            guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = contents.split(separator: "\n", maxSplits: 1).first,
                  line.hasPrefix(prefix) else {
                return nil
            }
            let target = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/")
                ? URL(fileURLWithPath: target, isDirectory: true)
                : URL(fileURLWithPath: target, isDirectory: true, relativeTo: checkout).standardizedFileURL
        }
        var gitDirIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &gitDirIsDirectory),
              gitDirIsDirectory.boolValue else {
            return nil
        }
        return gitDir
    }

    /// Parse the two reads `GitManager.branchTrackingSnapshot` runs.
    ///
    /// - Parameters:
    ///   - config: `git config -z --get-regexp '^(branch\..*\.merge|includeif\..*)$'`
    ///     — NUL-terminated records of `key` LF `value`. git prints a key's
    ///     section and variable lowercased and its subsection (the branch name)
    ///     as written, so `branch.` and `.merge` can be stripped literally and a
    ///     branch name containing dots survives. A key with no value has no LF.
    ///     git lists an `includeIf` key whether or not its condition holds in
    ///     the checkout that read it.
    ///   - refListing: `git for-each-ref --format=%(refname)%00%(push)` — one
    ///     line per ref, the ref name and its `%(push)` separated by NUL.
    ///   - readingCheckoutHasOwnTrackingConfig: `checkoutMayHaveOwnTrackingConfig`
    ///     for the checkout both reads ran in.
    static func parse(
        config: String, refListing: String, readingCheckoutHasOwnTrackingConfig: Bool = false
    ) -> BranchTrackingSnapshot {
        var mergeRefs: [String: String] = [:]
        var conditionalInclude = false
        let keyPrefix = "branch.", keySuffix = ".merge"
        for record in config.components(separatedBy: "\0") where !record.isEmpty {
            let key: Substring, value: String
            if let newline = record.firstIndex(of: "\n") {
                key = record[..<newline]
                value = String(record[record.index(after: newline)...])
            } else {
                key = Substring(record)
                value = ""
            }
            if key.hasPrefix("includeif.") {
                conditionalInclude = true
                continue
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
        return BranchTrackingSnapshot(
            mergeRefs: mergeRefs, pushRefs: pushRefs, refNames: refNames,
            holdsForOtherCheckouts: !conditionalInclude && !readingCheckoutHasOwnTrackingConfig)
    }
}
