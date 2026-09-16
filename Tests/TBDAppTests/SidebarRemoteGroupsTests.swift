import Foundation
import Testing
@testable import TBDApp
import TBDShared

enum SidebarGroupFixtures {
    static func provider(health: ProviderHealth = .ok) -> RemoteProviderStatus {
        RemoteProviderStatus(config: .init(name: "acme", exec: "/bin/false"), describe: nil,
                             health: health, errorMessage: nil, remediationLabel: nil,
                             remediationCommand: nil, lastSuccessfulSnapshotAt: Date())
    }

    static func session(_ id: String, state: RemoteProcessState = .running,
                        gone: Bool = false, dismissed: Bool = false, archived: Bool = false,
                        repoID: UUID? = nil, agent: RemoteAgentState = .idle) -> RemoteSessionInfo {
        RemoteSessionInfo(provider: "acme", payload: .init(id: id, state: state, agentState: agent, archived: archived),
                          gone: gone, dismissed: dismissed, lastSeen: Date(), resolvedRepoID: repoID)
    }

    static func row(_ name: String, repoID: UUID, remote: String? = nil, parent: UUID? = nil,
                    order: Int = 0, status: WorktreeStatus = .active) -> Worktree {
        let location = remote.map { WorktreeLocation.remote(provider: "acme", sessionID: $0) } ?? .local
        return Worktree(repoID: repoID, name: name, displayName: name, branch: "feature",
                        path: location.storagePath ?? "/tmp/acme", status: status, tmuxServer: "acme",
                        sortOrder: order, parentWorktreeID: parent, location: location)
    }

    static func groups(roots: [Worktree] = [], remainder: [RemoteSessionInfo] = [],
                       rows: [Worktree] = [], sessions: [RemoteSessionInfo] = [],
                       providers: [RemoteProviderStatus] = [provider()],
                       unread: [RemoteSessionSelection: UnreadSummary] = [:]) -> SidebarRemoteGroups {
        SidebarRemoteGroups(roots: roots, remainder: remainder, allWorktrees: rows,
                            inventory: sessions, providers: providers, unread: unread)
    }
}

@Suite("Sidebar remote groups")
struct SidebarRemoteGroupsTests {
    @Test func groupsAdoptedRootsAndDeduplicatesTheirMirrorRows() {
        let repo = UUID()
        let local = SidebarGroupFixtures.row("director", repoID: repo)
        let remote = SidebarGroupFixtures.row("worker", repoID: repo, remote: "one")
        let session = SidebarGroupFixtures.session("one")
        let groups = SidebarGroupFixtures.groups(roots: [local, remote], remainder: [session], sessions: [session])
        #expect(groups.localRoots.map(\.id) == [local.id])
        #expect(groups.remoteRoots.map(\.id) == [remote.id])
        #expect(groups.sessions.isEmpty)
        #expect(groups.summary.counts == [.running: 1])
    }

    @Test func countsEveryProcessStateWithoutTreatingAgentWorkingAsRunning() {
        let sessions = [SidebarGroupFixtures.session("run"), SidebarGroupFixtures.session("start", state: .starting),
                        SidebarGroupFixtures.session("exit", state: .exited),
                        SidebarGroupFixtures.session("unknown", state: .unknown, agent: .working),
                        SidebarGroupFixtures.session("gone", gone: true)]
        let groups = SidebarGroupFixtures.groups(remainder: sessions)
        #expect(groups.summary.counts == [.running: 1, .starting: 1, .exited: 1, .unknown: 1, .gone: 1])
        #expect(groups.exitedSessions.map(\.payload.id) == ["exit"])
        #expect(groups.sessions.count == 4)
    }

    @Test func staleAndMissingProviderNeverFileAnExitedSessionAsConfirmed() {
        let session = SidebarGroupFixtures.session("exit", state: .exited)
        for providers in [[], [SidebarGroupFixtures.provider(health: .stale)]] {
            let groups = SidebarGroupFixtures.groups(remainder: [session], providers: providers)
            #expect(groups.exitedSessions.isEmpty)
            #expect(groups.summary.counts == [.unknown: 1])
        }
    }

    @Test func missingMirrorCountsAnAdoptedLaneAsUnknown() {
        let row = SidebarGroupFixtures.row("worker", repoID: UUID(), remote: "missing")
        let groups = SidebarGroupFixtures.groups(roots: [row])
        #expect(groups.summary.counts == [.unknown: 1])
        #expect(groups.remoteRoots.map(\.id) == [row.id])
    }

    @Test func activeOrUncertainDescendantsKeepAnExitedParentOutsideExited() {
        let repo = UUID()
        let root = SidebarGroupFixtures.row("parent", repoID: repo, remote: "parent")
        let exited = SidebarGroupFixtures.session("parent", state: .exited)
        let local = SidebarGroupFixtures.row("local child", repoID: UUID(), parent: root.id)
        let remote = SidebarGroupFixtures.row("remote child", repoID: UUID(), remote: "child", parent: root.id)
        for child in [local, remote] {
            let groups = SidebarGroupFixtures.groups(roots: [root], rows: [root, child], sessions: [exited])
            #expect(groups.exitedRoots.isEmpty)
            #expect(groups.remoteWorktreeIDs.contains(child.id))
        }
        for state in [RemoteProcessState.running, .starting, .unknown] {
            let groups = SidebarGroupFixtures.groups(roots: [root], rows: [root, remote],
                sessions: [exited, SidebarGroupFixtures.session("child", state: state)])
            #expect(groups.exitedRoots.isEmpty)
        }
    }

