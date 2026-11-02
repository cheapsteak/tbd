import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

@MainActor
private final class ParentProjectionRenderRecord {
    var count = 0
    var groups: SidebarRemoteGroups?

    func record(_ groups: SidebarRemoteGroups) {
        count += 1
        self.groups = groups
    }
}

private struct ParentProjectionProbe: View {
    let parentID: UUID
    let record: ParentProjectionRenderRecord
    @Environment(AppState.self) private var appState

    var body: some View {
        let groups = appState.sidebarRemoteGroups(parentID: parentID)
        let _ = record.record(groups)
        VStack {
            Text(appState.alertMessage ?? "acme")
            Text(groups.summary.text)
            Text("\(groups.remoteRoots.count) active roots; \(groups.exitedRoots.count) exited roots")
        }
    }
}

@MainActor
@Suite("Parent projection warm-cache rendering")
struct SidebarParentRemoteCacheObservationTests {
    @Test(arguments: ParentGroupCacheInput.allCases)
    func inputMutationReachesTheCacheServedBody(_ input: ParentGroupCacheInput) async throws {
        let fixture = ParentGroupCacheFixture()
        defer { fixture.cleanUp() }
        let record = ParentProjectionRenderRecord()
        let host = OffscreenHost(
            root: ParentProjectionProbe(parentID: fixture.parent.id, record: record).environment(fixture.state),
            size: NSSize(width: 320, height: 180))
        defer { host.tearDown() }
        let mounted = await host.settle { record.count > 0 }
        try #require(mounted, "The probe must evaluate before measuring a warm render")
        await host.pump(times: 5)
        try #require(fixture.state.sidebarParentRemoteGroupsCache[fixture.parent.id] != nil)
        #expect(record.groups?.exitedRoots.map(\.id) == [fixture.worker.id])

        let coldCount = record.count
        fixture.state.alertMessage = "Force a warm-cache render"
        let warmed = await host.settle { record.count > coldCount }
        try #require(warmed, "An unrelated tracked write must force the cache-served evaluation")
        await host.pump(times: 5)
        let warmCount = record.count
        fixture.mutate(input)
        let changed = await host.settle {
            record.count > warmCount && record.groups.map { fixture.reflectsMutation($0, input: input) } == true
        }
        #expect(changed, "A \(input) mutation did not reach the warm-cache SwiftUI body")
    }

