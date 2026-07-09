import Foundation

/// Fans a merged-PR transition out to the auto-archive and auto-hibernate
/// coordinators, enforcing the precedence rule: archive supersedes hibernate.
///
/// If the worktree was ACTUALLY archived, hibernating its sessions is pointless
/// (they'd be torn down with the worktree anyway), so hibernate is skipped. But
/// the key asymmetry: precedence keys off "did archive actually begin", not "was
/// archive armed". An armed-but-blocked archive (e.g. the worktree has active
/// children) returns `false`, the worktree survives, and its idle sessions are
/// still parked — parking an idle session on a surviving worktree is correct.
public struct MergedTransitionDispatcher: Sendable {
    let archive: AutoArchiveOnMergeCoordinator
    let hibernate: AutoHibernateOnMergeCoordinator

    public init(
        archive: AutoArchiveOnMergeCoordinator,
        hibernate: AutoHibernateOnMergeCoordinator
    ) {
        self.archive = archive
        self.hibernate = hibernate
    }

    public func handleMergedTransition(worktreeID: UUID, prNumber: Int) async {
        let archived = await archive.handleMergedTransition(worktreeID: worktreeID, prNumber: prNumber)
        guard !archived else { return }
        await hibernate.handleMergedTransition(worktreeID: worktreeID, prNumber: prNumber)
    }
}
