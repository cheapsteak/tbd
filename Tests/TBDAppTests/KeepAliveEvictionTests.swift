import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for activity/pin/visibility-aware keep-alive eviction.
///
/// The keep-alive mount set (`AppState.keepAliveWorktreeIDs`) protects
/// worktrees the user must not lose — selected, pinned, or actively working —
/// from being torn down, while still evicting the least-recently-visited
/// *non-protected* worktrees once the cap is exceeded.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("Keep-alive eviction")
struct KeepAliveEvictionTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.KeepAliveEviction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func terminal(
        worktreeID: UUID,
        activityState: TerminalActivityState = .unknown,
        pinnedAt: Date? = nil
    ) -> Terminal {
        Terminal(
            id: UUID(),
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Claude",
            pinnedAt: pinnedAt,
            kind: .claude,
            activityState: activityState
        )
    }

    // MARK: - Pure policy (static function)

    @Test func nonProtectedWorktreeIsEvictedPastCap() {
        // limit 2, three plain non-protected visits — oldest drops out.
        let a = UUID(), b = UUID(), c = UUID()
        let kept = AppState.keepAliveWorktreeIDs(
            recentlyVisited: [c, b, a], // most-recent-first
            protected: [],
            limit: 2
        )
        #expect(kept == [c, b])
        #expect(!kept.contains(a))
    }

    @Test func protectedWorktreeSurvivesPastCapAndDoesNotConsumeBudget() {
        // `protectedOld` aged to the back of the recency log but is protected,
        // so it stays — and the two most-recent non-protected entries are BOTH
        // kept (protection doesn't eat the non-protected budget).
        let protectedOld = UUID()
        let recent1 = UUID(), recent2 = UUID()
        let kept = AppState.keepAliveWorktreeIDs(
            recentlyVisited: [recent2, recent1, protectedOld],
            protected: [protectedOld],
            limit: 2
        )
        #expect(kept.contains(protectedOld))
        #expect(kept.contains(recent1))
        #expect(kept.contains(recent2))
    }

    @Test func evictionPicksOldestNonProtected() {
        // Oldest entry is protected; the oldest *non-protected* is evicted.
        let protectedOldest = UUID()
        let oldNonProtected = UUID()
        let mid = UUID(), newest = UUID()
        let kept = AppState.keepAliveWorktreeIDs(
            recentlyVisited: [newest, mid, oldNonProtected, protectedOldest],
            protected: [protectedOldest],
            limit: 2
        )
        #expect(kept.contains(protectedOldest))
        #expect(kept.contains(newest))
        #expect(kept.contains(mid))
        #expect(!kept.contains(oldNonProtected)) // oldest non-protected evicted
    }

    @Test func protectedWorktreeNeverVisitedIsStillMounted() {
        // A worktree that became protected (e.g. started working) but is not in
        // the recency log at all is still mounted.
        let neverVisited = UUID()
        let visited = UUID()
        let kept = AppState.keepAliveWorktreeIDs(
            recentlyVisited: [visited],
            protected: [neverVisited],
            limit: 8
        )
        #expect(kept.contains(neverVisited))
        #expect(kept.contains(visited))
    }

    @Test func keepAliveSetAlwaysContainsProtectionSet() {
        let p1 = UUID(), p2 = UUID(), p3 = UUID()
        let n1 = UUID(), n2 = UUID()
        let protected: Set<UUID> = [p1, p2, p3]
        let kept = Set(AppState.keepAliveWorktreeIDs(
            recentlyVisited: [n1, n2, p1], // only p1 visited; many non-protected
            protected: protected,
            limit: 1 // tight budget — protection must still win
        ))
        #expect(protected.isSubset(of: kept))
    }

    // MARK: - Integration through AppState computed properties

    @Test func selectedWorktreeIsNotEvictedEvenPastCap() {
        withState { state in
            let selected = UUID()
            // Fill the recency log beyond the cap with plain visits, then make
            // `selected` the oldest entry and select it.
            var ids: [UUID] = []
            for _ in 0..<10 { ids.append(UUID()) }
            ids.append(selected)
            for id in ids.reversed() { state.touchVisitedWorktree(id) }
            state.selectedWorktreeIDs = [selected]

            #expect(state.protectedWorktreeIDs.contains(selected))
            #expect(state.keepAliveWorktreeIDs.contains(selected))
        }
    }

    @Test func pinnedOnlyWorktreeIsEvictedPastCapBecauseDockKeepsItAlive() {
        withState { state in
            // A worktree that is ONLY pinned (not selected, not working) is NOT
            // protected by the pager keep-alive set: PinnedTerminalDock already
            // keeps its pinned terminal's view alive, and protecting it here too
            // would double-mount the shared `tbd-view-<id>` tmux session. So it
            // is evictable once it ages past the cap.
            let pinnedWT = UUID()
            state.terminals = [pinnedWT: [terminal(worktreeID: pinnedWT, pinnedAt: Date())]]
            state.touchVisitedWorktree(pinnedWT)
            for _ in 0..<12 { state.touchVisitedWorktree(UUID()) }

            // It is still "visible" (the dock shows it) but NOT pager-protected.
            #expect(state.visibleWorktreeIDs.contains(pinnedWT))
            #expect(!state.protectedWorktreeIDs.contains(pinnedWT))
            #expect(!state.keepAliveWorktreeIDs.contains(pinnedWT))
        }
    }

    @Test func workingWorktreeIsNotEvictedEvenWhenOlderThanCap() {
        withState { state in
            let workingWT = UUID()
            state.terminals = [workingWT: [terminal(worktreeID: workingWT, activityState: .working)]]
            // Visit it first (oldest), then bury it under many newer visits.
            state.touchVisitedWorktree(workingWT)
            for _ in 0..<12 { state.touchVisitedWorktree(UUID()) }

            #expect(state.workingWorktreeIDs.contains(workingWT))
            #expect(state.protectedWorktreeIDs.contains(workingWT))
            #expect(state.keepAliveWorktreeIDs.contains(workingWT))
        }
    }

    @Test func nonWorkingNonVisibleWorktreeIsEvictedPastCap() {
        withState { state in
            // Ungated behavior still works: a plain worktree (idle, unpinned,
            // unselected) that aged past the cap is dropped from the mount set.
            let plainOld = UUID()
            state.terminals = [plainOld: [terminal(worktreeID: plainOld, activityState: .idle)]]
            state.touchVisitedWorktree(plainOld)
            for _ in 0..<12 { state.touchVisitedWorktree(UUID()) }

            #expect(!state.protectedWorktreeIDs.contains(plainOld))
            #expect(!state.keepAliveWorktreeIDs.contains(plainOld))
        }
    }

    // MARK: - Dock dedup (prevents double-mount)

    @Test func pinnedTerminalInNonSelectedWorktreeIsDockedAndSuppressedInLayout() {
        withState { state in
            let wt = UUID()
            let term = terminal(worktreeID: wt, pinnedAt: Date())
            state.terminals = [wt: [term]]
            // Not selected → its pinned terminal is owned by the dock, not the
            // main content area.
            #expect(!state.visibleTerminalIDs.contains(term.id))
            #expect(state.dockedTerminalIDs.contains(term.id))
            #expect(AppState.shouldSuppressTerminalInLayout(
                terminalID: term.id,
                dockedTerminalIDs: state.dockedTerminalIDs
            ))
        }
    }

    @Test func pinnedTerminalInSelectedActiveTabIsNotDockedNorSuppressed() {
        withState { state in
            let wt = UUID()
            let term = terminal(worktreeID: wt, pinnedAt: Date())
            state.terminals = [wt: [term]]
            state.tabs = [wt: [Tab(id: term.id, content: .terminal(terminalID: term.id), label: nil)]]
            state.activeTabIndices = [wt: 0]
            state.selectedWorktreeIDs = [wt]

            // Selected & on the active tab → rendered for real in the main area,
            // so it is NOT docked and must NOT be suppressed in the layout path.
            #expect(state.visibleTerminalIDs.contains(term.id))
            #expect(!state.dockedTerminalIDs.contains(term.id))
            #expect(!AppState.shouldSuppressTerminalInLayout(
                terminalID: term.id,
                dockedTerminalIDs: state.dockedTerminalIDs
            ))
        }
    }

    @Test func dockedTerminalIsSuppressedInLayout() {
        let id = UUID()
        #expect(AppState.shouldSuppressTerminalInLayout(terminalID: id, dockedTerminalIDs: [id]))
    }

    @Test func nonDockedTerminalIsNotSuppressedInLayout() {
        let id = UUID()
        #expect(!AppState.shouldSuppressTerminalInLayout(terminalID: id, dockedTerminalIDs: [UUID()]))
        #expect(!AppState.shouldSuppressTerminalInLayout(terminalID: id, dockedTerminalIDs: []))
    }
}
