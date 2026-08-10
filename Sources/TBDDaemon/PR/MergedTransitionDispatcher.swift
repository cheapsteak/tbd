import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "MergedTransition")

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

    /// The gate in front of the fan-out: a worktree may own several PRs, so a
    /// merge only means "this worktree is done" once every PR bound to it has
    /// resolved. See `AllResolvedMergeTrigger`.
    public func makeAllResolvedTrigger() -> AllResolvedMergeTrigger {
        AllResolvedMergeTrigger { [self] worktreeID, prNumber in
            await handleMergedTransition(worktreeID: worktreeID, prNumber: prNumber)
        }
    }
}

/// Decides *when* a worktree's PRs count as done, and fires the merged-transition
/// fan-out once when they do.
///
/// The rule (design `2026-08-10-multi-pr-per-worktree`, "Merge semantics"):
/// **every non-detached binding is terminal and at least one is merged** —
/// `PRBinding.allResolved(_:)`. With one binding this is identical to the
/// single-PR behavior it replaces; with several it refuses to archive a worktree
/// that still has an open PR on it. A binding whose status has never been
/// observed is not terminal, so an unpolled PR holds the gate shut.
///
/// **Edge-triggered, and this actor's state is the only once-only guard.** A
/// poll runs every few seconds and would otherwise re-fire on every pass, so a
/// worktree fires when `allResolved` goes false→true and not again until it goes
/// back to false (a newly bound open PR, or a re-attached one). The memory is
/// per daemon run and deliberately unpersisted, which is the same reason
/// `.merged` is never written to `Worktree.prStatus`: a merge observed while the
/// daemon was down is re-observed as a transition after restart, so an
/// auto-archive that failed is retried rather than lost.
public actor AllResolvedMergeTrigger {
    /// Worktrees whose bindings were all-resolved at their last evaluation.
    private var resolved: Set<UUID> = []
    private let onResolved: @Sendable (UUID, Int) async -> Void

    /// `onResolved` receives the worktree and the PR number to attribute the
    /// transition to. Production passes `MergedTransitionDispatcher`'s fan-out
    /// (see `makeAllResolvedTrigger`); tests pass a recorder.
    public init(onResolved: @escaping @Sendable (UUID, Int) async -> Void) {
        self.onResolved = onResolved
    }

    /// Judge one worktree against its current bindings. Call after each poll has
    /// folded fresh statuses onto them.
    public func evaluate(worktreeID: UUID, bindings: [PRBinding]) async {
        let live = bindings.filter { !$0.detached }
        guard PRBinding.allResolved(live) else {
            // Not resolved (any more): re-arm, so a later resolution is a fresh
            // rising edge rather than a suppressed repeat.
            resolved.remove(worktreeID)
            return
        }
        // Attribute the transition to the first merged binding in bind order —
        // stable across polls, so the notification text does not change if a
        // second PR merges later in the same set. `allResolved` guarantees one
        // exists; if that ever stops being true this must stay silent (a
        // worktree whose PRs all CLOSED was abandoned, not shipped), so say so
        // loudly rather than inventing a number.
        guard let merged = live.first(where: { $0.status?.state == .merged }) else {
            logger.error("all-resolved with no merged binding for \(worktreeID, privacy: .public) — not firing")
            resolved.remove(worktreeID)
            return
        }
        guard resolved.insert(worktreeID).inserted else { return }
        logger.info("all bound PRs resolved for \(worktreeID, privacy: .public) (\(live.count, privacy: .public) binding(s), attributing to PR #\(merged.number, privacy: .public))")
        await onResolved(worktreeID, merged.number)
    }

    /// The un-bound fallback: a merge observed on a worktree that has **no**
    /// bindings at all.
    ///
    /// Binding discovery does not reach every worktree, and the worktree-keyed
    /// status cache does not depend on it: a branch match the coordinator
    /// rejected as wrong-repo, or a `Worktree.prNumber` whose seed deferred
    /// because the worktree's own repo could not be named, still yields a cached
    /// status and so still observes a merge — with nothing bound to judge. There
    /// the observed merge is the whole story and this behaves exactly as the
    /// single-PR path always did. A worktree that *does* have bindings is judged
    /// only by `evaluate`, so an open sibling PR cannot be archived out from
    /// under.
    public func observedMerge(worktreeID: UUID, prNumber: Int, bindings: [PRBinding]) async {
        guard bindings.filter({ !$0.detached }).isEmpty else { return }
        guard resolved.insert(worktreeID).inserted else { return }
        await onResolved(worktreeID, prNumber)
    }
}
