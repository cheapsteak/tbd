import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "cloneCheckout")

extension WorktreeLifecycle {
    /// The fresh-create leg's `git worktree add --no-track <path> -b <branch>
    /// <base>`, routed through `CheckoutTemplateStore` while
    /// `clone_checkout_enabled` is on (default off, soaking).
    ///
    /// Either way the result is the same worktree: its own branch at the
    /// base, its own HEAD and index, a clean `git status`, and the
    /// `post-checkout` hook run once. With the flag on, files that also exist
    /// unchanged in the repo's template share its disk blocks instead of being
    /// written again. The flag is read on every call, so a change takes effect
    /// at the next create.
    ///
    /// Only the fresh-create path is routed here. Existing-branch, remote
    /// tracking, fork-PR and revive checkouts keep their plain `worktree add`.
    ///
    /// Returns how the store populated the worktree, or nil when the flag is
    /// off and the plain `worktreeAdd` ran.
    @discardableResult
    func addFreshWorktree(
        repo: Repo, worktreePath: String, branch: String, baseBranch: String
    ) async throws -> CheckoutTemplateStore.Outcome? {
        let enabled = (try? await db.config.get().cloneCheckoutEnabled) ?? Config.cloneCheckoutDefault
        guard enabled else {
            try await git.worktreeAdd(
                repoPath: repo.path, worktreePath: worktreePath, branch: branch, baseBranch: baseBranch)
            return nil
        }

        let outcome = try await checkoutTemplates.addWorktree(
            git: git, repoID: repo.id, repoPath: repo.path,
            worktreePath: worktreePath, branch: branch, baseBranch: baseBranch)
        switch outcome {
        case let .cloned(templateCommit):
            logger.info("""
            clone checkout: \(worktreePath, privacy: .public) cloned from template \
            \(templateCommit, privacy: .public)
            """)
        case let .materialized(reason):
            logger.info("""
            clone checkout: \(worktreePath, privacy: .public) written in full \
            (\(reason, privacy: .public))
            """)
        }

        // Move the template to this worktree's base, so the next create from
        // the same base clones with nothing to rewrite. Off the create's path:
        // the create is already complete, and a refresh that loses a race with
        // the next clone is simply skipped.
        guard let head = try? await git.headSHA(worktreePath: worktreePath) else { return outcome }
        let store = checkoutTemplates
        let gitManager = self.git
        let repoID = repo.id
        let repoPath = repo.path
        Task.detached(priority: .utility) {
            await store.refresh(git: gitManager, repoID: repoID, repoPath: repoPath, toCommit: head)
        }
        return outcome
    }
}
