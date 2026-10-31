import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// The controller is mounted in a real, offscreen window and driven through
// `flushPendingRebuild()`, never by waiting for the main loop. The scratch
// directory probe is a fixed answer, so no test touches the disk through it.

/// A `SidebarOutlineController` over an `AppState` fixture: configure `state`
/// and `defaults`, then `mount()` to run the first load offscreen.
@MainActor
final class OutlineHarness {
    let suite: TestDefaultsSuite
    let state: AppState
    let controller: SidebarOutlineController
    private(set) var host: OffscreenAppKitHost?

    var defaults: UserDefaults { suite.defaults }
    var outline: SidebarOutlineView { controller.outline }
    var clip: NSClipView { controller.scrollView.contentView }

    init(_ label: String) {
        suite = TestDefaultsSuite("SidebarOutlineControllerTests.\(label)")
        state = AppState(userDefaults: suite.defaults)
        controller = SidebarOutlineController(
            appState: state, defaults: suite.defaults, scratchDirectoryProbe: { _ in true })
    }

    /// Mounts the controller offscreen and runs its first load.
    func mount(size: NSSize = NSSize(width: 320, height: 600)) {
        host = OffscreenAppKitHost(controller: controller, size: size)
        controller.flushPendingRebuild()
        host?.layout()
    }

    func tearDown() {
        host?.tearDown()
        suite.tearDown()
    }

    /// The IDs of the rows the outline shows, top to bottom.
    var shownIDs: [SidebarNodeID] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
    }

    /// The outline row showing `id`, or -1.
    func row(_ id: SidebarNodeID) -> Int {
        guard let item = controller.item(for: id) else { return -1 }
        return outline.row(forItem: item)
    }

    /// What a fresh build of the current state looks like.
    func freshTree() -> SidebarTree {
        SidebarTreeBuilder.build(state, options: SidebarBuildOptions(defaults: defaults), directoryExists: { _ in true })
    }

    /// The text the row's cell shows in its name label.
    func cellText(_ id: SidebarNodeID) -> String? {
        let index = row(id)
        guard index >= 0 else { return nil }
        return (outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView)?
            .textField?.stringValue
    }

    /// The row view showing `id` after laying the window out; `make` creates
    /// one when the outline has none yet.
    func rowView(_ id: SidebarNodeID, make: Bool) -> NSTableRowView? {
        let index = row(id)
        guard index >= 0 else { return nil }
        host?.layout()
        return outline.rowView(atRow: index, makeIfNecessary: make)
    }
}

/// The native sidebar's update loop: first load, coalescing, applying diffs
/// with moves and height changes, the scroll anchor, the row-count fallback,
/// and holding structure during a drag or a rename.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Update loop".
@MainActor
@Suite("Sidebar outline controller")
struct SidebarOutlineControllerTests {
    // MARK: Update loop

