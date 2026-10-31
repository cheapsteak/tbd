import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// The native sidebar's container — the outline above, the dock below — is
// mounted in a real, offscreen window and driven through
// `flushPendingRebuild()`, never by waiting for the main loop. Selection and
// reorder are driven through the controllers' own methods: no clicks, no key
// events, no modal UI. A drag plays AppKit's part as `SidebarDragDropTests`
// does, and its stand-in `NSDraggingInfo` reaches only the dock's own
// data-source methods, never AppKit's handlers. `reorderPins` is a recorder,
// so no test reaches a daemon. No `~/tbd`.

/// The native pinned dock: its rows and their order, the subtree shown while
/// selected, the height clamp, pin reorder, the selection it shares with the
/// outline, and the pasteboard type it keeps to itself.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Scope" (Pinned
/// dock), "Selection" and "Drag and drop" › "Dock".
@MainActor
@Suite("Native pinned dock")
struct DockTableControllerTests {
    // MARK: Rows

    @Test func dockShowsPinnedRootsInPinOrder() throws {
        let h = DockHarness("pinOrder")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = SidebarOutlineControllerTests.row("main", repo, status: .main)
        // An explicit dock order beats pin time; pins never dragged follow it,
        // oldest pin first.
        let first = Self.pinned("first", repo, order: 0, pinOrder: 1, pinnedAt: 40)
        let second = Self.pinned("second", repo, order: 1, pinOrder: 0, pinnedAt: 50)
        let late = Self.pinned("late", repo, order: 2, pinOrder: nil, pinnedAt: 30)
        let early = Self.pinned("early", repo, order: 3, pinOrder: nil, pinnedAt: 10)
        let loose = SidebarOutlineControllerTests.row("loose", repo, order: 4)
        let lane = Self.remotePin("lane", pinnedAt: 0)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [main, first, second, late, early, loose]]
        h.state.remoteSessions = [lane]
        h.mount()
        let names = [main.id: "main", first.id: "first", second.id: "second", late.id: "late",
                     early.id: "early", loose.id: "loose"]

        // Remote pins follow the worktree pins, however early they were pinned.
        let expected: [SidebarNodeID] = [
            .worktree(second.id), .worktree(first.id), .worktree(early.id), .worktree(late.id),
            .remoteSession(lane.id),
        ]
        let shown = h.shownIDs
        #expect(shown == expected, h.evidence(names))
        #expect(h.table.numberOfRows == expected.count)
        let depths = h.depths
        #expect(depths == [0, 0, 0, 0, 0])
        // Each row draws through the outline's own cell, in the same order.
        let texts = h.cellTexts
        let worktreeTexts = Array(texts.prefix(4))
        #expect(worktreeTexts == ["second", "first", "early", "late"], h.evidence(names))
        let laneCell = h.cell(.remoteSession(lane.id))
        #expect(laneCell is RemoteSessionRowCell)
        let pinnedModel = h.worktreeModel(second.id)
        #expect(pinnedModel?.isPinned == true, "A dock row draws its pin solid")

