import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. The tree is built at a fixed
// time with an injected directory probe, so nothing touches the disk.

/// A repo's registry filter applied to the sidebar it builds: ungrouped and
/// grouped, the Remote, Exited and Ended groups, the selection exception, the
/// header button's state, and the sections it must leave alone.
/// Spec: docs/specs/2026-11-19-sidebar-remote-session-filter-design.md, "Testing".
@MainActor
@Suite("Sidebar registry filter layouts")
struct SidebarRegistryFilterLayoutTests {
    // MARK: Ungrouped

    @Test func filterOffLeavesTheSectionAsItWas() throws {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.off")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let main = Self.row("main", repo: repo, status: .main)
        let lane = Self.row("lane", repo: repo, order: 0)
        let worker = Self.row("worker", repo: repo, remote: "worker", order: 1)
        let loose = Self.session("loose", repoID: repo)
        state.worktrees = [repo: [main, lane, worker]]
        state.remoteSessions = [loose]

        let tree = Self.build(state)
        let children = Self.childIDs(tree, of: .repoHeader(repo))
        #expect(children == [.worktree(main.id), .worktree(lane.id), .worktree(worker.id), .remoteSession(loose.id)])
        let button = try #require(Self.header(tree, repo)?.registryFilter)
        #expect(button == SidebarRegistryFilterButton(isOn: false, count: 0, providerNames: ["acme"]))
    }

    @Test func ungroupedFilterDropsRegistryWorkAndKeepsStoredOrder() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.ungroupedOrder")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let main = Self.row("main", repo: repo, status: .main)
        let first = Self.row("first", repo: repo, order: 0)
        let registry = Self.row("registry", repo: repo, remote: "registry", order: 1)
        let cloud = Self.cloudRow("cloud", repo: repo, order: 2)
        let second = Self.row("second", repo: repo, order: 3)
        let loose = Self.session("loose", repoID: repo)
        let looseCloud = Self.cloudSession("loose-cloud", repoID: repo)
        state.worktrees = [repo: [main, first, registry, cloud, second]]
        state.remoteSessions = [loose, looseCloud]

