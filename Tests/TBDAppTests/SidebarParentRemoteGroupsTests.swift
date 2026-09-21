import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Sidebar parent remote groups")
struct SidebarParentRemoteGroupsTests {
    private func snapshot(_ rows: [Worktree], sessions: [RemoteSessionInfo] = []) -> SidebarRemoteGroups.Snapshot {
        .init(worktrees: rows, sessions: sessions, providers: [SidebarGroupFixtures.provider()])
    }

    @Test func childPartitionPreservesLocalAndRemoteSiblingOrder() {
        let repo = UUID()
        let parent = SidebarGroupFixtures.row("director", repoID: repo)
        let local = SidebarGroupFixtures.row("local", repoID: repo, parent: parent.id, order: 2)
        let first = SidebarGroupFixtures.row("first", repoID: repo, remote: "first", parent: parent.id, order: 1)
        let last = SidebarGroupFixtures.row("last", repoID: repo, remote: "last", parent: parent.id, order: 3)
        let state = snapshot([parent, last, local, first])
        let groups = SidebarRemoteGroups(
            roots: state.children[parent.id] ?? [], remainder: [], snapshot: state, unread: [:])
        #expect(groups.localRoots.map(\.id) == [local.id])
        #expect(groups.remoteRoots.map(\.id) == [first.id, last.id])
        #expect(groups.summary.counts == [.unknown: 2])
    }

    @Test func selectedNestedMirrorRevealsEveryContainingRemoteAndExitedGroup() {
        let repo = UUID()
        let director = SidebarGroupFixtures.row("director", repoID: repo)
        let worker = SidebarGroupFixtures.row("worker", repoID: repo, remote: "worker", parent: director.id)
        let child = SidebarGroupFixtures.row("child", repoID: repo, remote: "child", parent: worker.id)
        let state = snapshot([director, worker, child], sessions: [
            SidebarGroupFixtures.session("worker", state: .exited),
            SidebarGroupFixtures.session("child", state: .exited)
        ])
        let target = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "child")
        let expected: Set<SidebarGroupID> = [
            .init(owner: .parent(director.id), kind: .remote),
            .init(owner: .parent(director.id), kind: .exited),
            .init(owner: .parent(worker.id), kind: .remote),
            .init(owner: .parent(worker.id), kind: .exited)
        ]
        #expect(state.parentRevealGroups(worktreeIDs: [], remoteID: target, repoIDs: [repo]) == expected)
        #expect(state.parentRevealGroups(worktreeIDs: [child.id], remoteID: nil, repoIDs: [repo]) == expected)
    }

    @Test func localDescendantKeepsExitedParentVisibleInOuterRemoteGroup() {
        let ownerRepo = UUID()
        let director = SidebarGroupFixtures.row("director", repoID: ownerRepo)
        let worker = SidebarGroupFixtures.row("worker", repoID: ownerRepo, remote: "worker", parent: director.id)
        let local = SidebarGroupFixtures.row("local", repoID: UUID(), parent: worker.id)
        let state = snapshot([director, worker, local], sessions: [SidebarGroupFixtures.session("worker", state: .exited)])
        #expect(state.parentRevealGroups(worktreeIDs: [local.id], remoteID: nil, repoIDs: [ownerRepo])
                == [.init(owner: .parent(director.id), kind: .remote)])
        #expect(state.parentRevealGroups(worktreeIDs: [local.id], remoteID: nil, repoIDs: [local.repoID!]).isEmpty)
    }

    @Test func landedLocalOriginIsNotAnAdoptedMirrorOwner() {
        let repo = UUID()
        let director = SidebarGroupFixtures.row("director", repoID: repo)
        let remote = SidebarGroupFixtures.row("remote", repoID: repo, remote: "remote", parent: director.id)
        var landed = SidebarGroupFixtures.row("landed", repoID: repo, parent: remote.id)
        landed.origin = WorktreeOrigin(provider: "acme", sessionID: "landed-origin")
        let state = snapshot([director, remote, landed])
        let originID = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "landed-origin")
        let remoteID = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "remote")

        #expect(state.rowIDsBySession[originID] == nil)
        #expect(state.rowIDsBySession[remoteID] == [remote.id])
        #expect(state.parentRevealGroups(worktreeIDs: [], remoteID: originID, repoIDs: [repo]).isEmpty)
        // Selecting the local row itself still reveals its actual remote parent.
        #expect(state.parentRevealGroups(worktreeIDs: [landed.id], remoteID: nil, repoIDs: [repo])
                == [.init(owner: .parent(director.id), kind: .remote)])
    }

    @Test func missingParentAndCyclesDoNotInventRevealPaths() {
        let repo = UUID()
        var first = SidebarGroupFixtures.row("first", repoID: repo, remote: "first", parent: UUID())
        let child = SidebarGroupFixtures.row("child", repoID: repo, remote: "child", parent: first.id)
        #expect(snapshot([first, child]).ancestorPath(to: child.id) == nil)
        first.parentWorktreeID = child.id
        let state = snapshot([first, child])
        #expect(state.ancestorPath(to: child.id) == nil)
        #expect(state.parentRevealGroups(worktreeIDs: [child.id], remoteID: nil, repoIDs: [repo]).isEmpty)
    }

    @Test func ancestorBoundCountsWorktreesRatherThanDisclosures() {
        let repo = UUID()
        var rows = [SidebarGroupFixtures.row("root", repoID: repo)]
        for index in 1...51 {
            rows.append(SidebarGroupFixtures.row("row-\(index)", repoID: repo,
                                                remote: "row-\(index)", parent: rows.last!.id))
        }
        let state = snapshot(rows)
        #expect(state.ancestorPath(to: rows[50].id)?.count == 51)
        #expect(state.ancestorPath(to: rows[51].id) == nil)
    }

    @Test func scratchAndMainOwnershipRemainKnownWithoutAddingUnrenderedGroups() {
        let repo = UUID()
        var scratch = SidebarGroupFixtures.row("scratch", repoID: repo)
        scratch.repoID = nil
        let main = SidebarGroupFixtures.row("main", repoID: repo, status: .main)
        for parent in [scratch, main] {
            let child = SidebarGroupFixtures.row("worker", repoID: repo, remote: "worker", parent: parent.id)
            let state = snapshot([parent, child])
            #expect(state.ancestorPath(to: child.id)?.map(\.id) == [parent.id, child.id])
            #expect(state.parentRevealGroups(worktreeIDs: [child.id], remoteID: nil, repoIDs: [repo]).isEmpty)
        }
    }
}

