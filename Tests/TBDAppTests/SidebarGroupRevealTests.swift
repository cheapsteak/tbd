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
            state.selectRemoteSession(provider: "acme", sessionID: "worker")
            let first = state.sidebarSelectionReveal
            let generation = state.sidebarSelectionGeneration
            state.revealSidebarGroups(first)
            let group = SidebarGroupID(owner: .repository(repo), kind: .remote)
            state.toggleSidebarGroup(group)
            let sameInventory = state.remoteSessions
            state.remoteSessions = sameInventory
            #expect(state.sidebarSelectionReveal == first)
            #expect(!state.expandedSidebarGroups.contains(group))
            state.selectRemoteSession(provider: "acme", sessionID: "worker")
            #expect(state.sidebarSelectionGeneration == generation + 1)
            #expect(state.sidebarSelectionReveal != first)
            state.revealSidebarGroups(state.sidebarSelectionReveal)
            #expect(state.expandedSidebarGroups.contains(group))
        }
    }

    @Test(arguments: [false, true])
    func worktreeReselectionRevealsOnceForLocalAndAdoptedRows(adopted: Bool) {
        withState { state, repo in
            let parent = SidebarGroupFixtures.row("parent", repoID: repo, remote: "parent")
            let child = SidebarGroupFixtures.row("child", repoID: repo,
                                                remote: adopted ? "child" : nil, parent: parent.id)
            state.worktrees[repo] = [parent, child]
            state.remoteSessions = [SidebarGroupFixtures.session("parent", repoID: repo),
                                    SidebarGroupFixtures.session("child", repoID: repo)]
            state.selectedWorktreeIDs = [child.id]
            let first = state.sidebarSelectionReveal
            let generation = state.sidebarSelectionGeneration
            state.revealSidebarGroups(first)
            let group = SidebarGroupID(owner: .repository(repo), kind: .remote)
            #expect(state.expandedSidebarGroups.contains(group))
            state.toggleSidebarGroup(group)
            state.selectedWorktreeIDs = [child.id]
            #expect(state.sidebarSelectionGeneration == generation + 1)
            #expect(state.sidebarSelectionReveal != first)
            state.revealSidebarGroups(state.sidebarSelectionReveal)
            #expect(state.expandedSidebarGroups.contains(group))
        }
    }

    @Test func clearingSelectionsChangesTheTargetWithoutIncrementingGeneration() {
        withState { state, repo in
            let row = SidebarGroupFixtures.row("local", repoID: repo)
            state.worktrees[repo] = [row]
            state.selectedWorktreeIDs = [row.id]
            let local = state.sidebarSelectionReveal
            let localGeneration = state.sidebarSelectionGeneration
            state.selectedWorktreeIDs = []
            #expect(state.sidebarSelectionGeneration == localGeneration)
            #expect(state.sidebarSelectionReveal != local)

            state.selectedRemoteSession = .init(provider: "acme", sessionID: "worker")
            let remote = state.sidebarSelectionReveal
            let remoteGeneration = state.sidebarSelectionGeneration
            state.selectedRemoteSession = nil
            #expect(state.sidebarSelectionGeneration == remoteGeneration)
            #expect(state.sidebarSelectionReveal != remote)
        }
    }

    @Test func siblingExitRevealsInnerGroupWithoutReopeningCollapsedRepository() {
        withState { state, repo in
            let root = SidebarGroupFixtures.row("parent", repoID: repo, remote: "parent")
            let selected = SidebarGroupFixtures.row("selected", repoID: repo, remote: "selected", parent: root.id)
            let sibling = SidebarGroupFixtures.row("sibling", repoID: repo, remote: "sibling", parent: root.id)
            state.worktrees[repo] = [root, selected, sibling]
            state.remoteSessions = [
                SidebarGroupFixtures.session("parent", state: .exited, repoID: repo),
                SidebarGroupFixtures.session("selected", state: .exited, repoID: repo),
                SidebarGroupFixtures.session("sibling", repoID: repo)
            ]
            state.selectedWorktreeIDs = [selected.id]
            let initial = state.sidebarSelectionReveal
            let remote = SidebarGroupID(owner: .repository(repo), kind: .remote)
            let exited = SidebarGroupID(owner: .repository(repo), kind: .exited)
            let childRemote = SidebarGroupID(owner: .parent(root.id), kind: .remote)
            let childExited = SidebarGroupID(owner: .parent(root.id), kind: .exited)
            #expect(initial.groups == [remote, childRemote, childExited])
            state.revealSidebarGroups(initial)
            state.repos[0].expanded = false

            // An unrelated state update leaves membership and the observer's
            // signature unchanged, so it does not trigger any reveal.
            state.remoteSessions[2] = SidebarGroupFixtures.session("sibling", state: .starting, repoID: repo)
            #expect(state.sidebarSelectionReveal == initial)
            #expect(!state.repos[0].expanded)

            // The last continuing sibling exits, moving the selected row's
            // whole subtree beneath Exited without any navigation gesture.
            state.remoteSessions[2] = SidebarGroupFixtures.session("sibling", state: .exited, repoID: repo)
            let moved = state.sidebarSelectionReveal
            #expect(moved.generation == initial.generation)
            #expect(moved.groups == [remote, exited, childRemote, childExited])
            state.revealSidebarGroups(moved, previous: initial)
            #expect(state.expandedSidebarGroups.contains(exited))
            #expect(!state.repos[0].expanded)

            // Explicitly re-selecting that same row still reveals its owner.
            state.selectedWorktreeIDs = [selected.id]
            state.revealSidebarGroups(state.sidebarSelectionReveal, previous: moved)
            #expect(state.repos[0].expanded)
        }
    }

    @Test func initialAndExplicitScrollRevealsCanExpandTheOwningRepository() {
        withState { state, repo in
            state.remoteSessions = [SidebarGroupFixtures.session("worker", repoID: repo)]
            let reveal = state.sidebarGroupReveal(
                worktreeIDs: [], selection: .init(provider: "acme", sessionID: "worker"))
            state.repos[0].expanded = false
            state.revealSidebarGroups(reveal)
            #expect(state.repos[0].expanded)
            state.repos[0].expanded = false
            state.revealSidebarGroups(reveal, previous: reveal)
            #expect(!state.repos[0].expanded)
            state.revealSidebarGroups(reveal)
            #expect(state.repos[0].expanded)
        }
    }

    @Test func targetIdentityChangeRevealsWithoutNeedingAGenerationChange() {
        withState { state, repo in
            state.remoteSessions = [SidebarGroupFixtures.session("worker", repoID: repo)]
            let initial = state.sidebarGroupReveal(worktreeIDs: [], selection: nil)
            let target = state.sidebarGroupReveal(
                worktreeIDs: [], selection: .init(provider: "acme", sessionID: "worker"))
            #expect(initial.generation == target.generation)
            state.repos[0].expanded = false
            state.revealSidebarGroups(target, previous: initial)
            #expect(state.repos[0].expanded)
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