        // One batch: the explicit orders swap and `early` is unpinned. The
        // dock follows by ID, without a fallback reload.
        h.state.worktrees[repo.id]?[1].pinSortOrder = 0
        h.state.worktrees[repo.id]?[2].pinSortOrder = 1
        h.state.worktrees[repo.id]?[4].pinnedAt = nil
        h.flush()
        let reordered = h.shownIDs
        #expect(reordered == [.worktree(first.id), .worktree(second.id), .worktree(late.id), .remoteSession(lane.id)],
                h.evidence(names))
        #expect(h.table.numberOfRows == 4)
        #expect(h.dock.fallbackReloadCount == 0, h.evidence(names))
        // Rows that stayed kept their cells, and the row that moved got one
        // for itself: every cell still shows its own row.
        let reorderedTexts = Array(h.cellTexts.prefix(3))
        #expect(reorderedTexts == ["first", "second", "late"], h.evidence(names))
    }

    @Test func subtreeShownOnlyWhileSelected() throws {
        let h = DockHarness("subtree")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let a = Self.pinned("a", repo, order: 0, pinOrder: 0)
        let a1 = SidebarOutlineControllerTests.row("a1", repo, parent: a.id, order: 0)
        let a1x = SidebarOutlineControllerTests.row("a1x", repo, parent: a1.id, order: 0)
        let b = Self.pinned("b", repo, order: 1, pinOrder: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [a, a1, a1x, b]]
        h.mount()
        let names = [a.id: "a", a1.id: "a1", a1x.id: "a1x", b.id: "b"]
        let closed: [SidebarNodeID] = [.worktree(a.id), .worktree(b.id)]
        let open: [SidebarNodeID] = [.worktree(a.id), .worktree(a1.id), .worktree(a1x.id), .worktree(b.id)]

        let unselected = h.shownIDs
        #expect(unselected == closed, h.evidence(names))

        // Selecting the root opens its subtree under it, a level per depth.
        h.state.selectedWorktreeIDs = [a.id]
        h.flush()
        let rootSelected = h.shownIDs
        #expect(rootSelected == open, h.evidence(names))
        let depths = h.depths
        #expect(depths == [0, 1, 2, 0])
        // A descendant's content moves one indentation step per level, and
        // its row view draws one guide line per level.
        let deepCell = h.cell(.worktree(a1x.id)) as? WorktreeRowCell
        let deepInset = deepCell?.leadingInset
        #expect(deepInset == DockTableController.rowInset + 2 * SidebarNativeMetrics.indentation)
        let deepRowView = h.rowView(.worktree(a1x.id))
        let deepGuides = deepRowView?.configuration.guideCount
        #expect(deepGuides == 2)

        // Selecting a descendant keeps the subtree open: clicking a child in
        // the dock must not make it vanish.
        h.table.selectRowIndexes(IndexSet(integer: h.row(.worktree(a1x.id))), byExtendingSelection: false)
        #expect(h.state.selectedWorktreeIDs == [a1x.id])
        h.flush()
        let childSelected = h.shownIDs
        #expect(childSelected == open, h.evidence(names))
        let selected = h.selectedIDs
        #expect(selected == [.worktree(a1x.id)], h.evidence(names))

        // Selecting elsewhere closes it.
        h.state.selectedWorktreeIDs = [b.id]
        h.flush()
        let elsewhere = h.shownIDs
        #expect(elsewhere == closed, h.evidence(names))
        let selectedB = h.selectedIDs
        #expect(selectedB == [.worktree(b.id)], h.evidence(names))
        #expect(h.dock.fallbackReloadCount == 0, h.evidence(names))
    }

    // MARK: Height

    @Test func heightClampsToFiveRowsAndFortyPercent() throws {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let pins = (0..<7).map { index in
            Self.pinned("pin\(index)", repo, order: index, pinOrder: index, pinnedAt: TimeInterval(index))
        }
        let rowHeight = PinnedDockMetrics.rowHeight

        // A tall sidebar: seven pins want 196 pt and 40% of the column would
        // allow 239.6, so five rows cap it.
        let tall = DockHarness("height.tall")
        defer { tall.tearDown() }
        tall.state.repos = [repo]
        tall.state.worktrees = [repo.id: pins]
        tall.mount(size: NSSize(width: 320, height: 600))
        #expect(tall.table.numberOfRows == 7)
        #expect(tall.dockHeight == 5 * rowHeight, tall.evidence())
        // The dock is that tall and scrolls the rest; the outline keeps the
        // column above the divider.
        let dockFrame = tall.dock.view.frame.height
        #expect(dockFrame == 5 * rowHeight)
        let contentHeight = tall.table.rect(ofRow: 6).maxY
        #expect(contentHeight == 7 * rowHeight)
        let outlineFrame = tall.outlineController.view.frame.height
        #expect(outlineFrame == 600 - SidebarContainerController.dividerThickness - 5 * rowHeight)

        // Fewer pins than the cap: the dock fits them exactly.
        for index in 2..<7 {
            tall.state.worktrees[repo.id]?[index].pinnedAt = nil
        }
        tall.flush()
        #expect(tall.dockHeight == 2 * rowHeight, tall.evidence())

        // No pins: no dock.
        tall.state.worktrees[repo.id]?[0].pinnedAt = nil
        tall.state.worktrees[repo.id]?[1].pinnedAt = nil
        tall.flush()
        #expect(tall.dockHeight == 0, tall.evidence())

        // A short sidebar: 40% of the column binds before five rows do.
        let short = DockHarness("height.short")
        defer { short.tearDown() }
        short.state.repos = [repo]
        short.state.worktrees = [repo.id: pins]
        short.mount(size: NSSize(width: 320, height: 250))
        let shared = 250 - SidebarContainerController.dividerThickness
        let fraction = shared * PinnedDockMetrics.maxSidebarFraction
        #expect(abs(short.dockHeight - fraction) < 0.01, short.evidence())
        #expect(short.dockHeight < 5 * rowHeight)
    }

    // MARK: Reorder

    @Test func dockReorderCallsReorderPins() throws {
        let h = DockHarness("reorder")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let a = Self.pinned("a", repo, order: 0, pinOrder: 0)
        let a1 = SidebarOutlineControllerTests.row("a1", repo, parent: a.id, order: 0)
        let b = Self.pinned("b", repo, order: 1, pinOrder: 1)
        let c = Self.pinned("c", repo, order: 2, pinOrder: 2)
        let lane = Self.remotePin("lane", pinnedAt: 0)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [a, a1, b, c]]
        h.state.remoteSessions = [lane]
        // `a` selected, so its subtree is open: rows and roots no longer line
        // up, which is what a reorder must not confuse.
        h.state.selectedWorktreeIDs = [a.id]
        h.mount()
        let names = [a.id: "a", a1.id: "a1", b.id: "b", c.id: "c"]
        let shown = h.shownIDs
        try #require(
            shown == [.worktree(a.id), .worktree(a1.id), .worktree(b.id), .worktree(c.id), .remoteSession(lane.id)],
            h.evidence(names))

        // Only pinned roots drag: a descendant and a remote pin have no pin
        // order to move.
        let childWriter = h.dock.tableView(h.table, pasteboardWriterForRow: h.row(.worktree(a1.id)))
        #expect(childWriter == nil)
        let laneWriter = h.dock.tableView(h.table, pasteboardWriterForRow: h.row(.remoteSession(lane.id)))
        #expect(laneWriter == nil)

        // A press on a root's pin toggle tracks the button; a press on its
        // name can start a drag.
        let cell = try #require(h.cell(.worktree(c.id)) as? WorktreeRowCell)
        cell.layoutSubtreeIfNeeded()
        try #require(!cell.pinButton.isHidden, "A pinned row shows its pin")
        let rows = IndexSet(integer: h.row(.worktree(c.id)))
        let pin = cell.pinButton.bounds
        let pinPoint = h.table.convert(NSPoint(x: pin.midX, y: pin.midY), from: cell.pinButton)
        let name = cell.nameField.frame
        let namePoint = h.table.convert(NSPoint(x: name.midX, y: name.midY), from: cell)
        let pressedPin = h.table.canDragRows(with: rows, at: pinPoint)
        #expect(!pressedPin)
        let pressedName = h.table.canDragRows(with: rows, at: namePoint)
        #expect(pressedName)

        // `c` dragged to the top: its offset among the roots, not the rows.
        let info = try Self.startDrag(.worktree(c.id), in: h)
        defer { info.release() }
        let top = h.dock.tableView(h.table, validateDrop: info, proposedRow: 0, proposedDropOperation: .above)
        #expect(top == .move)
        let acceptedTop = h.dock.tableView(h.table, acceptDrop: info, row: 0, dropOperation: .above)
        #expect(acceptedTop)
        let firstCall = h.reorders.calls.last
        #expect(firstCall == ReorderCall(source: IndexSet(integer: 2), destination: 0), h.evidence(names))
        // Those offsets are the move `reorderPins` makes.
        let moved = PinnedDockReorder.reordered(
            roots: [a.id, b.id, c.id], fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(moved == [c.id, a.id, b.id])

        // A gap inside `a`'s open subtree — between `a` and `a1` — is the gap
        // after it, before `b`: root offset 1, where row index 1 would be
        // `a1`.
        let inside = h.dock.tableView(h.table, validateDrop: info, proposedRow: 1, proposedDropOperation: .above)
        #expect(inside == .move)
        let acceptedInside = h.dock.tableView(h.table, acceptDrop: info, row: 1, dropOperation: .above)
        #expect(acceptedInside)
        let secondCall = h.reorders.calls.last
        #expect(secondCall == ReorderCall(source: IndexSet(integer: 2), destination: 1), h.evidence(names))

        // A pin unpinned mid-drag: the drag holds the dock's rows, so `c`
        // still shows, but the drop is refused and nothing is reordered.
        h.state.worktrees[repo.id]?[3].pinnedAt = nil
        h.dock.flushPendingRebuild()
        let held = h.shownIDs
        #expect(held.contains(.worktree(c.id)), "The drag holds the dock's rows")
        let callsBefore = h.reorders.calls.count
        let acceptedStale = h.dock.tableView(h.table, acceptDrop: info, row: 0, dropOperation: .above)
        #expect(!acceptedStale)
        #expect(h.reorders.calls.count == callsBefore)

        // The held rows land as the drag ends.
        Self.endDrag(in: h)
        let after = h.shownIDs
        #expect(!after.contains(.worktree(c.id)), h.evidence(names))
    }

    // MARK: Selection

    @Test func dockSelectionSharedWithOutline() throws {
        let h = DockHarness("selection")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = SidebarOutlineControllerTests.row("main", repo, status: .main)
        let a = Self.pinned("a", repo, order: 0, pinOrder: 0)
        let a1 = SidebarOutlineControllerTests.row("a1", repo, parent: a.id, order: 0)
        let b = Self.pinned("b", repo, order: 1, pinOrder: 1)
        let loose = SidebarOutlineControllerTests.row("loose", repo, order: 2)
        let lane = Self.remotePin("lane", pinnedAt: 0)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [main, a, a1, b, loose]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [lane]
        h.mount()
        let names = [main.id: "main", a.id: "a", a1.id: "a1", b.id: "b", loose.id: "loose"]

        // Dock to AppState to outline.
        h.table.selectRowIndexes(IndexSet(integer: h.row(.worktree(b.id))), byExtendingSelection: false)
        #expect(h.state.selectedWorktreeIDs == [b.id])
        #expect(h.dock.appStateSelectionWriteCount == 1)
        h.flush()
        let outlineAfterDock = h.outlineSelectedIDs
        #expect(outlineAfterDock == [.worktree(b.id)], h.evidence(names))
        let dockAfterDock = h.selectedIDs
        #expect(dockAfterDock == [.worktree(b.id)], h.evidence(names))

        // Outline to AppState to dock: a child selected in the outline opens
        // its pinned parent's subtree in the dock and lights its copy there.
        let suppressedBefore = h.dock.suppressedSelectionNotificationCount
        let outline = h.outlineController.outline
        outline.selectRowIndexes(IndexSet(integer: h.outlineRow(.worktree(a1.id))), byExtendingSelection: false)
        #expect(h.state.selectedWorktreeIDs == [a1.id])
        h.flush()
        let opened = h.shownIDs
        #expect(opened == [.worktree(a.id), .worktree(a1.id), .worktree(b.id), .remoteSession(lane.id)],
                h.evidence(names))
        let dockAfterOutline = h.selectedIDs
        #expect(dockAfterOutline == [.worktree(a1.id)], h.evidence(names))
        // Mirroring is never written back.
        #expect(h.dock.appStateSelectionWriteCount == 1, h.evidence(names))
        #expect(h.dock.suppressedSelectionNotificationCount > suppressedBefore,
                "The dock posted no selection change while mirroring, so the guard was never tested")

        // A row the dock does not show: the dock selects nothing.
        outline.selectRowIndexes(IndexSet(integer: h.outlineRow(.worktree(loose.id))), byExtendingSelection: false)
        #expect(h.state.selectedWorktreeIDs == [loose.id])
        h.flush()
        let dockForLoose = h.selectedIDs
        #expect(dockForLoose.isEmpty, h.evidence(names))

        // A remote pin selected in the dock routes through
        // `selectRemoteSession`, and both lists keep its row selected.
        h.table.selectRowIndexes(IndexSet(integer: h.row(.remoteSession(lane.id))), byExtendingSelection: false)
        #expect(h.state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "lane"))
        #expect(h.state.selectedWorktreeIDs.isEmpty)
        h.flush()
        let dockRemote = h.selectedIDs
        #expect(dockRemote == [.remoteSession(lane.id)], h.evidence(names))
        let outlineRemote = h.outlineSelectedIDs
        #expect(outlineRemote == [.remoteSession(lane.id)], h.evidence(names))
    }

    // MARK: Pasteboard types

    @Test func dockRejectsSidebarPayload() throws {
        let h = DockHarness("payload")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let a = Self.pinned("a", repo, order: 0, pinOrder: 0)
        let b = Self.pinned("b", repo, order: 1, pinOrder: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [a, b]]
        h.mount()
        let names = [a.id: "a", b.id: "b"]

        // Each list registers its own type only.
        let dockTypes = h.table.registeredDraggedTypes
        #expect(dockTypes.contains(.tbdDockPin))
        #expect(!dockTypes.contains(.tbdSidebarWorktrees))
        let outlineTypes = h.outlineController.outline.registeredDraggedTypes
        #expect(!outlineTypes.contains(.tbdDockPin))

        // The dock writes its rows under its own type alone.
        let writer = h.dock.tableView(h.table, pasteboardWriterForRow: h.row(.worktree(b.id))) as? NSPasteboardItem
        let dockString = writer?.string(forType: .tbdDockPin)
        #expect(dockString == b.id.uuidString)
        let sidebarString = writer?.string(forType: .tbdSidebarWorktrees)
        #expect(sidebarString == nil)

        // A sidebar row dragged over the dock: refused, and nothing reorders.
        let sidebar = Self.dragInfo(carrying: [b.id], as: .tbdSidebarWorktrees)
        defer { sidebar.release() }
        let operation = h.dock.tableView(h.table, validateDrop: sidebar, proposedRow: 0, proposedDropOperation: .above)
        #expect(operation == [])
        let accepted = h.dock.tableView(h.table, acceptDrop: sidebar, row: 0, dropOperation: .above)
        #expect(!accepted)
        #expect(h.reorders.calls.isEmpty, h.evidence(names))

        // Control: the same row under the dock's own type moves.
        let pin = Self.dragInfo(carrying: [b.id], as: .tbdDockPin)
        defer { pin.release() }
        let control = h.dock.tableView(h.table, validateDrop: pin, proposedRow: 0, proposedDropOperation: .above)
        #expect(control == .move)
        let acceptedPin = h.dock.tableView(h.table, acceptDrop: pin, row: 0, dropOperation: .above)
        #expect(acceptedPin)
        let call = h.reorders.calls.last
        #expect(call == ReorderCall(source: IndexSet(integer: 1), destination: 0), h.evidence(names))
    }

    // MARK: Fixtures

    /// A worktree pinned to the dock: `pinOrder` is its explicit dock
    /// position, nil for one never dragged; `pinnedAt` counts seconds from a
    /// fixed epoch.
    private static func pinned(_ name: String, _ repo: Repo, parent: UUID? = nil, order: Int = 0,
                               pinOrder: Int?, pinnedAt seconds: TimeInterval = 0) -> Worktree {
        var worktree = SidebarOutlineControllerTests.row(name, repo, parent: parent, order: order)
        worktree.pinnedAt = Date(timeIntervalSince1970: 1_700_000_000 + seconds)
        worktree.pinSortOrder = pinOrder
        return worktree
    }

    /// A remote session pinned to the dock.
    private static func remotePin(_ sessionID: String, pinnedAt seconds: TimeInterval) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: "acme",
            payload: .init(id: sessionID, state: .running, agentState: .idle, archived: false),
            gone: false, dismissed: false, lastSeen: Date(),
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }

    // MARK: Playing AppKit's part

    /// A drag of `id`'s row: the writer AppKit asks the dock for, put on a
    /// fresh pasteboard, and the session begun.
    private static func startDrag(_ id: SidebarNodeID, in h: DockHarness) throws -> DockStubDraggingInfo {
        let index = h.row(id)
        try #require(index >= 0, "The row to drag is not shown")
        let writer = try #require(h.dock.tableView(h.table, pasteboardWriterForRow: index))
        h.dock.tableView(h.table, draggingSession: NSDraggingSession(), willBeginAt: .zero,
                         forRowIndexes: IndexSet(integer: index))
        return DockStubDraggingInfo(writing: [writer])
    }

    private static func endDrag(in h: DockHarness) {
        h.dock.tableView(h.table, draggingSession: NSDraggingSession(), endedAt: .zero, operation: .move)
    }

    /// A drag carrying `ids` under `type`, one pasteboard item each.
    private static func dragInfo(carrying ids: [UUID], as type: NSPasteboard.PasteboardType) -> DockStubDraggingInfo {
        var writers: [any NSPasteboardWriting] = []
        for id in ids {
            let item = NSPasteboardItem()
            item.setString(id.uuidString, forType: type)
            writers.append(item)
        }
        return DockStubDraggingInfo(writing: writers)
    }
}

