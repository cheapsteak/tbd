import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
@Suite("Sidebar group reveal")
struct SidebarGroupRevealTests {
    private func withState(_ body: (AppState, UUID) -> Void) {
        let suite = "SidebarGroupRevealTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(userDefaults: defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        body(state, repo.id)
    }

    @Test func disclosureDoesNotSelectAttachOrClearUnread() {
        withState { state, repo in
            let group = SidebarGroupID(owner: .repository(repo), kind: .remote)
            let key = RemoteSessionSelection(provider: "acme", sessionID: "worker")
            state.unreadByRemoteSession[key] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
            let unread = state.unreadByRemoteSession
            state.toggleSidebarGroup(group)
            #expect(state.expandedSidebarGroups == [group])
            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.selectedRemoteSession == nil)
            #expect(state.recentlyAttachedRemoteSessions.isEmpty)
            #expect(state.unreadByRemoteSession == unread)
            state.toggleSidebarGroup(group)
            #expect(state.expandedSidebarGroups.isEmpty)
        }
    }

    @Test func unchangedInventoryDoesNotUndoManualCollapseButReselectionReveals() {
        withState { state, repo in
            state.remoteSessions = [SidebarGroupFixtures.session("worker", repoID: repo)]
            let key = RemoteSessionSelection(provider: "acme", sessionID: "worker")
            state.selectedRemoteSession = key
            let first = state.sidebarSelectionReveal
            state.revealSidebarGroups(first)
            let group = SidebarGroupID(owner: .repository(repo), kind: .remote)
            state.toggleSidebarGroup(group)
            let sameInventory = state.remoteSessions
            state.remoteSessions = sameInventory
            #expect(state.sidebarSelectionReveal == first)
            #expect(!state.expandedSidebarGroups.contains(group))
            state.selectedRemoteSession = key
            #expect(state.sidebarSelectionReveal != first)
            state.revealSidebarGroups(state.sidebarSelectionReveal)
            #expect(state.expandedSidebarGroups.contains(group))
        }
    }

    @Test func selectedSessionMovingToExitedRevealsItsNewGroup() {
        withState { state, repo in
            state.remoteSessions = [SidebarGroupFixtures.session("worker", repoID: repo)]
            state.selectedRemoteSession = .init(provider: "acme", sessionID: "worker")
            let initial = state.sidebarSelectionReveal
            state.remoteSessions = [SidebarGroupFixtures.session("worker", state: .exited, repoID: repo)]
            let updated = state.sidebarSelectionReveal
            #expect(updated != initial)
            state.revealSidebarGroups(updated)
            #expect(state.expandedSidebarGroups.contains(.init(owner: .repository(repo), kind: .exited)))
            #expect(state.recentlyAttachedRemoteSessions.isEmpty)
        }
    }

    @Test func snapshotInvalidatesForRowsSessionsAndProviderHealth() {
        withState { state, repo in
            state.remoteSessions = [SidebarGroupFixtures.session("worker", repoID: repo)]
            #expect(state.sidebarRemoteGroups(repoID: repo).summary.counts == [.running: 1])
            let row = SidebarGroupFixtures.row("worker", repoID: repo, remote: "worker")
            state.worktrees[repo] = [row]
            #expect(state.sidebarRemoteGroups(repoID: repo).sessions.isEmpty)
            #expect(state.sidebarRemoteGroups(repoID: repo).remoteRoots.map(\.id) == [row.id])
            state.remoteProviders = [SidebarGroupFixtures.provider(health: .error)]
            #expect(state.sidebarRemoteGroups(repoID: repo).summary.counts == [.unknown: 1])
            state.remoteProviders = [SidebarGroupFixtures.provider()]
            state.remoteSessions = [SidebarGroupFixtures.session("worker", state: .exited, repoID: repo)]
            #expect(state.sidebarRemoteGroups(repoID: repo).exitedRoots.map(\.id) == [row.id])
        }
    }

    @Test func filteredRepoSessionsKeepTheExistingProviderFallback() {
        withState { state, repo in
            state.remoteSessions = [SidebarGroupFixtures.session("worker", repoID: repo)]
            #expect(state.sidebarRemoteGroups(provider: "acme").isEmpty)
            state.repoFilter = UUID()
            #expect(state.sidebarRemoteGroups(provider: "acme").sessions.count == 1)
        }
    }
}
