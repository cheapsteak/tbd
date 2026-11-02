import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

@MainActor
private struct ScratchChildFixture {
    let suite = TestDefaultsSuite("SidebarScratchChildRenderingTests")
    let state: AppState
    let parent: Worktree
    let scratch: Worktree

    init(remoteParent: Bool) {
        let defaults = suite.defaults
        defaults.set(true, forKey: AppState.scratchSectionExpandedKey)
        defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
        state = AppState(userDefaults: defaults)
        let repo = UUID()
        parent = SidebarGroupFixtures.row("parent", repoID: repo, remote: remoteParent ? "parent" : nil)
        var scratch = SidebarGroupFixtures.row("scratch", repoID: repo)
        scratch.repoID = nil
        self.scratch = scratch
        state.worktrees = [repo: [parent]]
        state.scratchWorktrees = [scratch]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        state.remoteSessions = [SidebarGroupFixtures.session("parent", state: .exited)]
    }

    func cleanUp() {
        suite.tearDown()
    }
}

@MainActor
@Suite("Reparented Scratch rows retain one flat render location")
struct SidebarScratchChildRenderingTests {
    @Test(arguments: [false, true])
    func scratchStaysFlatWithoutLosingDescendantLiveness(remoteParent: Bool) {
        let fixture = ScratchChildFixture(remoteParent: remoteParent)
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.scratchWorktrees[0].parentWorktreeID = fixture.parent.id
        let groups = state.sidebarRemoteGroups(parentID: fixture.parent.id)
        #expect(groups.localRoots.isEmpty)
        #expect(groups.remoteRoots.isEmpty)
        #expect(groups.exitedRoots.isEmpty)
        #expect(state.sidebarScratchHibernation.workingRoots.map(\.id) == [fixture.scratch.id])
        #expect(state.sidebarRemoteSnapshot.children[fixture.parent.id]?.map(\.id) == [fixture.scratch.id])
        if remoteParent {
            let outer = state.sidebarRemoteGroups(repoID: fixture.parent.repoID!)
            #expect(outer.remoteRoots.map(\.id) == [fixture.parent.id])
            #expect(outer.exitedRoots.isEmpty, "The snapshot must still conservatively retain local work")
        }
    }

    /// The outline after a CLI reparent: the Scratch row stays where it was,
    /// once, and the parent gains no row. The rebuild count proves the write
    /// reached the outline's observation, and a repo-backed child added the
    /// same way does appear under the parent, so the outline would show a
    /// second row if the build made one.
    @Test func reparentingScratchDoesNotAddASecondRenderedRow() throws {
        let h = OutlineHarness("scratchReparent")
        defer { h.tearDown() }
        h.defaults.set(true, forKey: AppState.scratchSectionExpandedKey)
        h.defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = SidebarGroupFixtures.row("parent", repoID: repo.id)
        var scratch = SidebarGroupFixtures.row("scratch", repoID: repo.id)
        scratch.repoID = nil
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [parent]]
        h.state.scratchWorktrees = [scratch]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [SidebarGroupFixtures.session("parent", state: .exited)]
        h.mount()
        let flatRows = h.shownIDs
        let flatScratchRows = flatRows.filter { $0 == .worktree(scratch.id) }.count
        try #require(flatScratchRows == 1, "The Scratch row must show before the reparent: \(h.evidence().rawValue)")
        let flatBuilds = h.controller.buildCount

        h.state.scratchWorktrees[0].parentWorktreeID = parent.id
        h.controller.flushPendingRebuild()
        let rebuilt = h.controller.buildCount > flatBuilds
        try #require(rebuilt, "The reparent must reach the outline's observation")
        let reparentedRows = h.shownIDs
        let reparentedScratchRows = reparentedRows.filter { $0 == .worktree(scratch.id) }.count
        #expect(reparentedScratchRows == 1, h.evidence())
        #expect(reparentedRows.count == flatRows.count,
                "Reparenting Scratch must not show its row again beneath the parent: \(h.evidence().rawValue)")
        #expect(Self.shownParent(of: .worktree(scratch.id), in: h) == .scratchHeader, h.evidence())

        // Positive control: a repo-backed child reaches the same parent and
        // adds a row, proving the count can detect duplication.
        let child = SidebarGroupFixtures.row("local child", repoID: repo.id, parent: parent.id)
        h.state.worktrees[repo.id]?.append(child)
        h.controller.flushPendingRebuild()
        let expectedCount = reparentedRows.count + 1
        #expect(h.shownIDs.count == expectedCount, "A real local child must add exactly one row: \(h.evidence().rawValue)")
        #expect(Self.shownParent(of: .worktree(child.id), in: h) == .worktree(parent.id), h.evidence())
        #expect(h.state.sidebarScratchHibernation.workingRoots.map(\.id) == [scratch.id])
    }

    /// The outline row `id` hangs under, by what the outline shows.
    private static func shownParent(of id: SidebarNodeID, in h: OutlineHarness) -> SidebarNodeID? {
        guard let item = h.controller.item(for: id) else { return nil }
        return (h.outline.parent(forItem: item) as? SidebarItem)?.id
    }
}
