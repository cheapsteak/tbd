import Foundation
import Testing
@testable import TBDApp

/// Tests for `RemoteAttachLifecycle.attachedSelections` — the pure decision
/// behind which remote sessions get a live attach terminal right now. Pure
/// Swift, no AppState/AppKit — mirrors `KeepAliveEvictionTests`'s "pure
/// policy" section for the worktree analogue this type is modeled on.
@Suite("RemoteAttachLifecycle.attachedSelections")
struct RemoteAttachLifecycleTests {
    private func selection(_ id: String) -> RemoteSessionSelection {
        RemoteSessionSelection(provider: "acme", sessionID: id)
    }

    // MARK: - Selected session (protected)

    @Test func selectedEligibleSessionIsIncluded() {
        let a = selection("a")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: a, recentlyViewed: [], eligible: [a], explicitlyDetached: [], cap: 8
        )
        #expect(result == [a])
    }

    @Test func selectedIneligibleSessionIsExcludedEvenThoughSelected() {
        // No capability (or gone) — not in `eligible` at all.
        let a = selection("a")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: a, recentlyViewed: [], eligible: [], explicitlyDetached: [], cap: 8
        )
        #expect(result.isEmpty)
    }

    @Test func selectedExplicitlyDetachedSessionIsExcludedEvenThoughSelectedAndEligible() {
        // The core "no re-attach loop" rule: explicit-detach overrides even
        // an eligible, currently-selected session.
        let a = selection("a")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: a, recentlyViewed: [], eligible: [a], explicitlyDetached: [a], cap: 8
        )
        #expect(result.isEmpty)
    }

    @Test func nilSelectionContributesNothing() {
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: nil, recentlyViewed: [], eligible: [], explicitlyDetached: [], cap: 8
        )
        #expect(result.isEmpty)
    }

    // MARK: - Recent (non-selected) sessions

    @Test func recentEligibleSessionWithinCapIsIncluded() {
        let a = selection("a")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: nil, recentlyViewed: [a], eligible: [a], explicitlyDetached: [], cap: 8
        )
        #expect(result == [a])
    }

    @Test func recentEligibleSessionBeyondCapIsExcluded() {
        let a = selection("a"), b = selection("b"), c = selection("c")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: nil, recentlyViewed: [a, b, c], eligible: [a, b, c], explicitlyDetached: [], cap: 2
        )
        #expect(result == [a, b])
        #expect(!result.contains(c))
    }

    @Test func recentExplicitlyDetachedSessionIsExcludedRegardlessOfPosition() {
        let a = selection("a"), b = selection("b")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: nil, recentlyViewed: [a, b], eligible: [a, b], explicitlyDetached: [a], cap: 8
        )
        #expect(result == [b])
    }

    @Test func recentIneligibleSessionIsExcluded() {
        let a = selection("a"), b = selection("b")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: nil, recentlyViewed: [a, b], eligible: [b], explicitlyDetached: [], cap: 8
        )
        #expect(result == [b])
    }

    // MARK: - Selected + recent budget interaction

    @Test func selectedSessionDoesNotConsumeTheCapBudget() {
        // Mirrors `protectedWorktreeSurvivesPastCapAndDoesNotConsumeBudget`:
        // the selected session plus `cap` recent ones is `cap + 1` total.
        let selected = selection("selected")
        let r1 = selection("r1"), r2 = selection("r2")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: selected,
            recentlyViewed: [r1, r2],
            eligible: [selected, r1, r2],
            explicitlyDetached: [],
            cap: 2
        )
        #expect(Set(result) == Set([selected, r1, r2]))
    }

    @Test func selectedSessionAlsoPresentInRecentlyViewedIsNotDoubleCounted() {
        let selected = selection("selected")
        let other = selection("other")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: selected,
            recentlyViewed: [selected, other],
            eligible: [selected, other],
            explicitlyDetached: [],
            cap: 1
        )
        // Budget of 1 non-protected slot is spent on `other`, not wasted on
        // `selected` appearing a second time.
        #expect(result == [selected, other])
    }

    @Test func capZeroOnlyKeepsTheProtectedSelection() {
        let selected = selection("selected")
        let other = selection("other")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: selected,
            recentlyViewed: [other],
            eligible: [selected, other],
            explicitlyDetached: [],
            cap: 0
        )
        #expect(result == [selected])
    }

    @Test func emptyInputsProduceEmptyResult() {
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: nil, recentlyViewed: [], eligible: [], explicitlyDetached: [], cap: 8
        )
        #expect(result.isEmpty)
    }

    @Test func duplicateEntriesInRecentlyViewedAreNotDoubleCounted() {
        let a = selection("a")
        let result = RemoteAttachLifecycle.attachedSelections(
            selected: nil, recentlyViewed: [a, a, a], eligible: [a], explicitlyDetached: [], cap: 8
        )
        #expect(result == [a])
    }
}