    @Test func whollyExitedSubtreeMovesTogetherAndRevealsByDescendant() {
        let root = SidebarGroupFixtures.row("parent", repoID: UUID(), remote: "parent")
        let child = SidebarGroupFixtures.row("child", repoID: UUID(), remote: "child", parent: root.id)
        let sessions = [SidebarGroupFixtures.session("parent", state: .exited),
                        SidebarGroupFixtures.session("child", state: .exited)]
        let groups = SidebarGroupFixtures.groups(roots: [root], rows: [root, child], sessions: sessions)
        let owner = SidebarGroupID.Owner.repository(root.repoID!)
        #expect(groups.exitedRoots.map(\.id) == [root.id])
        #expect(groups.exitedSummary.counts == [.exited: 2])
        #expect(groups.revealGroups(owner: owner, worktreeIDs: [child.id], remoteID: nil)
                == [.init(owner: owner, kind: .remote), .init(owner: owner, kind: .exited)])
    }

    @Test func cycleCannotBeClassifiedAsAnExitedSubtree() {
        var root = SidebarGroupFixtures.row("parent", repoID: UUID(), remote: "parent")
        let child = SidebarGroupFixtures.row("child", repoID: root.repoID!, remote: "child", parent: root.id)
        root.parentWorktreeID = child.id
        let groups = SidebarGroupFixtures.groups(roots: [root], rows: [root, child], sessions: [
            SidebarGroupFixtures.session("parent", state: .exited), SidebarGroupFixtures.session("child", state: .exited)])
        #expect(groups.exitedRoots.isEmpty)
        #expect(groups.summary.counts == [.exited: 2])
    }

    @Test func preservesRootOrderAndExcludesDismissedAndArchivedRemainders() {
        let repo = UUID()
        let first = SidebarGroupFixtures.row("first", repoID: repo, remote: "first")
        let second = SidebarGroupFixtures.row("second", repoID: repo, remote: "second")
        let groups = SidebarGroupFixtures.groups(roots: [second, first], remainder: [
            SidebarGroupFixtures.session("dismissed", dismissed: true),
            SidebarGroupFixtures.session("archived", archived: true)])
        #expect(groups.remoteRoots.map(\.id) == [second.id, first.id])
        #expect(groups.sessions.isEmpty)
    }

    @Test func waitingInputAndUnreadRemainVisibleInCollapsedSummary() {
        let sessions = [SidebarGroupFixtures.session("wait", agent: .waitingInput)]
        let key = RemoteSessionSelection(provider: "acme", sessionID: "wait")
        let waiting = SidebarGroupFixtures.groups(remainder: sessions)
        #expect(waiting.summary.attention == .attentionNeeded)
        let error = SidebarGroupFixtures.groups(remainder: sessions,
            unread: [key: UnreadSummary(type: .error, mostRecentAt: Date())])
        #expect(error.summary.attention == .error)
    }

    @Test func emptyGroupsNeedNoDisclosureAndMirrorSelectionRevealsExited() {
        #expect(SidebarGroupFixtures.groups().isEmpty)
        let session = SidebarGroupFixtures.session("exit", state: .exited)
        let groups = SidebarGroupFixtures.groups(remainder: [session])
        let owner = SidebarGroupID.Owner.provider("acme")
        #expect(groups.revealGroups(owner: owner, worktreeIDs: [], remoteID: session.id).count == 2)
        #expect(groups.revealGroups(owner: owner, worktreeIDs: [UUID()], remoteID: nil).isEmpty)
    }
}

@Suite("Sidebar visible subset reorder")
struct SidebarSubsetOrderTests {
    @Test func reordersOnlyTheVisibleSlots() {
        let ids = (0..<5).map { _ in UUID() }
        #expect(SidebarSubsetOrder.moved(all: ids, visible: [ids[0], ids[2], ids[4]],
            source: [0], destination: 3) == [ids[2], ids[1], ids[4], ids[3], ids[0]])
        #expect(SidebarSubsetOrder.moved(all: ids, visible: [ids[0], ids[2], ids[4]],
            source: [0, 2], destination: 1) == [ids[0], ids[1], ids[4], ids[3], ids[2]])
    }

    @Test func rejectsStaleDuplicateAndMissingIdentitiesAndBadIndices() {
        let ids = (0..<3).map { _ in UUID() }
        let invalid = [[ids[0], ids[0]], [UUID()], [ids[2], ids[0]], []]
        for visible in invalid {
            #expect(SidebarSubsetOrder.moved(all: ids, visible: visible, source: [0], destination: 1) == nil)
        }
        #expect(SidebarSubsetOrder.moved(all: [ids[0], ids[0]], visible: [ids[0]], source: [0], destination: 1) == nil)
        #expect(SidebarSubsetOrder.moved(all: ids, visible: ids, source: [3], destination: 1) == nil)
        #expect(SidebarSubsetOrder.moved(all: ids, visible: ids, source: [0], destination: -1) == nil)
        #expect(SidebarSubsetOrder.moved(all: ids, visible: ids, source: [0], destination: 4) == nil)
    }
}
