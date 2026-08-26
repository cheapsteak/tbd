import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "archivedBackfill")

/// One-shot recovery for archived worktree rows whose `branch` no longer exists
/// in the underlying repo (e.g. the user ran `git branch -m` inside the worktree
/// before archive, and the rename never made it into the DB).
///
/// Strategy: for each archived worktree, verify the branch resolves; if not,
/// mine the reflog (`git log -g --all --pretty=%H %gs`) for entries shaped like
/// `Branch: renamed refs/heads/<old> to refs/heads/<new>`. If we find a rename
/// chain and the destination branch currently exists, update the DB row to the
/// new branch and populate `archivedHeadSHA` from that branch's HEAD.
///
/// Idempotent: rows with a resolvable branch are skipped — running twice is a
/// no-op for already-fixed rows. Never deletes rows; never throws to the caller.
///
/// The pass runs *while the daemon serves RPCs* (see
/// `Daemon.startArchivedWorktreeBackfill`), so every write goes through
/// `WorktreeStore.repairArchivedBranch`, which refuses a row whose status,
/// branch or `archivedAt` no longer matches the snapshot the repair was decided
/// from, and every loop checks `Task.isCancelled` so shutdown does not have to
/// wait out the `git` subprocesses still ahead of it.
public struct ArchivedWorktreeBackfill: Sendable {
    public let db: TBDDatabase
    public let git: GitManager

    public init(db: TBDDatabase, git: GitManager) {
        self.db = db
        self.git = git
    }

    /// Run the backfill across all repos. Errors are logged, never propagated.
    public func run() async {
        let repos: [Repo]
        do {
            repos = try await db.repos.list()
        } catch {
            logger.warning("backfill: failed to list repos: \(error, privacy: .public)")
            return
        }

        for repo in repos where repo.status != .missing {
            // The pass now runs alongside a serving daemon, so a SIGTERM must
            // not have to wait out the remaining repos' `git` subprocesses.
            guard !Task.isCancelled else {
                logger.debug("backfill: cancelled before repo \(repo.displayName, privacy: .public)")
                return
            }
            await runForRepo(repo: repo)
        }
    }

    /// What one repo's pass did, in counts. Returned so tests can assert the
    /// two things the repo-wide ref map is about, neither of which shows up in
    /// the DB: that a branch the map names costs no `git` subprocess, and that
    /// a branch it does *not* name still gets a real `refExists` before the row
    /// is called broken. Nothing in production reads this.
    struct RepoPassStats: Equatable {
        /// Rows whose branch the ref map did not name, and which therefore
        /// reached a real `git rev-parse` probe.
        var refExistsProbes = 0
        /// Rows the pass judged broken and handed to `attemptRepair`.
        var repairAttempts = 0
    }

    /// Run the backfill for a single repo. `internal` so tests can drive it directly.
    @discardableResult
    func runForRepo(repo: Repo) async -> RepoPassStats {
        var stats = RepoPassStats()
        // `listLocal`, not `list`: this pass probes each row's branch against
        // the repo's checkout on THIS disk, so a remote lane — which has no
        // checkout here — is not broken, it is out of scope. Probing one would
        // classify it broken on every daemon start, and a local reflog rename
        // that happened to key on its branch name would rewrite a row that was
        // never wrong. (`limit`/`offset` are applied in SQL before the
        // location filter; this call passes neither, so that caveat is moot.)
        let archived: [LocalWorktree]
        do {
            archived = try await db.worktrees.listLocal(repoID: repo.id, status: .archived)
        } catch {
            logger.warning("backfill: failed to list archived worktrees for \(repo.displayName, privacy: .public): \(error, privacy: .public)")
            return stats
        }

        guard !archived.isEmpty else { return stats }

        // One `for-each-ref` for the whole repo, used as a fast *negative*
        // filter — never as a replacement for `refExists`. `refExists` resolves
        // a ref by git's own rules; `refTips` covers only `refs/heads` and
        // `refs/remotes/origin`. A name present in the map certainly resolves,
        // so the row is fine and costs no subprocess (the overwhelmingly common
        // case on a healthy fleet). A name *absent* from the map may still
        // resolve some other way, so it falls through to the real `refExists`
        // before the row is treated as broken — treating absence as authority
        // would reclassify rows as broken and trigger repairs that never used
        // to happen.
        //
        // A failed `refTips` leaves this nil, which degrades to exactly the
        // per-row behavior that predates it: one `refExists` per archived row.
        let tips: [String: String]?
        do {
            tips = try await git.refTips(repoPath: repo.path)
        } catch {
            logger.warning("backfill: refTips failed in \(repo.displayName, privacy: .public), falling back to per-row probes: \(error, privacy: .public)")
            tips = nil
        }

        // Lazily mine the reflog only if at least one row needs repair —
        // skip the git call entirely on the common (no-broken-rows) path.
        var renameMap: [String: String]? = nil

        logger.debug("backfill: repo=\(repo.displayName, privacy: .public) archivedCount=\(archived.count, privacy: .public)")

        for wt in archived {
            guard !Task.isCancelled else {
                logger.debug("backfill: cancelled mid-repo \(repo.displayName, privacy: .public)")
                return stats
            }
            if tips?[wt.branch] != nil { continue }
            stats.refExistsProbes += 1
            let branchOK = await git.refExists(repoPath: repo.path, ref: wt.branch)
            logger.debug("backfill:   wt=\(wt.name, privacy: .public) branch=\(wt.branch, privacy: .public) exists=\(branchOK, privacy: .public)")
            if branchOK {
                continue
            }

            // First broken row in this repo — mine the reflog now.
            if renameMap == nil {
                renameMap = await mineReflogRenames(repoPath: repo.path)
            }

            stats.repairAttempts += 1
            await attemptRepair(
                worktree: wt.worktree, repo: repo, renameMap: renameMap ?? [:], refTips: tips)
        }
        return stats
    }