    @Test func firstLoadShowsTreeRows() throws {
        let h = OutlineHarness("firstLoad")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = Self.row("main", repo, status: .main)
        let parent = Self.row("parent", repo, order: 0)
        let child = Self.row("child", repo, parent: parent.id)
        let sibling = Self.row("sibling", repo, order: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [main, parent, child, sibling]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [SidebarGroupFixtures.session("lane")]
        h.mount()

        #expect(h.controller.buildCount == 1)
        let expected = h.freshTree()
        #expect(h.outline.numberOfRows == expected.visibleRowCount)
        #expect(h.shownIDs == expected.visibleIDs)
        #expect(h.shownIDs.contains(.worktree(child.id)))
        #expect(h.shownIDs.contains(.providerHeader("acme")))

        // A header at level 0, its rows at 1, a nested row one deeper.
        let headerRow = h.row(.repoHeader(repo.id))
        let parentRow = h.row(.worktree(parent.id))
        let childRow = h.row(.worktree(child.id))
        #expect(h.outline.level(forRow: headerRow) == 0)
        #expect(h.outline.level(forRow: parentRow) == 1)
        #expect(h.outline.level(forRow: childRow) == 2)
        // A header and its top-level rows share a leading edge; each nesting
        // level adds one indentation step. No disclosure triangle.
        let headerX = h.outline.frameOfCell(atColumn: 0, row: headerRow).minX
        let parentX = h.outline.frameOfCell(atColumn: 0, row: parentRow).minX
        let childX = h.outline.frameOfCell(atColumn: 0, row: childRow).minX
        #expect(headerX == parentX)
        #expect(childX - parentX == SidebarNativeMetrics.indentation)
        #expect(h.outline.frameOfOutlineCell(atRow: childRow) == .zero)

        for row in 0..<h.outline.numberOfRows {
            #expect(h.outline.view(atColumn: 0, row: row, makeIfNecessary: true) != nil, "Row \(row) has no cell")
        }
    }

    @Test func burstOfWritesRebuildsOnce() throws {
        let h = OutlineHarness("burst")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let row = Self.row("work", repo)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [row]]
        h.mount()
        let afterLoad = h.controller.buildCount

        for index in 0..<50 {
            h.state.devServerRunningWorktreeIDs = index.isMultiple(of: 2) ? [row.id] : []
        }
        h.controller.flushPendingRebuild()
        #expect(h.controller.buildCount == afterLoad + 1, "Fifty writes must cost one rebuild")
        // The last write (index 49) cleared the dot.
        #expect(Self.worktreeModel(h.controller.tree, row.id)?.showsDevServerDot == false)

        h.controller.flushPendingRebuild()
        #expect(h.controller.buildCount == afterLoad + 1, "With nothing changed, a flush must not rebuild")

        // Positive control: the tracking re-armed, so the next write rebuilds.
        h.state.devServerRunningWorktreeIDs = [row.id]
        h.controller.flushPendingRebuild()
        #expect(h.controller.buildCount == afterLoad + 2)
        #expect(Self.worktreeModel(h.controller.tree, row.id)?.showsDevServerDot == true)
    }

    @Test func crossParentMoveKeepsRowViewIdentity() throws {
        let h = OutlineHarness("move")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = Self.row("first", repo, order: 0)
        let second = Self.row("second", repo, order: 1)
        let moving = Self.row("moving", repo, parent: first.id, order: 0)
        let staying = Self.row("staying", repo, parent: first.id, order: 1)
        // The destination already shows children, so it is expanded and the
        // move is a move rather than a re-creation under a former leaf.
        let resident = Self.row("resident", repo, parent: second.id, order: 0)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [first, second, moving, staying, resident]]
        h.mount()

        let item = try #require(h.controller.item(for: .worktree(moving.id)))
        let before = try #require(h.rowView(.worktree(moving.id), make: true))
        let index = try #require(h.state.worktrees[repo.id]?.firstIndex { $0.id == moving.id })
        h.state.worktrees[repo.id]?[index].parentWorktreeID = second.id
        h.controller.flushPendingRebuild()

