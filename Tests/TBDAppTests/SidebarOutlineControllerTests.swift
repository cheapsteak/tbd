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

    /// Rows whose shown item is not the item the controller holds for that
    /// ID: an item dropped from the cache while the outline still shows it.
    var shownItemsMissingFromCache: [SidebarNodeID] {
        (0..<outline.numberOfRows).compactMap { row -> SidebarNodeID? in
            guard let item = outline.item(atRow: row) as? SidebarItem else { return nil }
            return controller.item(for: item.id) === item ? nil : item.id
        }
    }

    // MARK: Evidence for a failing expectation

    /// What a failing outline expectation prints, so a CI failure carries it:
    /// the rows shown, the rows selected, the last update's steps, the
    /// fallback count, and any shown row whose item left the cache. `names`
    /// labels worktree rows.
    func evidence(_ names: [UUID: String] = [:]) -> Comment {
        let shown = shownIDs.map { Self.label($0, names) }.joined(separator: ", ")
        let selectedIDs = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
        let selected = selectedIDs.map { Self.label($0, names) }.joined(separator: ", ")
        let steps = controller.lastAppliedUpdate.map { update in
            update.steps.map { Self.describe($0, names) }.joined(separator: "; ")
        } ?? "no update applied"
        let uncached = shownItemsMissingFromCache.map { Self.label($0, names) }.joined(separator: ", ")
        let appSelection = state.selectedWorktreeIDs.map { names[$0] ?? Self.short($0) }.sorted().joined(separator: ", ")
        return Comment(rawValue: "shown [\(shown)] · selected [\(selected)] · AppState selection [\(appSelection)]"
            + " · steps [\(steps)] · fallbacks \(controller.fallbackReloadCount)"
            + " · shown but not cached [\(uncached)]")
    }

    /// `evidence` plus which row view was captured, which one the outline now
    /// shows for `id`, their configurations, and the views configured for
    /// `id` since the last apply began.
    func rowViewEvidence(_ id: SidebarNodeID, captured: SidebarRowView, _ names: [UUID: String] = [:]) -> Comment {
        let shownView = rowView(id, make: false)
        let shownConfiguration = (shownView as? SidebarRowView).map { String(describing: $0.configuration) } ?? "none"
        let configured = controller.configuredRowViews.filter { $0.value == id }.map { String(describing: $0.key) }
        return Comment(rawValue: evidence(names).rawValue
            + " · captured view \(String(describing: ObjectIdentifier(captured))) \(captured.configuration)"
            + " · shown view \(shownView.map { String(describing: ObjectIdentifier($0)) } ?? "none") \(shownConfiguration)"
            + " · configured for this row since the apply [\(configured.joined(separator: ", "))]")
    }

    static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    static func label(_ id: SidebarNodeID, _ names: [UUID: String]) -> String {
        switch id {
        case .worktree(let uuid): names[uuid] ?? "worktree \(short(uuid))"
        case .remoteSession(let uuid): "session \(short(uuid))"
        case .repoHeader(let uuid): "repo \(short(uuid))"
        case .providerHeader(let name): "provider \(name)"
        case .group(let group): "\(group.kind) group"
        case .scratchHeader: "scratch"
        case .scratchPrompt: "scratch prompt"
        }
    }

    static func parentLabel(_ id: SidebarNodeID?, _ names: [UUID: String]) -> String {
        guard let id else { return "root" }
        return label(id, names)
    }

    static func describe(_ step: OutlineStep, _ names: [UUID: String]) -> String {
        switch step {
        case .remove(let from, let index): return "remove \(index) of \(parentLabel(from, names))"
        case .insert(let into, let index, let id):
            return "insert \(label(id, names)) at \(index) of \(parentLabel(into, names))"
        case .move(let from, let fromIndex, let into, let toIndex):
            return "move \(fromIndex) of \(parentLabel(from, names)) to \(toIndex) of \(parentLabel(into, names))"
        case .reloadItem(let id): return "reload \(label(id, names))"
        case .expand(let id): return "expand \(label(id, names))"
        case .collapse(let id): return "collapse \(label(id, names))"
        }
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
        let found = h.state.worktrees[repo.id]?.firstIndex { $0.id == moving.id }
        let index = try #require(found)
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
        let headerView = try #require(h.outline.rowView(atRow: headerRow, makeIfNecessary: true))
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
        // Nothing is animating: no animation on either row view's layer, and
        // the row below is already where it ends up.
        let headerAnimations = headerView.layer?.animationKeys() ?? []
        let belowAnimations = below.layer?.animationKeys() ?? []
        #expect(headerAnimations.isEmpty, "The changed row is animating: \(headerAnimations)")
        #expect(belowAnimations.isEmpty, "The row below is animating: \(belowAnimations)")
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

    // MARK: Diffs replayed on a real outline

    // `SidebarTreeDiffTests` replays the diff on `OutlineSimulator`, a model of
    // `NSOutlineView`. These replay it on the real thing, through the
    // controller: each must end with the outline showing exactly a fresh
    // build, with no fallback reload.

    @Test func leafGainingChildReplaysOnTheOutline() throws {
        let h = OutlineHarness("replay.leaf")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let leaf = Self.row("leaf", repo, order: 0)
        let other = Self.row("other", repo, order: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [leaf, other]]
        h.mount()
        let leafItem = try #require(h.controller.item(for: .worktree(leaf.id)))
        try #require(!h.outline.isExpandable(leafItem))

        let child = Self.row("child", repo, parent: leaf.id)
        h.state.worktrees[repo.id]?.append(child)
        h.controller.flushPendingRebuild()

        #expect(h.controller.fallbackReloadCount == 0)
        #expect(h.shownIDs == h.freshTree().visibleIDs)
        #expect(h.outline.isItemExpanded(leafItem), "The former leaf shows its first child")
        #expect(h.outline.level(forRow: h.row(.worktree(child.id))) == 2)
    }

    /// A Hibernated group whose only row is reparented under a working row:
    /// the row moves out first, keeping its view, and then the emptied group
    /// goes.
    @Test func groupEmptiedByMovingItsRowsOutReplaysOnTheOutline() throws {
        let h = OutlineHarness("replay.emptied")
        defer { h.tearDown() }
        h.defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = Self.row("parent", repo, order: 0)
        let working = Self.row("working", repo, parent: parent.id, order: 0)
        let parked = Self.row("parked", repo, order: 1)
        let shelf = SidebarGroupID(owner: .repository(repo.id), kind: .hibernated)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [parent, working, parked]]
        h.state.terminals[parked.id] = [TBDShared.Terminal(
            worktreeID: parked.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude,
            hibernatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        h.state.expandedSidebarGroups = [shelf]
        h.mount()
        try #require(h.controller.tree.parent(of: .worktree(parked.id)) == .group(shelf),
                     "The parked row must start on the Hibernated shelf")
        let parkedItem = try #require(h.controller.item(for: .worktree(parked.id)))
        let before = try #require(h.rowView(.worktree(parked.id), make: true) as? SidebarRowView)
        // On the shelf: one level of group padding, no worktree ancestor.
        try #require(before.configuration.tintLevel == 1 && before.configuration.guideCount == 0)

        let found = h.state.worktrees[repo.id]?.firstIndex { $0.id == parked.id }
        let index = try #require(found)
        h.state.worktrees[repo.id]?[index].parentWorktreeID = parent.id
        h.controller.flushPendingRebuild()

        let names = [parent.id: "parent", working.id: "working", parked.id: "parked"]
        #expect(h.controller.fallbackReloadCount == 0, h.evidence(names))
        #expect(h.shownIDs == h.freshTree().visibleIDs, h.evidence(names))
        #expect(!h.controller.tree.contains(.group(shelf)), "The emptied shelf is gone")
        #expect(h.controller.item(for: .group(shelf)) == nil)
        #expect(h.controller.tree.parent(of: .worktree(parked.id)) == .worktree(parent.id))
        #expect(h.controller.item(for: .worktree(parked.id)) === parkedItem, h.evidence(names))
        let uncached = h.shownItemsMissingFromCache
        #expect(uncached.isEmpty, h.evidence(names))
        // The row's model is the same at the same depth, but its ancestors
        // changed. Whichever view the outline now shows for it takes its tint
        // and guide line from them.
        let shown = try #require(h.rowView(.worktree(parked.id), make: false) as? SidebarRowView,
                                 h.rowViewEvidence(.worktree(parked.id), captured: before, names))
        #expect(shown === before, "A move keeps the row's view; \(h.rowViewEvidence(.worktree(parked.id), captured: before, names).rawValue)")
        #expect(shown.configuration.tintLevel == 0, h.rowViewEvidence(.worktree(parked.id), captured: before, names))
        #expect(shown.configuration.guideCount == 1, h.rowViewEvidence(.worktree(parked.id), captured: before, names))
    }

    /// The one case a moved row cannot keep its view: nested onto a former
    /// leaf, it is removed and brought back by the leaf's reload, its own
    /// child with it. The rows match a fresh build, the selection and scroll
    /// anchor come back, and every row the outline shows is the item the
    /// cache holds for it.
    @Test func nestOntoLeafWithChildrenReplaysOnTheOutline() throws {
        let h = OutlineHarness("replay.nest")
        defer { h.tearDown() }
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let fillers = (0..<30).map { Self.row("filler \($0)", repo, order: $0) }
        let leaf = Self.row("leaf", repo, order: 30)
        let moving = Self.row("moving", repo, order: 31)
        let movingChild = Self.row("moving child", repo, parent: moving.id)
        let after = (0..<10).map { Self.row("after \($0)", repo, order: 32 + $0) }
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: fillers + [leaf, moving, movingChild] + after]
        h.state.selectedWorktreeIDs = [moving.id]
        h.mount(size: NSSize(width: 320, height: 200))

        let movingRow = h.row(.worktree(moving.id))
        try #require(h.outline.selectedRowIndexes == IndexSet(integer: movingRow))
        // The moving row is the first visible one, 6 pt above the clip's top.
        h.outline.scroll(NSPoint(x: 0, y: h.outline.rect(ofRow: movingRow).minY + 6))
        try #require(h.clip.bounds.minY > 0, "The outline never scrolled; the anchor check would be vacuous")
        let offsetBefore = h.outline.rect(ofRow: movingRow).minY - h.clip.bounds.minY

        let found = h.state.worktrees[repo.id]?.firstIndex { $0.id == moving.id }
        let index = try #require(found)
        h.state.worktrees[repo.id]?[index].parentWorktreeID = leaf.id
        h.controller.flushPendingRebuild()

        let names = [leaf.id: "leaf", moving.id: "moving", movingChild.id: "moving child"]
        #expect(h.controller.fallbackReloadCount == 0, h.evidence(names))
        #expect(h.shownIDs == h.freshTree().visibleIDs, h.evidence(names))
        #expect(h.controller.tree.parent(of: .worktree(moving.id)) == .worktree(leaf.id))
        #expect(h.outline.level(forRow: h.row(.worktree(movingChild.id))) == 3, h.evidence(names))
        // Nothing the outline still shows was dropped from the cache, so every
        // lookup by ID — selection, anchor, reconfigure — finds its row.
        let uncached = h.shownItemsMissingFromCache
        #expect(uncached.isEmpty, h.evidence(names))
        // The selection and the scroll anchor came back.
        let newRow = h.row(.worktree(moving.id))
        try #require(newRow >= 0, h.evidence(names))
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: newRow), h.evidence(names))
        #expect(h.state.selectedWorktreeIDs == [moving.id], h.evidence(names))
        #expect(h.controller.appStateSelectionWriteCount == 0, h.evidence(names))
        let offsetAfter = h.outline.rect(ofRow: newRow).minY - h.clip.bounds.minY
        #expect(abs(offsetAfter - offsetBefore) < 0.5,
                "The anchor row moved on screen: \(offsetBefore) → \(offsetAfter); \(h.evidence(names).rawValue)")
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

    // MARK: Selection, header actions, expansion and reveal

    @Test func pureRemoteSelectionRoutesToSelectRemoteSession() throws {
        let h = OutlineHarness("pureRemote")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let row = Self.row("work", repo)
        let lane = SidebarGroupFixtures.session("lane")
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [row]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [lane]
        h.state.selectedWorktreeIDs = [row.id]
        h.mount()
        try #require(h.outline.selectedRowIndexes == IndexSet(integer: h.row(.worktree(row.id))))

        let laneRow = h.row(.remoteSession(lane.id))
        try #require(laneRow >= 0)
        h.outline.selectRowIndexes(IndexSet(integer: laneRow), byExtendingSelection: false)

        // `selectedWorktreeIDs`' didSet stripped the session's ID and routed
        // the pure-remote selection through `selectRemoteSession`.
        #expect(h.controller.appStateSelectionWriteCount == 1)
        #expect(h.state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "lane"))
        #expect(h.state.selectedWorktreeIDs.isEmpty)
        // The session's row stays selected, now and after the rebuild.
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: laneRow))
        h.controller.flushPendingRebuild()
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: h.row(.remoteSession(lane.id))))
        #expect(h.controller.appStateSelectionWriteCount == 1)
    }

    @Test func modelSelectionNotEchoedDuringApply() throws {
        let h = OutlineHarness("noEcho")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = Self.row("first", repo, order: 0)
        let second = Self.row("second", repo, order: 1)
        let third = Self.row("third", repo, order: 2)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [first, second, third]]
        h.state.selectedWorktreeIDs = [first.id]
        h.mount()
        try #require(h.outline.selectedRowIndexes == IndexSet(integer: h.row(.worktree(first.id))))
        let suppressedBefore = h.controller.suppressedSelectionNotificationCount

        // One batch: the selected row goes, and AppState selects another. The
        // outline drops the removed row from its selection mid-apply and says
        // so; written back, that empty selection would clobber `third`.
        h.state.worktrees[repo.id]?.removeAll { $0.id == first.id }
        h.state.selectedWorktreeIDs = [third.id]
        h.controller.flushPendingRebuild()

        #expect(h.controller.appStateSelectionWriteCount == 0, "The apply wrote the outline's interim selection back")
        #expect(h.controller.suppressedSelectionNotificationCount > suppressedBefore,
                "The outline posted no selection change during the apply, so the guard was never tested")
        #expect(h.state.selectedWorktreeIDs == [third.id])
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: h.row(.worktree(third.id))))
    }

    /// Review Focus 2: a selected row disappears during an apply.
    @Test func selectedRowArchivedDuringApplyDropsFromSelection() throws {
        let h = OutlineHarness("vanished")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = Self.row("first", repo, order: 0)
        let second = Self.row("second", repo, order: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [first, second]]
        h.state.selectedWorktreeIDs = [first.id, second.id]
        h.mount()
        try #require(h.outline.selectedRowIndexes.count == 2)

        // The daemon drops `first` without anything pruning the selection.
        h.state.worktrees[repo.id]?.removeAll { $0.id == first.id }
        h.controller.flushPendingRebuild()

        let names = [first.id: "first", second.id: "second"]
        #expect(h.controller.item(for: .worktree(first.id)) == nil, h.evidence(names))
        let uncached = h.shownItemsMissingFromCache
        #expect(uncached.isEmpty, h.evidence(names))
        let secondRow = h.row(.worktree(second.id))
        try #require(secondRow >= 0, h.evidence(names))
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: secondRow), h.evidence(names))
        #expect(h.state.selectedWorktreeIDs == [second.id], h.evidence(names))
        #expect(h.controller.appStateSelectionWriteCount == 1, "AppState must be told exactly once")
        // Converged: the rebuild that write schedules writes nothing more.
        h.controller.flushPendingRebuild()
        #expect(h.controller.appStateSelectionWriteCount == 1, h.evidence(names))
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: h.row(.worktree(second.id))), h.evidence(names))

        // A selected row that is only out of view stays selected, as in the List.
        h.state.repos[0].expanded = false
        h.controller.flushPendingRebuild()
        #expect(!h.shownIDs.contains(.worktree(second.id)))
        #expect(h.state.selectedWorktreeIDs == [second.id])
        #expect(h.controller.appStateSelectionWriteCount == 1)
    }

    @Test func headerClickSelectsRepo() throws {
        let h = OutlineHarness("headerClick")
        defer { h.tearDown() }
        h.defaults.set(true, forKey: AppState.sidebarCollapseEndedSessionsKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let row = Self.row("work", repo)
        let done = SidebarGroupFixtures.session("done", state: .exited, repoID: repo.id)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [row]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [done]
        h.state.selectedWorktreeIDs = [row.id]
        h.mount()

        #expect(h.outline.target === h.controller)
        #expect(h.outline.action == #selector(SidebarOutlineController.outlineClicked(_:)))
        let header = SidebarNodeID.repoHeader(repo.id)
        let headerItem = try #require(h.controller.item(for: header))
        let rowItem = try #require(h.controller.item(for: .worktree(row.id)))
        #expect(!h.controller.outlineView(h.outline, shouldSelectItem: headerItem), "Headers take no selection")
        #expect(h.controller.outlineView(h.outline, shouldSelectItem: rowItem))

        h.controller.handleClick(row: h.row(header))
        #expect(h.state.selectedRepoID == repo.id)
        #expect(h.state.selectedWorktreeIDs.isEmpty)
        h.controller.flushPendingRebuild()
        #expect(h.outline.selectedRowIndexes.isEmpty, "Selecting the repo clears the row selection")
        guard case .repoHeader(let model)? = h.controller.tree.node(header)?.kind else {
            Issue.record("The repo header is missing")
            return
        }
        #expect(model.isSelected, "The selected repo's header draws selected")

        // Each other header runs its own action.
        h.controller.handleClick(row: h.row(.providerHeader("acme")))
        #expect(h.state.selectedRemoteProvider == "acme")
        h.controller.handleClick(row: h.row(.scratchHeader))
        #expect(h.state.selectedScratchSection)
        let ended = SidebarGroupID(owner: .repository(repo.id), kind: .ended)
        try #require(h.row(.group(ended)) >= 0, "The fixture must show an Ended disclosure")
        h.controller.handleClick(row: h.row(.group(ended)))
        #expect(h.state.expandedSidebarGroups.contains(ended))
        h.controller.flushPendingRebuild()
        #expect(h.shownIDs.contains(.remoteSession(done.id)), "The opened group shows its rows")
    }

    @Test func chevronClickPersistsRepoExpanded() async throws {
        let h = OutlineHarness("chevron")
        defer { h.tearDown() }
        // Before the title the chevron is always shown, so there is a button
        // to click without a pointer over the header.
        h.defaults.set(true, forKey: AppState.chevronBeforeProjectNameKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let row = Self.row("work", repo)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [row]]
        h.mount()

        let header = SidebarNodeID.repoHeader(repo.id)
        let headerItem = try #require(h.controller.item(for: header))
        try #require(h.outline.isItemExpanded(headerItem))
        let cell = try #require(
            h.outline.view(atColumn: 0, row: h.row(header), makeIfNecessary: true) as? SectionHeaderCell)
        try #require(!cell.chevronButton.isHidden)
        #expect(cell.chevronButton.target === h.controller)

        cell.chevronButton.performClick(nil)
        let state = h.state
        let persisted = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { state.repos.first?.expanded == false }
        }
        #expect(persisted == .satisfied, "The chevron never wrote Repo.expanded")
        h.controller.flushPendingRebuild()
        #expect(!h.outline.isItemExpanded(headerItem))
        #expect(!h.shownIDs.contains(.worktree(row.id)))

        // The Scratch section's chevron writes its @AppStorage key.
        try #require(h.shownIDs.contains(.scratchPrompt))
        let scratchCell = try #require(
            h.outline.view(atColumn: 0, row: h.row(.scratchHeader), makeIfNecessary: true) as? SectionHeaderCell)
        scratchCell.chevronButton.performClick(nil)
        #expect(h.defaults.object(forKey: AppState.scratchSectionExpandedKey) as? Bool == false)
        h.controller.flushPendingRebuild()
        #expect(!h.shownIDs.contains(.scratchPrompt))
    }

    @Test func pendingScrollExpandsRepoThenCentersRow() throws {
        let h = OutlineHarness("pendingScroll")
        defer { h.tearDown() }
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme", expanded: false)
        let rows = (0..<60).map { Self.row("row \($0)", repo, order: $0) }
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: rows]
        h.mount(size: NSSize(width: 320, height: 200))
        let header = SidebarNodeID.repoHeader(repo.id)
        try #require(h.shownIDs == [header], "The repo must start collapsed")

        let target = rows[30]
        h.state.navigateToActiveWorktree(target.id)
        h.controller.flushPendingRebuild()

        let headerItem = try #require(h.controller.item(for: header))
        #expect(h.outline.isItemExpanded(headerItem), "The target's section expanded in the same pass")
        #expect(h.state.pendingScrollToWorktreeID == nil, "The scroll request was consumed")
        let targetRow = h.row(.worktree(target.id))
        try #require(targetRow >= 0)
        let rowMid = h.outline.rect(ofRow: targetRow).midY
        let clipMid = h.clip.bounds.midY
        #expect(abs(rowMid - clipMid) <= 1, "The target is not centred: row \(rowMid), clip \(clipMid)")
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: targetRow))

        // A later rebuild leaves the scroll where it is.
        let settled = h.clip.bounds.minY
        h.state.devServerRunningWorktreeIDs = [rows[0].id]
        h.controller.flushPendingRebuild()
        #expect(abs(h.clip.bounds.minY - settled) < 0.5)
    }

    @Test func pendingScrollDuringHoldReplaysWhenTheHoldEnds() throws {
        let h = OutlineHarness("pendingScrollHeld")
        defer { h.tearDown() }
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme", expanded: false)
        let rows = (0..<60).map { Self.row("row \($0)", repo, order: $0) }
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: rows]
        h.mount(size: NSSize(width: 320, height: 200))
        let header = SidebarNodeID.repoHeader(repo.id)

        h.controller.beginHold(.rename)
        let target = rows[30]
        h.state.navigateToActiveWorktree(target.id)
        h.controller.flushPendingRebuild()
        #expect(h.shownIDs == [header], "The section's expansion waits for the hold")
        #expect(h.clip.bounds.minY == 0)

        h.controller.endHold(.rename)
        let targetRow = h.row(.worktree(target.id))
        try #require(targetRow >= 0, "The held expansion never landed")
        let rowMid = h.outline.rect(ofRow: targetRow).midY
        let clipMid = h.clip.bounds.midY
        #expect(abs(rowMid - clipMid) <= 1, "The held scroll was dropped: row \(rowMid), clip \(clipMid)")
        #expect(h.state.pendingScrollToWorktreeID == nil)
    }

    @Test func arrowKeyFromRemoteRowMovesSelection() throws {
        let h = OutlineHarness("arrowKey")
        defer { h.tearDown() }
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        let one = SidebarGroupFixtures.session("one")
        let two = SidebarGroupFixtures.session("two")
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [one, two]
        h.mount()
        let oneRow = h.row(.remoteSession(one.id))
        let twoRow = h.row(.remoteSession(two.id))
        try #require(oneRow >= 0 && twoRow >= 0 && abs(oneRow - twoRow) == 1)
        let (upper, lower) = oneRow < twoRow ? (one, two) : (two, one)

        h.state.selectRemoteSession(provider: "acme", sessionID: upper.payload.id)
        h.controller.flushPendingRebuild()
        try #require(h.outline.selectedRowIndexes == IndexSet(integer: h.row(.remoteSession(upper.id))),
                     "A remote selection must rest on its row for the keys to move from it")

        let window = try #require(h.host?.window)
        window.makeFirstResponder(h.outline)
        let down = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        h.outline.keyDown(with: down)

        #expect(h.state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: lower.payload.id))
        #expect(h.state.selectedWorktreeIDs.isEmpty)
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: h.row(.remoteSession(lower.id))))
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