        let before = Self.childIDs(Self.build(state), of: .repoHeader(repo))
        #expect(before.contains(.worktree(registry.id)))
        #expect(before.contains(.remoteSession(loose.id)))

        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        let after = Self.childIDs(Self.build(state), of: .repoHeader(repo))
        #expect(after == [.worktree(main.id), .worktree(first.id), .worktree(cloud.id), .worktree(second.id),
                          .remoteSession(looseCloud.id)])
    }

    @Test func ungroupedFilterHidesARegistryChildUnderALocalLane() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.childUnderLane")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let lane = Self.row("lane", repo: repo)
        let worker = Self.row("worker", repo: repo, remote: "worker", parent: lane.id)
        state.worktrees = [repo: [lane, worker]]
        #expect(Self.build(state).parent(of: .worktree(worker.id)) == .worktree(lane.id))

        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        let tree = Self.build(state)
        #expect(tree.parent(of: .worktree(lane.id)) == .repoHeader(repo))
        #expect(!tree.contains(.worktree(worker.id)))
        #expect(Self.childIDs(tree, of: .worktree(lane.id)).isEmpty)
    }

    @Test func aKeptChildKeepsItsRegistryAncestorsInBothModes() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.keptAncestors")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let registry = Self.row("registry", repo: repo, remote: "registry")
        let local = Self.row("local", repo: repo, parent: registry.id)
        state.worktrees = [repo: [registry, local]]
        state.expandedSidebarGroups.insert(Self.remoteGroup(repo))
        state.toggleSidebarRegistryRemoteFilter(repoID: repo)

        for grouped in [false, true] {
            let tree = Self.build(state, groups: grouped)
            #expect(tree.contains(.worktree(registry.id)), "grouped: \(grouped)")
            #expect(tree.parent(of: .worktree(local.id)) == .worktree(registry.id), "grouped: \(grouped)")
            #expect(Self.header(tree, repo)?.registryFilter == nil,
                    "Nothing is left to hide, so no button; grouped: \(grouped)")
        }
    }

    // MARK: Grouped

    @Test func groupedRemoteGroupKeepsCloudWorkAndCountsOnlyIt() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.groupedRemote")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let main = Self.row("main", repo: repo, status: .main)
        let registry = Self.row("registry", repo: repo, remote: "registry", order: 0)
        let cloud = Self.cloudRow("cloud", repo: repo, order: 1)
        let loose = Self.session("loose", repoID: repo)
        let looseCloud = Self.cloudSession("loose-cloud", repoID: repo)
        state.worktrees = [repo: [main, registry, cloud]]
        state.remoteSessions = [Self.session("registry", repoID: repo), Self.cloudSession("cloud", repoID: repo),
                                loose, looseCloud]
        let remote = Self.remoteGroup(repo)
        state.expandedSidebarGroups.insert(remote)

        let before = Self.build(state, groups: true)
        #expect(SidebarTreeBuilderTests.groupModel(before, remote)?.summary == "4 running")

        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        let after = Self.build(state, groups: true)
        #expect(Self.childIDs(after, of: .group(remote)) == [.worktree(cloud.id), .remoteSession(looseCloud.id)])
        #expect(SidebarTreeBuilderTests.groupModel(after, remote)?.summary == "2 running")
    }

    @Test func groupedRemoteGroupLeftEmptyDoesNotRender() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.groupedEmpty")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let lane = Self.row("lane", repo: repo, order: 0)
        let registry = Self.row("registry", repo: repo, remote: "registry", order: 1)
        let loose = Self.session("loose", repoID: repo)
        state.worktrees = [repo: [lane, registry]]
        state.remoteSessions = [loose]
        let remote = Self.remoteGroup(repo)
        state.expandedSidebarGroups.insert(remote)
        #expect(Self.build(state, groups: true).contains(.group(remote)))

        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        let tree = Self.build(state, groups: true)
        #expect(!tree.contains(.group(remote)))
        #expect(!tree.contains(.worktree(registry.id)))
        #expect(!tree.contains(.remoteSession(loose.id)))
        #expect(tree.parent(of: .worktree(lane.id)) == .repoHeader(repo))
    }

    @Test func exitedAndEndedRegistryWorkLeavesItsGroups() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.exitedEnded")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let cloud = Self.cloudRow("cloud", repo: repo, order: 0)
        let exitedRow = Self.row("exited", repo: repo, remote: "exited", order: 1)
        let endedSession = Self.session("ended", state: .exited, repoID: repo)
        state.worktrees = [repo: [cloud, exitedRow]]
        state.remoteSessions = [Self.cloudSession("cloud", repoID: repo),
                                Self.session("exited", state: .exited, repoID: repo), endedSession]
        let remote = Self.remoteGroup(repo)
        let exited = SidebarGroupID(owner: .repository(repo), kind: .exited)
        let ended = SidebarGroupID(owner: .repository(repo), kind: .ended)
        state.expandedSidebarGroups.formUnion([remote, exited, ended])

        let groupedBefore = Self.build(state, groups: true)
        #expect(groupedBefore.parent(of: .worktree(exitedRow.id)) == .group(exited))
        #expect(groupedBefore.parent(of: .remoteSession(endedSession.id)) == .group(exited))
        let ungroupedBefore = Self.build(state, collapseEnded: true)
        #expect(ungroupedBefore.parent(of: .remoteSession(endedSession.id)) == .group(ended))

        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        let grouped = Self.build(state, groups: true)
        #expect(!grouped.contains(.group(exited)), "An Exited group left empty must not render")
        #expect(!grouped.contains(.worktree(exitedRow.id)))
        #expect(!grouped.contains(.remoteSession(endedSession.id)))
        #expect(grouped.parent(of: .worktree(cloud.id)) == .group(remote))

        let ungrouped = Self.build(state, collapseEnded: true)
        #expect(!ungrouped.contains(.group(ended)), "An Ended group left empty must not render")
        #expect(!ungrouped.contains(.remoteSession(endedSession.id)))
        #expect(!ungrouped.contains(.worktree(exitedRow.id)))
        #expect(ungrouped.parent(of: .worktree(cloud.id)) == .repoHeader(repo))
    }

    // MARK: Selection

    @Test func aSelectedHiddenRowShowsWithItsAncestorsUntilSelectionMoves() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.selectedRow")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let lane = Self.row("lane", repo: repo)
        let outer = Self.row("outer", repo: repo, remote: "outer", parent: lane.id)
        let inner = Self.row("inner", repo: repo, remote: "inner", parent: outer.id)
        state.worktrees = [repo: [lane, outer, inner]]
        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        #expect(!Self.build(state).contains(.worktree(outer.id)))

        state.selectedWorktreeIDs = [inner.id]
        var tree = Self.build(state)
        #expect(tree.parent(of: .worktree(inner.id)) == .worktree(outer.id))
        #expect(tree.parent(of: .worktree(outer.id)) == .worktree(lane.id))
        #expect(Self.header(tree, repo)?.registryFilter == SidebarRegistryFilterButton(
            isOn: true, count: 0, providerNames: ["acme"]),
            "Selecting a hidden row keeps the button; only the count drops")

        state.selectedWorktreeIDs = [lane.id]
        tree = Self.build(state)
        #expect(!tree.contains(.worktree(outer.id)))
        #expect(!tree.contains(.worktree(inner.id)))

        // Grouped: the reveal opens the parent groups on the selected row's
        // path, and the row shows inside them while it is selected.
        state.selectedWorktreeIDs = [inner.id]
        let reveal = state.sidebarSelectionReveal
        let laneRemote = SidebarGroupID(owner: .parent(lane.id), kind: .remote)
        let outerRemote = SidebarGroupID(owner: .parent(outer.id), kind: .remote)
        #expect(reveal.groups.contains(outerRemote))
        state.revealSidebarGroups(reveal, grouped: true)
        tree = Self.build(state, groups: true)
        #expect(tree.parent(of: .worktree(inner.id)) == .group(outerRemote))
        #expect(tree.parent(of: .worktree(outer.id)) == .group(laneRemote))

        state.selectedWorktreeIDs = [lane.id]
        tree = Self.build(state, groups: true)
        #expect(!tree.contains(.worktree(outer.id)))
        #expect(!tree.contains(.worktree(inner.id)))
        #expect(!tree.contains(.group(laneRemote)))
    }

    @Test func aSelectedHiddenSessionShows() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.selectedSession")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let lane = Self.row("lane", repo: repo)
        let loose = Self.session("loose", repoID: repo)
        state.worktrees = [repo: [lane]]
        state.remoteSessions = [loose]
        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        #expect(!Self.build(state).contains(.remoteSession(loose.id)))

        state.selectedRemoteSession = RemoteSessionSelection(provider: "acme", sessionID: "loose")
        #expect(Self.build(state).parent(of: .remoteSession(loose.id)) == .repoHeader(repo))

        state.selectedRemoteSession = nil
        #expect(!Self.build(state).contains(.remoteSession(loose.id)))
    }

    // MARK: Header

    @Test func headerCarriesTheButtonState() throws {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.header")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Self.addRepo(to: state)
        let main = Self.row("main", repo: repo, status: .main)
        let lane = Self.row("lane", repo: repo, order: 0)
        state.worktrees = [repo: [main, lane]]
        #expect(Self.header(Self.build(state), repo)?.registryFilter == nil, "Only local rows: no button")

        let cloud = Self.cloudRow("cloud", repo: repo, order: 1)
        state.worktrees = [repo: [main, lane, cloud]]
        state.remoteSessions = [Self.cloudSession("loose-cloud", repoID: repo)]
        #expect(Self.header(Self.build(state), repo)?.registryFilter == nil, "Only cloud work: no button")

        let registry = Self.row("registry", repo: repo, remote: "registry", order: 2)
        state.worktrees = [repo: [main, lane, cloud, registry]]
        let off = try #require(Self.header(Self.build(state), repo)?.registryFilter)
        #expect(off == SidebarRegistryFilterButton(isOn: false, count: 0, providerNames: ["acme"]))

        state.toggleSidebarRegistryRemoteFilter(repoID: repo)
        let on = try #require(Self.header(Self.build(state), repo)?.registryFilter)
        #expect(on == SidebarRegistryFilterButton(isOn: true, count: 1, providerNames: ["acme"]))

        // Nothing left to hide: the button goes, the setting stays on.
        state.worktrees = [repo: [main, lane, cloud]]
        #expect(Self.header(Self.build(state), repo)?.registryFilter == nil)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [repo])

        // A registry row that arrives later is hidden at once, and the button
        // returns tinted and counted.
        let arrival = Self.row("arrival", repo: repo, remote: "arrival", order: 3)
        state.worktrees = [repo: [main, lane, cloud, arrival]]
        let back = Self.build(state)
        #expect(!back.contains(.worktree(arrival.id)))
        #expect(Self.header(back, repo)?.registryFilter
                == SidebarRegistryFilterButton(isOn: true, count: 1, providerNames: ["acme"]))

        // A folded repo's header still carries the button.
        state.repos[0].expanded = false
        #expect(Self.header(Self.build(state), repo)?.registryFilter
                == SidebarRegistryFilterButton(isOn: true, count: 1, providerNames: ["acme"]))
    }

    // MARK: Unchanged surfaces

    @Test func otherReposAndProviderSectionsAreUnchanged() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterLayoutTests.unchanged")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let filtered = Self.addRepo(to: state, "acme")
        let other = Self.addRepo(to: state, "acme-two")
        let hidden = Self.row("hidden", repo: filtered, remote: "hidden")
        let kept = Self.row("kept", repo: other, remote: "kept")
        let unmatched = Self.session("unmatched", repoID: nil)
        state.worktrees = [filtered: [hidden], other: [kept]]
        state.remoteSessions = [unmatched]

        state.toggleSidebarRegistryRemoteFilter(repoID: filtered)
        let tree = Self.build(state)
        #expect(!tree.contains(.worktree(hidden.id)))
        #expect(tree.parent(of: .worktree(kept.id)) == .repoHeader(other))
        #expect(tree.parent(of: .remoteSession(unmatched.id)) == .providerHeader("acme"))
        #expect(Self.header(tree, other)?.registryFilter
                == SidebarRegistryFilterButton(isOn: false, count: 0, providerNames: ["acme"]))
    }

    // MARK: Fixtures

    /// Adds a repo and registers the "acme" registry provider and the cloud
    /// provider, both healthy.
    static func addRepo(to state: AppState, _ name: String = "acme") -> UUID {
        let repo = Repo(path: "/tmp/\(name)", displayName: name)
        state.repos.append(repo)
        state.remoteProviders = [SidebarGroupFixtures.provider(), SidebarInteractionTests.cloudProvider()]
        return repo.id
    }

    /// A local row, or an "acme" registry row when `remote` names its session.
    static func row(_ name: String, repo: UUID, remote: String? = nil, parent: UUID? = nil,
                    order: Int = 0, status: WorktreeStatus = .active) -> Worktree {
        SidebarGroupFixtures.row(name, repoID: repo, remote: remote, parent: parent, order: order, status: status)
    }

    /// A cloud row bound to the cloud session named `name`.
    static func cloudRow(_ name: String, repo: UUID, parent: UUID? = nil, order: Int = 0) -> Worktree {
        let location = WorktreeLocation.remote(provider: ClaudeCloudProvider.name, sessionID: name)
        return Worktree(repoID: repo, name: name, displayName: name, branch: "feature",
                        path: location.storagePath ?? "/tmp/acme", status: .active, tmuxServer: "acme",
                        sortOrder: order, parentWorktreeID: parent, location: location)
    }

    /// An "acme" registry session.
    static func session(_ id: String, state: RemoteProcessState = .running, repoID: UUID?) -> RemoteSessionInfo {
        SidebarGroupFixtures.session(id, state: state, repoID: repoID)
    }

    static func cloudSession(_ id: String, state: RemoteProcessState = .running, repoID: UUID?) -> RemoteSessionInfo {
        RemoteSessionInfo(provider: ClaudeCloudProvider.name,
                          payload: RemoteSessionPayload(id: id, state: state, agentState: .idle),
                          gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repoID)
    }

    static func build(_ state: AppState, groups: Bool = false, collapseEnded: Bool = false) -> SidebarTree {
        SidebarTreeBuilderTests.build(
            state, SidebarTreeBuilderTests.options(groups: groups, collapseEnded: collapseEnded))
    }

    static func childIDs(_ tree: SidebarTree, of id: SidebarNodeID) -> [SidebarNodeID] {
        tree.children(of: id).map(\.id)
    }

    static func header(_ tree: SidebarTree, _ repoID: UUID) -> SectionHeaderModel? {
        guard case .repoHeader(let model)? = tree.node(.repoHeader(repoID))?.kind else { return nil }
        return model
    }

    static func remoteGroup(_ repoID: UUID) -> SidebarGroupID {
        SidebarGroupID(owner: .repository(repoID), kind: .remote)
    }
}