    /// The outline drawn against an already-warm projection drops the Exited
    /// disclosure once the provider goes stale, and the worker stays under
    /// Remote. Collapsing Remote then removes exactly that one row, which
    /// checks the outline independently of the model assertion.
    @Test func outlineRemovesExitedDisclosureWhenProviderBecomesStale() throws {
        let fixture = ParentOutlineFixture("parentStale", workflowGroups: true)
        defer { fixture.h.tearDown() }
        let h = fixture.h
        let remote = SidebarGroupID(owner: .parent(fixture.parent.id), kind: .remote)
        let exited = SidebarGroupID(owner: .parent(fixture.parent.id), kind: .exited)
        h.state.expandedSidebarGroups = [remote, exited]
        _ = h.state.sidebarRemoteGroups(parentID: fixture.parent.id)
        h.mount()
        try #require(fixture.shownParent(of: .worktree(fixture.worker.id)) == .group(exited), h.evidence())
        try #require(fixture.shownParent(of: .group(exited)) == .group(remote), h.evidence())
        try #require(fixture.shownParent(of: .group(remote)) == .worktree(fixture.parent.id), h.evidence())

        h.state.remoteProviders = [SidebarGroupFixtures.provider(health: .stale)]
        h.controller.flushPendingRebuild()
        let staleRows = h.shownIDs
        #expect(!staleRows.contains(.group(exited)), "The stale provider must remove the Exited header")
        #expect(fixture.shownParent(of: .worktree(fixture.worker.id)) == .group(remote), h.evidence())
        let remoteRoots = h.state.sidebarRemoteGroups(parentID: fixture.parent.id).remoteRoots.map(\.id)
        #expect(remoteRoots == [fixture.worker.id])

        h.state.toggleSidebarGroup(remote)
        h.controller.flushPendingRebuild()
        let collapsedRows = h.shownIDs
        let expectedCount = staleRows.count - 1
        #expect(collapsedRows.count == expectedCount,
                "Remote must have held exactly the worker row after its Exited subgroup went: \(h.evidence().rawValue)")
        #expect(!collapsedRows.contains(.worktree(fixture.worker.id)), h.evidence())
        #expect(collapsedRows.contains(.group(remote)), h.evidence())
    }

    /// With the sidebar-groups toggle off, a parent's remote worker shows
    /// inline as a plain child row: no Remote or Exited header under the
    /// parent, and the grouped projection is never read.
    @Test func groupsOffShowsRemoteChildrenInlineWithoutParentHeaders() throws {
        let fixture = ParentOutlineFixture("parentInline", workflowGroups: false)
        defer { fixture.h.tearDown() }
        let h = fixture.h
        h.mount()
        #expect(h.state.expandedSidebarGroups.isEmpty)
        #expect(fixture.parentGroupRows.isEmpty, h.evidence())
        #expect(fixture.shownParent(of: .worktree(fixture.worker.id)) == .worktree(fixture.parent.id), h.evidence())
        #expect(h.state.sidebarParentRemoteGroupsCache[fixture.parent.id] == nil,
                "The ungrouped outline must not read the parent group projection")

        // The worker is a plain row: moving it to another parent moves that
        // one row there, where a collapsed Remote group would have hidden it
        // behind a header.
        h.state.worktrees[fixture.parent.repoID!]?[2].parentWorktreeID = fixture.other.id
        h.controller.flushPendingRebuild()
        #expect(fixture.shownParent(of: .worktree(fixture.worker.id)) == .worktree(fixture.other.id), h.evidence())
        #expect(fixture.parentGroupRows.isEmpty, h.evidence())
        #expect(h.state.sidebarParentRemoteGroupsCache[fixture.parent.id] == nil)

        // Positive control: turning the toggle on reaches the grouped build
        // through the same outline, so the off-branch assertions above are live.
        h.defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
        h.controller.flushPendingRebuild()
        #expect(h.state.sidebarParentRemoteGroupsCache[fixture.parent.id] != nil,
                "Turning sidebar groups on must build the parent projection")
    }
}

/// `ParentGroupCacheFixture`'s rows in an outline harness's state, under a
/// repo the outline draws a section for.
@MainActor
private struct ParentOutlineFixture {
    let h: OutlineHarness
    let parent: Worktree
    let other: Worktree
    let worker: Worktree

    init(_ label: String, workflowGroups: Bool) {
        h = OutlineHarness("parentRemote.\(label)")
        h.defaults.set(workflowGroups, forKey: AppState.sidebarWorkflowGroupsKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        parent = SidebarGroupFixtures.row("director", repoID: repo.id)
        other = SidebarGroupFixtures.row("other", repoID: repo.id)
        worker = SidebarGroupFixtures.row("worker", repoID: repo.id, remote: "worker", parent: parent.id)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [parent, other, worker]]
        h.state.remoteSessions = [SidebarGroupFixtures.session("worker", state: .exited)]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
    }

    /// The outline row `id` hangs under, by what the outline shows.
    func shownParent(of id: SidebarNodeID) -> SidebarNodeID? {
        guard let item = h.controller.item(for: id) else { return nil }
        return (h.outline.parent(forItem: item) as? SidebarItem)?.id
    }

    /// The shown group headers a worktree row owns.
    var parentGroupRows: [SidebarNodeID] {
        h.shownIDs.filter { id in
            guard case .group(let group) = id, case .parent = group.owner else { return false }
            return true
        }
    }
}