// MARK: - Harness

/// One `reorderPins` call the dock made.
private struct ReorderCall: Equatable {
    let source: IndexSet
    let destination: Int
}

/// Stands in for `AppState.reorderPins(fromOffsets:toOffset:)`.
@MainActor
private final class ReorderRecorder {
    var calls: [ReorderCall] = []
}

/// A `SidebarContainerController` over an `AppState` fixture: configure
/// `state`, then `mount()` to run both lists' first load offscreen.
@MainActor
private final class DockHarness {
    let suite: TestDefaultsSuite
    let state: AppState
    let container: SidebarContainerController
    let reorders = ReorderRecorder()
    private(set) var host: OffscreenAppKitHost?

    var dock: DockTableController { container.dockController }
    var outlineController: SidebarOutlineController { container.outlineController }
    var table: DockTableView { dock.table }

    init(_ label: String) {
        suite = TestDefaultsSuite("DockTableControllerTests.\(label)")
        state = AppState(userDefaults: suite.defaults)
        container = SidebarContainerController(appState: state, defaults: suite.defaults)
        let recorder = reorders
        container.dockController.reorderPinsForTesting = { source, destination in
            recorder.calls.append(ReorderCall(source: source, destination: destination))
        }
    }

    func mount(size: NSSize = NSSize(width: 320, height: 600)) {
        host = OffscreenAppKitHost(controller: container, size: size)
        flush()
    }

