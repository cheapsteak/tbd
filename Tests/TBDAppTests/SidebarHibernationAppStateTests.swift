import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
@Suite("Sidebar hibernation integration")
struct SidebarHibernationAppStateTests {
    private func withState(_ body: (AppState, UUID) -> Void) {
        let suite = "SidebarHibernationAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(userDefaults: defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        body(state, repo.id)
    }

    private func park(_ row: Worktree, in state: AppState) {
        state.terminals[row.id] = [Terminal(
            worktreeID: row.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude,
            hibernatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
    }

    @Test func selectedCrossRepositoryDescendantRevealsOwnersShelf() {
        withState { state, repoID in
            let otherRepo = Repo(path: "/tmp/acme-web", displayName: "acme/web")
            state.repos.append(otherRepo)
            let parent = SidebarGroupFixtures.row("parent", repoID: repoID)
            let child = SidebarGroupFixtures.row("child", repoID: otherRepo.id, parent: parent.id)
            state.worktrees = [repoID: [parent], otherRepo.id: [child]]
            park(parent, in: state)
            park(child, in: state)
            let reveal = state.sidebarGroupReveal(worktreeIDs: [child.id], selection: nil)
            #expect(reveal.groups == [.init(owner: .repository(repoID), kind: .hibernated)])
            #expect(state.sidebarHibernation(repoID: repoID).hibernatedCount == 2)
            #expect(state.sidebarHibernation(repoID: otherRepo.id).hibernatedCount == 0)
        }
    }

    @Test func parkedSelectionDoesNotUndoManualCollapseUntilReselection() {
        withState { state, repoID in
            let row = SidebarGroupFixtures.row("parked", repoID: repoID)
            state.worktrees[repoID] = [row]
            park(row, in: state)
            state.selectedWorktreeIDs = [row.id]
            let reveal = state.sidebarSelectionReveal
            let group = SidebarGroupID(owner: .repository(repoID), kind: .hibernated)
            state.revealSidebarGroups(reveal)
            #expect(state.expandedSidebarGroups == [group])
            state.toggleSidebarGroup(group)
            let same = state.terminals
            state.terminals = same
            #expect(state.sidebarSelectionReveal == reveal)
            #expect(state.expandedSidebarGroups.isEmpty)
            state.selectedWorktreeIDs = [row.id]
            #expect(state.sidebarSelectionReveal != reveal)
            state.revealSidebarGroups(state.sidebarSelectionReveal)
            #expect(state.expandedSidebarGroups == [group])
            #expect(state.terminals[row.id]?.first?.isParked == true)
        }
    }

    @Test func parkAndWakeChangeSelectedMembershipWithoutChangingSelection() {
        withState { state, repoID in
            let row = SidebarGroupFixtures.row("task", repoID: repoID)
            state.worktrees[repoID] = [row]
            state.selectedWorktreeIDs = [row.id]
            let initial = state.sidebarSelectionReveal
            #expect(initial.groups.isEmpty)
            park(row, in: state)
            let parked = state.sidebarSelectionReveal
            #expect(parked != initial)
            state.revealSidebarGroups(parked)
            #expect(state.expandedSidebarGroups.contains(.init(owner: .repository(repoID), kind: .hibernated)))
            state.terminals[row.id]?[0].hibernatedAt = nil
            #expect(state.sidebarSelectionReveal.groups.isEmpty)
            #expect(state.sidebarHibernation(repoID: repoID).workingRoots == [row])
            #expect(state.selectedWorktreeIDs == [row.id])
            #expect(state.recentlyAttachedRemoteSessions.isEmpty)
        }
    }

    @Test func scratchNavigationExpandsScratchAndItsShelf() {
        withState { state, _ in
            let scratch = Worktree(repoID: nil, name: "scratch", displayName: "Scratch task",
                                   branch: "", path: "/tmp/acme-scratch", tmuxServer: "acme")
            state.scratchWorktrees = [scratch]
            park(scratch, in: state)
            state.userDefaults.set(false, forKey: AppState.scratchSectionExpandedKey)
            let reveal = state.sidebarGroupReveal(worktreeIDs: [scratch.id], selection: nil)
            #expect(reveal.groups == [.init(owner: .scratch, kind: .hibernated)])
            state.revealSidebarGroups(reveal)
            #expect(state.userDefaults.bool(forKey: AppState.scratchSectionExpandedKey))
            #expect(state.expandedSidebarGroups == [.init(owner: .scratch, kind: .hibernated)])
            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.terminals[scratch.id]?.first?.isParked == true)
            #expect(state.recentlyAttachedRemoteSessions.isEmpty)
        }
    }

    @Test func scratchMembershipChangePreservesCollapsedSectionUntilNavigation() {
        withState { state, _ in
            let scratch = Worktree(repoID: nil, name: "scratch", displayName: "Scratch task",
                                   branch: "", path: "/tmp/acme-scratch", tmuxServer: "acme")
            state.scratchWorktrees = [scratch]
            state.selectedWorktreeIDs = [scratch.id]
            let initial = state.sidebarSelectionReveal
            state.userDefaults.set(false, forKey: AppState.scratchSectionExpandedKey)

            park(scratch, in: state)
            let parked = state.sidebarSelectionReveal
            #expect(parked.groups == [.init(owner: .scratch, kind: .hibernated)])
            state.revealSidebarGroups(parked, previous: initial)
            #expect(!state.userDefaults.bool(forKey: AppState.scratchSectionExpandedKey))
            #expect(state.expandedSidebarGroups.contains(.init(owner: .scratch, kind: .hibernated)))

            state.selectedWorktreeIDs = [scratch.id]
            state.revealSidebarGroups(state.sidebarSelectionReveal, previous: parked)
            #expect(state.userDefaults.bool(forKey: AppState.scratchSectionExpandedKey))
        }
    }

    @Test func shelfToggleDoesNotSelectWakeOrClearUnread() {
        withState { state, repoID in
            let row = SidebarGroupFixtures.row("parked", repoID: repoID)
            state.worktrees[repoID] = [row]
            park(row, in: state)
            state.unreadByWorktree[row.id] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
            let unread = state.unreadByWorktree
            let terminals = state.terminals
            let group = SidebarGroupID(owner: .repository(repoID), kind: .hibernated)
            state.toggleSidebarGroup(group)
            #expect(state.expandedSidebarGroups == [group])
            state.toggleSidebarGroup(group)
            #expect(state.expandedSidebarGroups.isEmpty)
            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.terminals == terminals)
            #expect(state.unreadByWorktree == unread)
            #expect(state.recentlyAttachedRemoteSessions.isEmpty)
        }
    }