    /// Repair one row. `internal` (like `runForRepo`) so tests can drive it
    /// with a deliberately stale snapshot — the race this pass has to survive
    /// now that it runs alongside a serving daemon.
    ///
    /// `refTips` is the repo-wide ref map `runForRepo` already paid for, used
    /// here on the same positive-only terms: a name found in it resolves and
    /// carries its SHA, a name absent from it falls back to `refExists` /
    /// `headSHA`. Nil means the map was unavailable and every probe is a
    /// subprocess.
    func attemptRepair(
        worktree: Worktree, repo: Repo, renameMap: [String: String],
        refTips: [String: String]? = nil
    ) async {
        // Walk the rename chain (a → b → c) until we hit a branch that no
        // longer appears as a key (i.e. the latest known name).
        var current = worktree.branch
        var visited: Set<String> = [current]
        while let next = renameMap[current], !visited.contains(next) {
            visited.insert(next)
            current = next
        }

        guard current != worktree.branch else {
            logger.warning("backfill: worktree \(worktree.id, privacy: .public) branch '\(worktree.branch, privacy: .public)' missing and no rename found in reflog")
            return
        }

        // `refs/heads/<name>` short-names to `<name>`; a remote-tracking ref
        // short-names to `origin/<name>`. `current` came out of a
        // `refs/heads/… → refs/heads/…` reflog entry, so an `origin/` prefix
        // here would mean a local branch literally named `origin/…`, whose key
        // in the map is ambiguous with the remote-tracking ref of the same
        // name. Refuse the shortcut in that case and let git answer.
        let tipSHA: String? = current.hasPrefix("origin/") ? nil : refTips?[current]
        // Spelled out rather than `tipSHA != nil || await refExists(…)`:
        // `||` takes its right operand as an autoclosure, which cannot be
        // `async`. The short-circuit is the point — a name the map already
        // resolved must not cost a subprocess.
        let newExists: Bool
        if tipSHA != nil {
            newExists = true
        } else {
            newExists = await git.refExists(repoPath: repo.path, ref: current)
        }
        guard newExists else {
            logger.warning("backfill: worktree \(worktree.id, privacy: .public) reflog suggests rename '\(worktree.branch, privacy: .public)' → '\(current, privacy: .public)' but renamed branch is also missing")
            return
        }

        // Resolve everything the write needs BEFORE touching the row, so the
        // repair lands as one compare-and-swap rather than two unguarded
        // writes. A SHA lookup that fails still must not block the branch
        // repair, so it degrades to `nil` — which the store reads as "leave
        // archivedHeadSHA alone".
        var headSHA: String? = nil
        if worktree.archivedHeadSHA == nil {
            // Populate archivedHeadSHA from the renamed branch's *current*
            // HEAD — not the commit the worktree was on at archive time, which
            // we can't recover after the fact. If the user committed on the
            // renamed branch post-archive, a later SHA-fallback revive will
            // land on the newer commit. Acceptable: the fallback only fires
            // when the branch is also gone, and a slightly newer starting point
            // beats outright failure.
            if let tipSHA {
                headSHA = tipSHA
            } else {
                do {
                    headSHA = try await git.headSHA(repoPath: repo.path, ref: current)
                } catch {
                    logger.warning("backfill: failed to resolve archivedHeadSHA for \(worktree.id, privacy: .public) (branch \(current, privacy: .public)): \(error, privacy: .public)")
                }
            }
        }

        // Re-verify the premise the repair rests on — "`worktree.branch` does
        // not resolve" — immediately before the write. Between the probe that
        // decided this row was broken and now, a revive can have recreated that
        // exact branch: `beginReviveWorktree` runs `git worktree add` on
        // `worktree.branch` at `archivedHeadSHA` while leaving the row
        // `.archived` on the old branch for the whole of its work
        // (`WorktreeLifecycle+Archive.swift`), so the CAS below sees nothing
        // amiss and would rewrite the branch out from under a live checkout.
        // One subprocess, paid only on rows that are about to be repaired.
        //
        // This narrows the window; it does not close it. The probe cannot run
        // inside the DB transaction, so a revive landing between these two
        // lines still slips through — with the row's `archivedAt` unchanged,
        // the CAS cannot see it either. What the CAS *does* close durably is
        // the aftermath: once that revive completes and the worktree is
        // archived again, `archivedAt` differs and the row is never rewritten.
        if await git.refExists(repoPath: repo.path, ref: worktree.branch) {
            logger.debug("backfill: worktree \(worktree.id, privacy: .public) branch '\(worktree.branch, privacy: .public)' resolves again (likely revived under the pass) — repair abandoned")
            return
        }

        // The snapshot this decision came from can be stale: the daemon is
        // serving, so an RPC may have revived, re-archived or deleted this row
        // since. `repairArchivedBranch` writes only if the row is still
        // archived, still carries the branch we decided to repair, and still
        // has the `archivedAt` the snapshot was taken with. Losing that race is
        // expected and costs nothing — the repair is idempotent, so the next
        // daemon start picks the row up again if it still needs one. No lock
        // and no generation column: a lock held across the pass's `git`
        // subprocesses would block exactly the RPCs this deferral exists to
        // unblock.
        let repaired: Bool
        do {
            repaired = try await db.worktrees.repairArchivedBranch(
                id: worktree.id, expectedBranch: worktree.branch,
                newBranch: current, expectedArchivedAt: worktree.archivedAt,
                archivedHeadSHA: headSHA)
        } catch {
            logger.warning("backfill: failed to update branch for \(worktree.id, privacy: .public): \(error, privacy: .public)")
            return
        }

        guard repaired else {
            logger.debug("backfill: worktree \(worktree.id, privacy: .public) no longer matches the snapshot (status, branch '\(worktree.branch, privacy: .public)', or archivedAt changed) — skipped")
            return
        }

        logger.info("backfill: repaired worktree \(worktree.id, privacy: .public) branch '\(worktree.branch, privacy: .public)' → '\(current, privacy: .public)'")
    }