    /// Runs both lists' pending rebuilds, then lays the window out.
    func flush() {
        outlineController.flushPendingRebuild()
        dock.flushPendingRebuild()
        host?.layout()
    }

    func tearDown() {
        host?.tearDown()
        suite.tearDown()
    }

    /// The dock's rows, top to bottom.
    var shownIDs: [SidebarNodeID] {
        dock.rows.map { $0.id }
    }

    var depths: [Int] {
        dock.rows.map { $0.depth }
    }

    /// The dock row showing `id`, or -1.
    func row(_ id: SidebarNodeID) -> Int {
        dock.rows.firstIndex { $0.id == id } ?? -1
    }

    /// The dock's selected rows, top to bottom.
    var selectedIDs: [SidebarNodeID] {
        let rows = dock.rows
        return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
    }

    /// The outline row showing `id`, or -1.
    func outlineRow(_ id: SidebarNodeID) -> Int {
        guard let item = outlineController.item(for: id) else { return -1 }
        return outlineController.outline.row(forItem: item)
    }

    /// The outline's selected rows, top to bottom.
    var outlineSelectedIDs: [SidebarNodeID] {
        let outline = outlineController.outline
        return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
    }

    func cell(_ id: SidebarNodeID) -> NSView? {
        let index = row(id)
        guard index >= 0 else { return nil }
        return table.view(atColumn: 0, row: index, makeIfNecessary: true)
    }

