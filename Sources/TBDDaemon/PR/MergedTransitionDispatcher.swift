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
/// **every non-detached binding is terminal, at least one is merged, and at
/// least one merged binding is the worktree's own work** —
/// `PRBinding.allResolved(_:)` and
/// `PRBinding.mergedBindingIsOwnWork(_:branchCandidates:provenancePRNumber:)`.
/// A binding whose status has never been observed is not terminal, so an
/// unpolled PR holds the gate shut.
///
/// Both halves are required, and together they make this **strictly stronger**
/// than the single-PR rule it replaces: the old rule fired when the worktree's
/// own PR merged, this one fires when the worktree's own PR merged AND every
/// other PR it opened has finished too. Ownership is not implied by the set —
/// a subagent's `gh pr create`, or one run from a sibling checkout in the same
/// repo, binds to the current worktree, is spared the head-ref heal, and is
/// re-queried only by number, so nothing else would ever disprove it.
///
/// **Edge-triggered, and this actor's state is the only once-only guard.** A
/// poll runs every few seconds and would otherwise re-fire on every pass, so a
/// worktree fires when `allResolved` goes false→true and not again until it goes
/// back to false — a newly bound open PR, or every binding detached, which
/// `retainBound(polled:bound:)` reports because `evaluate` never sees a worktree
/// that has left the bound population. A `tbd pr detach` followed by a
/// `tbd pr attach` therefore re-arms and fires again, which is what an explicit
/// attach should mean. The memory is per daemon run and deliberately
/// unpersisted, which is the same reason
/// `.merged` is never written to `Worktree.prStatus`: a merge observed while the
/// daemon was down is re-observed as a transition after restart, so an
/// auto-archive that failed is retried rather than lost.
public actor AllResolvedMergeTrigger {
    /// Worktrees whose bindings were all-resolved at their last evaluation.
    /// Owned exclusively by `evaluate`.
    private var allResolvedFired: Set<UUID> = []

    /// Worktrees the un-bound fallback has already fired for. Owned exclusively
    /// by `observedMerge`.
    ///
    /// **Two sets, not one.** The two entry points describe different worktree
    /// populations — bound and un-bound — and each clears its own set on its own
    /// definition of "no longer resolved". One shared set could not: a fire
    /// through either path would suppress the other path's first fire for the
    /// same worktree, and the two paths are not alternative views of one event.
    /// A worktree whose bindings are all detached is judged by `observedMerge`
    /// from then on, on a merge `evaluate` never saw and cannot re-derive.
    private var unboundMergeFired: Set<UUID> = []

    /// Worktrees this poll pass has already fanned out for, through either
    /// entry point. Cleared by `beginPollPass()`.
    ///
    /// The two sets above are per-*edge* memories and stay independent — that
    /// independence is what stops either path suppressing the other's
    /// legitimate first fire. This one is a per-*pass* memory, and it exists
    /// because one pass can legitimately raise both edges for the same
    /// worktree: `PRStatusManager.apply` observes an already-merged PR from
    /// inside `fetchAll` with nothing bound yet, so `observedMerge` fires; the
    /// same pass then creates the binding and `evaluate` judges it resolved.
    /// That is the ordinary path for a worktree whose PR merged while the
    /// daemon was down, so it is not a rare race.
    ///
    /// Both fires are correct as *edges*; what must not happen twice is the
    /// **actuation**. Today no duplicate is user-visible, but only because both
    /// coordinators happen to re-check state on entry — a property of those two
    /// coordinators, not of this trigger. Deduplicating here makes "at most one
    /// fan-out per worktree per pass" a guarantee the trigger owns.
    ///
    /// The edge memories are still recorded when a fire is suppressed here: the
    /// fan-out DID happen this pass, through the other path, so neither edge
    /// should fire again on the next one.
    private var firedThisPass: Set<UUID> = []

    private let onResolved: @Sendable (UUID, Int) async -> Void

    /// `onResolved` receives the worktree and the PR number to attribute the
    /// transition to. Production passes `MergedTransitionDispatcher`'s fan-out
    /// (see `makeAllResolvedTrigger`); tests pass a recorder.
    public init(onResolved: @escaping @Sendable (UUID, Int) async -> Void) {
        self.onResolved = onResolved
    }

    /// Open a poll pass: forget which worktrees the previous one fanned out for.
    ///
    /// Called at the very top of `computePRList`, before anything can observe a
    /// merge. `pr.list` is single-flighted, so passes never overlap, and both
    /// entry points fire strictly inside one — `observedMerge` from `fetchAll`,
    /// `evaluate` from `refreshBindingStatuses`. A merge observed OUTSIDE a pass
    /// (the targeted `pr.refresh`) is remembered here too and cleared by the
    /// next pass before any `evaluate` can run, so it can never suppress one.
    public func beginPollPass() {
        firedThisPass.removeAll()
    }

    /// Fan out at most once per worktree per poll pass. See `firedThisPass`.
    private func fanOut(worktreeID: UUID, prNumber: Int) async {
        guard firedThisPass.insert(worktreeID).inserted else {
            logger.debug("merged fan-out already ran this pass for \(worktreeID, privacy: .public) — not repeating")
            return
        }
        await onResolved(worktreeID, prNumber)
    }

    /// Judge one worktree against its current bindings. Call after each poll has
    /// folded fresh statuses onto them.
    ///
    /// `branchCandidates` is the worktree's own branch list as the matcher
    /// derives it (`PRStatusManager.candidatesFor`) and `provenancePRNumber` its
    /// `Worktree.prNumber`; both are passed in rather than looked up here so the
    /// rule stays a pure function of facts the poll already holds.
    public func evaluate(worktreeID: UUID, bindings: [PRBinding],
                         branchCandidates: [String], provenancePRNumber: Int?) async {
        let live = bindings.filter { !$0.detached }
        let ownWorkMerged = PRBinding.mergedBindingIsOwnWork(
            live, branchCandidates: branchCandidates, provenancePRNumber: provenancePRNumber)
        guard PRBinding.allResolved(live), ownWorkMerged else {
            // Not resolved (any more), or nothing merged here is this worktree's
            // own: re-arm, so a later resolution is a fresh rising edge rather
            // than a suppressed repeat.
            allResolvedFired.remove(worktreeID)
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
            allResolvedFired.remove(worktreeID)
            return
        }
        guard allResolvedFired.insert(worktreeID).inserted else { return }
        logger.info("all bound PRs resolved for \(worktreeID, privacy: .public) (\(live.count, privacy: .public) binding(s), attributing to PR #\(merged.number, privacy: .public))")
        await fanOut(worktreeID: worktreeID, prNumber: merged.number)
    }

    /// Re-arm every polled worktree that no longer has a live binding.
    ///
    /// `evaluate` runs only over the worktrees the poll's grouping contains, and
    /// that grouping is built from live bindings — so a worktree whose last
    /// binding was detached leaves the bound population entirely and its own
    /// re-arm inside `evaluate` never runs. Each pass therefore reports the
    /// whole population it looked at, and anything that dropped out of it is
    /// disarmed here: a later `tbd pr attach` that puts the worktree back in a
    /// resolved state is a fresh rising edge rather than a silent no-op.
    ///
    /// Scoped to `polled` deliberately. A worktree this pass never examined has
    /// said nothing about its bindings, and unremembering it on that silence
    /// would let an unrelated poll re-fire an archive that already ran.
    public func retainBound(polled: Set<UUID>, bound: Set<UUID>) {
        allResolvedFired.subtract(polled.subtracting(bound))
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
    ///
    /// Its own once-only guard re-arms on its own condition: the moment the
    /// worktree has a live binding again, `evaluate` owns it and this fallback
    /// is disarmed, so if every binding is later detached a fresh merge is a
    /// fresh rising edge.
    public func observedMerge(worktreeID: UUID, prNumber: Int, bindings: [PRBinding]) async {
        guard bindings.filter({ !$0.detached }).isEmpty else {
            unboundMergeFired.remove(worktreeID)
            return
        }
        guard unboundMergeFired.insert(worktreeID).inserted else { return }
        await fanOut(worktreeID: worktreeID, prNumber: prNumber)
    }
}