    /// Parse `git log -g --all --pretty='%H %gs'` output for branch-rename
    /// entries. Returns a map from old → new branch name.
    ///
    /// Reflog message shape:
    ///   Branch: renamed refs/heads/<old> to refs/heads/<new>
    func mineReflogRenames(repoPath: String) async -> [String: String] {
        let output: String
        do {
            output = try await git.reflogAll(repoPath: repoPath)
        } catch {
            logger.warning("backfill: reflog read failed in \(repoPath, privacy: .public): \(error, privacy: .public)")
            return [:]
        }

        return Self.parseReflogRenames(output)
    }

    /// Pure parser — public for tests.
    ///
    /// The needle is case-sensitive: git's reflog message for `git branch -m`
    /// has been `"Branch: renamed ..."` (capital B) for many years, but isn't
    /// formally guaranteed. If git ever changes the message, the parser
    /// silently returns an empty map and the backfill leaves rows untouched —
    /// in line with the best-effort, never-throws contract.
    public static func parseReflogRenames(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        let prefix = "refs/heads/"
        let needle = "Branch: renamed "
        let separator = " to "

        for line in output.split(separator: "\n") {
            // Format: "<sha> Branch: renamed refs/heads/<old> to refs/heads/<new>"
            guard let renameRange = line.range(of: needle) else { continue }
            let tail = line[renameRange.upperBound...]
            guard let sepRange = tail.range(of: separator) else { continue }
            let oldRef = String(tail[..<sepRange.lowerBound])
            let newRef = String(tail[sepRange.upperBound...])
            guard oldRef.hasPrefix(prefix), newRef.hasPrefix(prefix) else { continue }
            let old = String(oldRef.dropFirst(prefix.count))
            let new = String(newRef.dropFirst(prefix.count))
            // Latest reflog entries come first; if we encounter a chain we
            // want the most recent mapping for a given key. Since we're
            // iterating top-down, only set if missing.
            if map[old] == nil {
                map[old] = new
            }
        }
        return map
    }
}
