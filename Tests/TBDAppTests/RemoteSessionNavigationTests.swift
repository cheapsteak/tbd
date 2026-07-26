import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for remote-session back/forward navigation — `NavigationEntry
/// .remoteSession`, recording on `selectRemoteSession`, and stale-entry
/// skipping. Follows `ArchiveNavigateBackTests`'s patterns (same `withState`
/// shape, same style of walking `navigationEntries`/`navigationIndex`
/// directly since they're internal, not private).
///
/// Deliberately does NOT touch scratch-space navigation — that keeps its
/// documented scope cut; only remote sessions became first-class history
/// entries in this task.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("Remote session navigation")
struct RemoteSessionNavigationTests {
    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.RemoteSessionNavigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func makeWorktree(id: UUID, repoID: UUID) -> Worktree {
        Worktree(
            id: id, repoID: repoID, name: "test-\(id.uuidString.prefix(8))",
            displayName: "Test \(id.uuidString.prefix(8))", branch: "main",
            path: "/tmp/test", status: .active, tmuxServer: "test-server"
        )
    }

    private func session(provider: String, id: String, dismissed: Bool = false, gone: Bool = false) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider, payload: RemoteSessionPayload(id: id, state: .running),
            gone: gone, dismissed: dismissed, lastSeen: Date()
        )
    }

    // MARK: - Recording on selection

    @Test func selectingARemoteSessionRecordsANavigationEntry() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            let expected = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.navigationEntries == [.remoteSession(expected)])
            #expect(state.navigationIndex == 0)
        }
    }

    @Test func selectingASecondRemoteSessionAppendsANewEntry() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s2")

            #expect(state.navigationEntries == [
                .remoteSession(RemoteSessionSelection(provider: "acme", sessionID: "s1")),
                .remoteSession(RemoteSessionSelection(provider: "acme", sessionID: "s2")),
            ])
        }
    }

    @Test func reselectingTheSameRemoteSessionDoesNotDuplicateTheEntry() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.navigationEntries.count == 1)
        }
    }

    @Test func selectingAWorktreeThenARemoteSessionRecordsBothEntries() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            state.selectedWorktreeIDs = [wtID]
            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.navigationEntries == [
                .worktrees([wtID]),
                .remoteSession(RemoteSessionSelection(provider: "acme", sessionID: "s1")),
            ])
        }
    }

    // MARK: - Back/forward restoring a remote selection

    @Test func backFromAWorktreeRestoresThePriorRemoteSessionSelection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            // History: [.remoteSession(s1)] (index 0), [.worktrees([wtID])] (index 1, current).
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [wtID]

            state.navigateBack()

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }

    @Test func forwardReturnsFromARemoteSessionToTheLaterWorktreeSelection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [wtID]
            state.navigateBack()
            #expect(state.selectedRemoteSession != nil)

            state.navigateForward()

            #expect(state.selectedWorktreeIDs == [wtID])
            #expect(state.selectedRemoteSession == nil)
        }
    }

    @Test func backBetweenTwoRemoteSessionsRestoresTheEarlierOne() {
        withState { state in
            state.remoteSessions = [session(provider: "acme", id: "s1"), session(provider: "acme", id: "s2")]

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s2")

            state.navigateBack()

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
        }
    }

    // MARK: - Stale-entry skipping

    /// `gone` (still reported by the provider's mirror, just no longer
    /// live) stays a USABLE landing spot — matches the detail view and
    /// context menu, which both still render a gone row read-only rather
    /// than treating it as absent.
    @Test func navigateBack_treatsAGoneRemoteSessionAsUsable() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [wtID]
            // The session goes `gone` after the history entry was recorded
            // (e.g. the provider stopped reporting it while the user was
            // looking at the worktree).
            state.remoteSessions = [session(provider: "acme", id: "s1", gone: true)]

            state.navigateBack()

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
        }
    }

    /// A dismissed session (explicit user tombstone) is NOT a usable
    /// landing spot — back must skip past it, mirroring how an archived
    /// worktree is skipped.
    @Test func navigateBack_skipsADismissedRemoteSessionEntry() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [
                makeWorktree(id: a, repoID: repoID), makeWorktree(id: wtID, repoID: repoID),
            ]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            // History: [.worktrees([a])], [.remoteSession(s1)], [.worktrees([wtID])] (current).
            state.selectedWorktreeIDs = [a]
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [wtID]
            // s1 gets dismissed while the user is elsewhere.
            state.remoteSessions = [session(provider: "acme", id: "s1", dismissed: true)]

            state.navigateBack()

            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedWorktreeIDs == [a])
        }
    }

    /// A session absent from the mirror ENTIRELY (never dismissed, just not
    /// reported any more — e.g. the provider was unregistered) is equally
    /// unusable — the same membership check covers both cases.
    @Test func navigateBack_skipsARemoteSessionEntryForASessionNoLongerInTheMirrorAtAll() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [
                makeWorktree(id: a, repoID: repoID), makeWorktree(id: wtID, repoID: repoID),
            ]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            state.selectedWorktreeIDs = [a]
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [wtID]
            state.remoteSessions = [] // s1 vanished entirely

            state.navigateBack()

            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedWorktreeIDs == [a])
        }
    }

    @Test func canGoBack_isFalseWhenOnlyPriorEntryIsADismissedRemoteSession() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            // History: [.remoteSession(s1)] (index 0), [.worktrees([wtID])] (index 1, current).
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [wtID]
            state.remoteSessions = [session(provider: "acme", id: "s1", dismissed: true)]
            // `canGoBack` is now stale-true (computed before the dismissal);
            // clicking back on the dead button must no-op AND self-correct
            // the flag, mirroring `navigateBack_withFlagsGoneStale_noOpsAndDisablesBack`.
            #expect(state.canGoBack == true)

            state.navigateBack()

            #expect(state.selectedWorktreeIDs == [wtID], "no usable prior entry: selection stays put")
            #expect(state.canGoBack == false)
        }
    }

    @Test func navigateForward_skipsADismissedRemoteSessionEntry() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            state.worktrees = [repoID: [
                makeWorktree(id: a, repoID: repoID), makeWorktree(id: b, repoID: repoID),
            ]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            // History: [.worktrees([a])], [.remoteSession(s1)], [.worktrees([b])].
            state.selectedWorktreeIDs = [a]
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [b]

            // Walk back to the start, then dismiss s1, then walk forward —
            // forward must skip the now-dead remote entry and land on [b].
            state.navigateBack() // -> remote s1 (still usable at this point)
            state.navigateBack() // -> [a]
            #expect(state.selectedWorktreeIDs == [a])
            state.remoteSessions = [session(provider: "acme", id: "s1", dismissed: true)]

            state.navigateForward()

            #expect(state.selectedWorktreeIDs == [b])
            #expect(state.selectedRemoteSession == nil)
        }
    }

    // MARK: - isNavigating guard: replay doesn't re-record

    @Test func navigatingBackAndForwardDoesNotGrowHistory() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.remoteSessions = [session(provider: "acme", id: "s1")]

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectedWorktreeIDs = [wtID]
            let countAfterSelections = state.navigationEntries.count

            state.navigateBack()
            state.navigateForward()

            #expect(state.navigationEntries.count == countAfterSelections)
        }
    }
}