        #expect(h.controller.fallbackReloadCount == 0)
        #expect(h.shownIDs == h.freshTree().visibleIDs)
        #expect(h.controller.tree.parent(of: .worktree(moving.id)) == .worktree(second.id))
        #expect(h.controller.item(for: .worktree(moving.id)) === item, "A moved row keeps its item")
        #expect((h.outline.parent(forItem: item) as? SidebarItem)?.id == .worktree(second.id))
        let after = h.rowView(.worktree(moving.id), make: false)
        #expect(after === before, "A cross-parent move must keep the row's view")
    }

    @Test func scrollAnchorRestoredAfterInsertAbove() throws {
        let h = OutlineHarness("anchor")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let rows = (0..<40).map { Self.row("row \($0)", repo, order: $0 + 1) }
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: rows]
        h.mount(size: NSSize(width: 320, height: 200))

        let anchor = SidebarNodeID.worktree(rows[20].id)
        let anchorRow = h.row(anchor)
        try #require(anchorRow > 0)
        // The anchor row's top sits 5 pt above the clip view's top.
        h.outline.scroll(NSPoint(x: 0, y: h.outline.rect(ofRow: anchorRow).minY + 5))
        try #require(h.clip.bounds.minY > 0, "The outline never scrolled; the check below would be vacuous")
        let offsetBefore = h.outline.rect(ofRow: anchorRow).minY - h.clip.bounds.minY

        h.state.worktrees[repo.id]?.append(Self.row("inserted", repo, order: 0))
        h.controller.flushPendingRebuild()

        let rowAfter = h.row(anchor)
        #expect(rowAfter == anchorRow + 1, "The inserted row sits above the anchor")
        let offsetAfter = h.outline.rect(ofRow: rowAfter).minY - h.clip.bounds.minY
        #expect(abs(offsetAfter - offsetBefore) < 0.5, "The anchor row moved on screen: \(offsetBefore) → \(offsetAfter)")
    }

    @Test func heightClassChangeDoesNotAnimate() throws {
        let h = OutlineHarness("height")
        defer { h.tearDown() }
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [SidebarGroupFixtures.session("one"), SidebarGroupFixtures.session("two")]
        h.mount()

        let header = SidebarNodeID.providerHeader("acme")
        let headerRow = h.row(header)
        try #require(headerRow >= 0 && headerRow + 1 < h.outline.numberOfRows)
        let heightBefore = h.outline.rect(ofRow: headerRow).height
        let below = try #require(h.outline.rowView(atRow: headerRow + 1, makeIfNecessary: true))

        // An unhealthy provider shows an issue line under its name.
        h.state.remoteProviders = [SidebarGroupFixtures.provider(health: .error)]
        h.controller.flushPendingRebuild()

        let kind = try #require(h.controller.tree.node(header)?.kind)
        #expect(kind.heightClass == .withSubtitle)
        #expect(h.controller.fallbackReloadCount == 0)
        let heightAfter = h.outline.rect(ofRow: headerRow).height
        #expect(heightAfter == h.controller.rowHeight(for: kind))
        #expect(heightAfter != heightBefore, "The height class change never reached the outline")
        #expect(h.controller.lastHeightNoteDuration == 0)
        // Nothing is left animating: the row below is already where it ends up.
        h.host?.layout()
        #expect(abs(below.frame.minY - h.outline.rect(ofRow: headerRow + 1).minY) < 0.5)
    }

    @Test func rowCountMismatchFallsBackToReload() throws {
        let h = OutlineHarness("fallback")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [Self.row("one", repo, order: 0), Self.row("two", repo, order: 1)]]
        h.mount()

        // A diff that forgets the insert leaves the outline a row short.
        h.controller.diffForTesting = { _, _ in OutlineUpdate(steps: [], reconfigure: [], heightChanged: []) }
        let late = Self.row("late", repo, order: 2)
        h.state.worktrees[repo.id]?.append(late)
        h.controller.flushPendingRebuild()

        #expect(h.controller.fallbackReloadCount == 1)
        #expect(h.outline.numberOfRows == h.controller.tree.visibleRowCount)
        #expect(h.shownIDs == h.freshTree().visibleIDs)
        #expect(h.shownIDs.contains(.worktree(late.id)))

        // Positive control: the real diff needs no fallback.
        h.controller.diffForTesting = nil
        let later = Self.row("later", repo, order: 3)
        h.state.worktrees[repo.id]?.append(later)
        h.controller.flushPendingRebuild()
        #expect(h.controller.fallbackReloadCount == 1)
        #expect(h.shownIDs == h.freshTree().visibleIDs)
    }

    // MARK: Holding structure

    /// Review Focus 4: the hidden-repos filter, a row's removal and the groups
    /// toggle all change mid-hold; nothing moves until the hold ends, and then
    /// the outline matches a fresh build with no item left over.
    @Test func structuralChangesHeldDuringRenameAndDrag() throws {
        for reason in [SidebarOutlineController.HoldReason.rename, .drag] {
            try checkHeldStructure(reason)
        }

        // Holds nest: the structure lands only when the last one ends.
        let h = OutlineHarness("hold.nested")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [Self.row("one", repo)]]
        h.mount()
        h.controller.beginHold(.drag)
        h.controller.beginHold(.rename)
        let added = Self.row("added", repo, order: 1)
        h.state.worktrees[repo.id]?.append(added)
        h.controller.flushPendingRebuild()
        h.controller.endHold(.drag)
        #expect(h.controller.isHoldingStructure)
        #expect(!h.shownIDs.contains(.worktree(added.id)))
        h.controller.endHold(.rename)
        #expect(!h.controller.isHoldingStructure)
        #expect(h.shownIDs.contains(.worktree(added.id)))
    }

    private func checkHeldStructure(_ reason: SidebarOutlineController.HoldReason) throws {
        let h = OutlineHarness("hold.\(reason)")
        defer { h.tearDown() }
        let shown = Repo(path: "/tmp/acme-shown", displayName: "shown")
        let hidden = Repo(path: "/tmp/acme-hidden", displayName: "hidden", hidden: true)
        let keep = Self.row("keep", shown, order: 0)
        let doomed = Self.row("doomed", shown, order: 1)
        let secret = Self.row("secret", hidden)
        h.state.repos = [shown, hidden]
        h.state.worktrees = [shown.id: [keep, doomed], hidden.id: [secret]]
        h.mount()
        let before = h.shownIDs
        try #require(!before.contains(.repoHeader(hidden.id)))

        h.controller.beginHold(reason)
        #expect(h.controller.isHoldingStructure)
        h.defaults.set(true, forKey: SidebarBuildOptions.showHiddenReposKey)
        h.state.worktrees[shown.id]?.removeAll { $0.id == doomed.id }
        h.defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
        h.controller.flushPendingRebuild()

        #expect(h.shownIDs == before, "Structure moved while \(reason) held it")
        #expect(h.controller.item(for: .worktree(doomed.id)) != nil, "A held row keeps its item until the hold ends")

        h.controller.endHold(reason)
        #expect(!h.controller.isHoldingStructure)
        let expected = h.freshTree().visibleIDs
        #expect(expected.contains(.repoHeader(hidden.id)), "The fixture must reveal the hidden repo")
        #expect(h.shownIDs == expected)
        #expect(h.controller.item(for: .worktree(doomed.id)) == nil, "A stale item survived the hold")
        for row in 0..<h.outline.numberOfRows {
            let item = try #require(h.outline.item(atRow: row) as? SidebarItem)
            #expect(h.controller.item(for: item.id) === item)
            #expect(h.controller.tree.contains(item.id))
        }
        #expect(h.controller.fallbackReloadCount == 0)
    }

    @Test func contentChangesApplyDuringHold() throws {
        let h = OutlineHarness("holdContent")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let keep = Self.row("keep", repo, order: 0)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [keep]]
        h.mount()
        let before = h.shownIDs
        _ = try #require(h.rowView(.worktree(keep.id), make: true))
        try #require(h.cellText(.worktree(keep.id)) == "keep")

        h.controller.beginHold(.drag)
        h.state.worktrees[repo.id]?[0].displayName = "renamed"
        let added = Self.row("added", repo, order: 1)
        h.state.worktrees[repo.id]?.append(added)
        h.controller.flushPendingRebuild()

        #expect(h.shownIDs == before, "The insert must wait for the drag")
        #expect(Self.worktreeModel(h.controller.tree, keep.id)?.name == "renamed")
        #expect(h.cellText(.worktree(keep.id)) == "renamed", "A content change must land mid-drag")

        h.controller.endHold(.drag)
        #expect(h.shownIDs.contains(.worktree(added.id)))
        #expect(h.cellText(.worktree(keep.id)) == "renamed")
    }

    // MARK: Fixtures

    static func row(_ name: String, _ repo: Repo, parent: UUID? = nil, order: Int = 0,
                    status: WorktreeStatus = .active) -> Worktree {
        SidebarGroupFixtures.row(name, repoID: repo.id, parent: parent, order: order, status: status)
    }

    static func worktreeModel(_ tree: SidebarTree, _ id: UUID) -> WorktreeRowModel? {
        guard case .worktree(let model)? = tree.node(.worktree(id))?.kind else { return nil }
        return model
    }
}