    /// The name each dock row's cell shows, top to bottom.
    var cellTexts: [String?] {
        dock.rows.indices.map { index in
            (table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
    }

    func rowView(_ id: SidebarNodeID) -> SidebarRowView? {
        let index = row(id)
        guard index >= 0 else { return nil }
        return table.rowView(atRow: index, makeIfNecessary: true) as? SidebarRowView
    }

    func worktreeModel(_ id: UUID) -> WorktreeRowModel? {
        guard let index = dock.rows.firstIndex(where: { $0.id == .worktree(id) }),
              case .worktree(let model) = dock.rows[index].kind else { return nil }
        return model
    }

    /// The dock height constraint's constant.
    var dockHeight: CGFloat {
        container.dockHeight?.constant ?? -1
    }

    /// What a failing expectation prints: the dock's rows and selection,
    /// `AppState`'s selection, the fallback count and the dock's height.
    func evidence(_ names: [UUID: String] = [:]) -> Comment {
        let shown = shownIDs.map { OutlineHarness.label($0, names) }.joined(separator: ", ")
        let selected = selectedIDs.map { OutlineHarness.label($0, names) }.joined(separator: ", ")
        let appSelection = state.selectedWorktreeIDs.map { names[$0] ?? OutlineHarness.short($0) }
            .sorted().joined(separator: ", ")
        return Comment(rawValue: "dock [\(shown)] · dock selected [\(selected)]"
            + " · AppState selection [\(appSelection)] · fallbacks \(dock.fallbackReloadCount)"
            + " · dock height \(dockHeight) of \(container.dockAvailableHeight)")
    }
}

/// An `NSDraggingInfo` over a uniquely named pasteboard, for driving the
/// dock's `validateDrop` and `acceptDrop` without a drag session. Call
/// `release()` once done with it.
@MainActor
private final class DockStubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    /// Where the pointer is, in window coordinates.
    var draggingLocation: NSPoint = .zero
    let draggingSequenceNumber = Int.random(in: 1...Int.max)
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
        super.init()
    }

    /// A fresh pasteboard holding `writers`, one item each.
    convenience init(writing writers: [any NSPasteboardWriting]) {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        _ = pasteboard.writeObjects(writers)
        self.init(pasteboard: pasteboard)
    }

    func release() {
        draggingPasteboard.releaseGlobally()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    func resetSpringLoading() {}
}