    @Test func flatScratchShelfExcludesRootsWithDescendants() {
        withState { state, repoID in
            let scratch = Worktree(repoID: nil, name: "scratch", displayName: "Scratch task",
                                   branch: "", path: "/tmp/acme-scratch", tmuxServer: "acme")
            let leaf = Worktree(repoID: nil, name: "leaf", displayName: "Leaf task",
                                branch: "", path: "/tmp/acme-leaf", tmuxServer: "acme")
            state.scratchWorktrees = [scratch, leaf]
            park(scratch, in: state)
            park(leaf, in: state)
            #expect(state.sidebarScratchHibernation.hibernatedCount == 2)
            let child = SidebarGroupFixtures.row("child", repoID: repoID, parent: scratch.id)
            park(child, in: state)
            state.worktrees[repoID] = [child]
            let partition = state.sidebarScratchHibernation
            #expect(partition.workingRoots == [scratch])
            #expect(partition.hibernatedRoots == [leaf])
            #expect(partition.hibernatedWorktreeIDs == [leaf.id])
            #expect(partition.hibernatedCount == 1)
            #expect(state.sidebarGroupReveal(worktreeIDs: [child.id], selection: nil).groups.isEmpty)
        }
    }

    @Test func cacheInvalidatesForTreeAndScratchChanges() {
        withState { state, repoID in
            let root = SidebarGroupFixtures.row("parent", repoID: repoID)
            state.worktrees[repoID] = [root]
            park(root, in: state)
            #expect(state.sidebarHibernation(repoID: repoID).hibernatedCount == 1)
            let child = SidebarGroupFixtures.row("unloaded child", repoID: repoID, parent: root.id)
            state.worktrees[repoID]?.append(child)
            #expect(state.sidebarHibernation(repoID: repoID).hibernatedCount == 0)
            park(child, in: state)
            #expect(state.sidebarHibernation(repoID: repoID).hibernatedCount == 2)

            #expect(state.sidebarScratchHibernation.hibernatedCount == 0)
            let scratch = Worktree(repoID: nil, name: "scratch", displayName: "Scratch task",
                                   branch: "", path: "/tmp/acme-scratch", tmuxServer: "acme")
            park(scratch, in: state)
            state.scratchWorktrees = [scratch]
            #expect(state.sidebarScratchHibernation.hibernatedCount == 1)
            state.scratchWorktrees = []
            #expect(state.sidebarScratchHibernation.hibernatedCount == 0)
        }
    }

    @Test func reorderingEitherShelfPreservesTheOtherShelfsSlots() {
        let workingA = UUID(), parkedA = UUID(), remote = UUID(), parkedB = UUID(), workingB = UUID()
        let all = [workingA, parkedA, remote, parkedB, workingB]
        #expect(SidebarSubsetOrder.moved(
            all: all, visible: [workingA, workingB], source: [0], destination: 2
        ) == [workingB, parkedA, remote, parkedB, workingA])
        #expect(SidebarSubsetOrder.moved(
            all: all, visible: [parkedA, parkedB], source: [1], destination: 0
        ) == [workingA, parkedB, remote, parkedA, workingB])
    }
}
