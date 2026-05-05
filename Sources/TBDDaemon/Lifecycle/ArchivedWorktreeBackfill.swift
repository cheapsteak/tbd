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
            await runForRepo(repo: repo)
        }
    }

    /// Run the backfill for a single repo. `internal` so tests can drive it directly.
    func runForRepo(repo: Repo) async {
        let archived: [Worktree]
        do {
            archived = try await db.worktrees.list(repoID: repo.id, status: .archived)
        } catch {
            logger.warning("backfill: failed to list archived worktrees for \(repo.displayName, privacy: .public): \(error, privacy: .public)")
            return
        }

        guard !archived.isEmpty else { return }

        // Lazily mine the reflog only if at least one row needs repair —
        // skip the git call entirely on the common (no-broken-rows) path.
        var renameMap: [String: String]? = nil

        logger.debug("backfill: repo=\(repo.displayName, privacy: .public) archivedCount=\(archived.count, privacy: .public)")

        for wt in archived {
            let branchOK = await git.refExists(repoPath: repo.path, ref: wt.branch)
            logger.debug("backfill:   wt=\(wt.name, privacy: .public) branch=\(wt.branch, privacy: .public) exists=\(branchOK, privacy: .public)")
            if branchOK {
                continue
            }

            // First broken row in this repo — mine the reflog now.
            if renameMap == nil {
                renameMap = await mineReflogRenames(repoPath: repo.path)
            }

            await attemptRepair(worktree: wt, repo: repo, renameMap: renameMap ?? [:])
        }
    }

    private func attemptRepair(worktree: Worktree, repo: Repo, renameMap: [String: String]) async {
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

        let newExists = await git.refExists(repoPath: repo.path, ref: current)
        guard newExists else {
            logger.warning("backfill: worktree \(worktree.id, privacy: .public) reflog suggests rename '\(worktree.branch, privacy: .public)' → '\(current, privacy: .public)' but renamed branch is also missing")
            return
        }

        do {
            try await db.worktrees.updateBranch(id: worktree.id, branch: current)
        } catch {
            logger.warning("backfill: failed to update branch for \(worktree.id, privacy: .public): \(error, privacy: .public)")
            return
        }

        // Populate archivedHeadSHA from the renamed branch's *current* HEAD —
        // not the commit the worktree was on at archive time, which we can't
        // recover after the fact. If the user committed on the renamed branch
        // post-archive, a later SHA-fallback revive will land on the newer
        // commit. Acceptable: the fallback only fires when the branch is also
        // gone, and a slightly newer starting point beats outright failure.
        if worktree.archivedHeadSHA == nil {
            do {
                let sha = try await git.headSHA(repoPath: repo.path, ref: current)
                try await db.worktrees.updateArchivedHeadSHA(id: worktree.id, sha: sha)
            } catch {
                logger.warning("backfill: failed to populate archivedHeadSHA for \(worktree.id, privacy: .public) (branch \(current, privacy: .public)): \(error, privacy: .public)")
            }
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