@MainActor
@Suite("Sidebar parent group state")
struct SidebarParentGroupStateTests {
    private func withState(_ body: (AppState, UUID) -> Void) {
        let suite = "SidebarParentGroupStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(userDefaults: defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        body(state, repo.id)
    }

    @Test func scratchSnapshotInvalidatesWhenParentRowsChange() {
        withState { state, repo in
            var scratch = SidebarGroupFixtures.row("scratch", repoID: repo)
            scratch.repoID = nil
            state.scratchWorktrees = [scratch]
            #expect(state.sidebarRemoteSnapshot.rowsByID[scratch.id]?.displayName == "scratch")
            scratch.displayName = "renamed scratch"
            state.scratchWorktrees = [scratch]
            #expect(state.sidebarRemoteSnapshot.rowsByID[scratch.id]?.displayName == "renamed scratch")
        }
    }

    @Test func parentDisclosureDoesNotSelectAttachOrClearUnread() {
        withState { state, repo in
            let parent = SidebarGroupFixtures.row("director", repoID: repo)
            let key = RemoteSessionSelection(provider: "acme", sessionID: "worker")
            state.unreadByRemoteSession[key] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
            let group = SidebarGroupID(owner: .parent(parent.id), kind: .remote)
            state.toggleSidebarGroup(group)
            #expect(state.expandedSidebarGroups == [group])
            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.selectedRemoteSession == nil)
            #expect(state.recentlyAttachedRemoteSessions.isEmpty)
            #expect(state.unreadByRemoteSession[key] != nil)
        }
    }
    @Test func nestedMembershipDoesNotReopenRepositoryButNavigationDoes() {
        withState { state, repo in
            let director = SidebarGroupFixtures.row("director", repoID: repo)
            let worker = SidebarGroupFixtures.row("worker", repoID: repo, remote: "worker", parent: director.id)
            state.worktrees[repo] = [director, worker]
            state.remoteSessions = [SidebarGroupFixtures.session("worker", repoID: repo)]
            state.selectedRemoteSession = .init(provider: "acme", sessionID: "worker")
            let initial = state.sidebarSelectionReveal
            let remote = SidebarGroupID(owner: .parent(director.id), kind: .remote)
            let exited = SidebarGroupID(owner: .parent(director.id), kind: .exited)
            #expect(initial.groups == [remote])
            state.revealSidebarGroups(initial)
            state.toggleSidebarGroup(remote)
            let sameInventory = state.remoteSessions
            state.remoteSessions = sameInventory
            #expect(state.sidebarSelectionReveal == initial)
            #expect(!state.expandedSidebarGroups.contains(remote))
            state.repos[0].expanded = false

            state.remoteSessions = [SidebarGroupFixtures.session("worker", state: .exited, repoID: repo)]
            let moved = state.sidebarSelectionReveal
            #expect(moved.groups == [remote, exited])
            state.revealSidebarGroups(moved, previous: initial)
            #expect(state.expandedSidebarGroups.contains(exited))
            #expect(!state.repos[0].expanded)

            state.selectedRemoteSession = .init(provider: "acme", sessionID: "worker")
            state.revealSidebarGroups(state.sidebarSelectionReveal, previous: moved)
            #expect(state.repos[0].expanded)
            #expect(state.recentlyAttachedRemoteSessions.isEmpty)
        }
    }

}
