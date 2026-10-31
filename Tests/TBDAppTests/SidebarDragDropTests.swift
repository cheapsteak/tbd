import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// An offscreen window cannot run a real drag session, so these tests play
// AppKit's part: they press a row through `canDragRows(with:at:)`, ask the
// controller for a writer per row AppKit would ask about, put what comes back
// on a uniquely named pasteboard, and drive the session callbacks,
// `validateDrop` and `acceptDrop` with a stub `NSDraggingInfo`.
// `worktree.moveMany` is a recorder behind `worktreeMoveManySender`, so no
// test reaches a daemon. No `~/tbd`.

/// The native sidebar's drag and drop: what a drag carries, what a drop
/// proposal resolves to, the move a drop makes, the structure held for the
/// whole drag, the expansion veto, and the feedback drawn for a proposal.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Drag and drop".
@MainActor
@Suite("Native sidebar drag and drop")
struct SidebarDragDropTests {
    // MARK: What a drag carries

    @Test func dragFromSelectedRowCarriesSelection() throws {
        let h = OutlineHarness("drag.selection")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.state.selectedWorktreeIDs = [f.main.id, f.a.id, f.a1.id, f.c.id]
        h.mount()
        try #require(h.outline.selectedRowIndexes.count == 4, h.evidence(f.names))

        let origin = SidebarNodeID.worktree(f.c.id)
        Self.press(origin, in: h)
        #expect(h.outline.dragOrigin == origin)

        // AppKit asks for a writer for every selected row.
        let written = Self.selectedIDs(in: h).compactMap { Self.writtenID(for: $0, in: h) }
        #expect(written == [f.a.id, f.c.id], h.evidence(f.names))
        let mainWriter = Self.writtenID(for: .worktree(f.main.id), in: h)
        #expect(mainWriter == nil, "The main row stays behind")
        let childWriter = Self.writtenID(for: .worktree(f.a1.id), in: h)
        #expect(childWriter == nil, "A selected row whose ancestor is selected travels with it")
    }

    @Test func dragFromUnselectedRowCarriesOnlyIt() throws {
        let h = OutlineHarness("drag.unselected")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.state.selectedWorktreeIDs = [f.a.id, f.c.id]
        h.mount()
        try #require(h.outline.selectedRowIndexes.count == 2, h.evidence(f.names))

        Self.press(.worktree(f.b.id), in: h)
        // AppKit asks for the pressed row alone.
        let pressed = Self.writtenID(for: .worktree(f.b.id), in: h)
        #expect(pressed == f.b.id)
        // Asked about the selection, none of it would travel either.
        let selectedA = Self.writtenID(for: .worktree(f.a.id), in: h)
        let selectedC = Self.writtenID(for: .worktree(f.c.id), in: h)
        #expect(selectedA == nil)
        #expect(selectedC == nil)
    }

    @Test func childOfSelectedParentStillDrags() throws {
        let h = OutlineHarness("drag.childOfSelected")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.state.selectedWorktreeIDs = [f.a.id]
        h.mount()

        // The child is not selected, so its selected parent does not take its
        // writer away: the drag starts, carrying the child.
        let child = SidebarNodeID.worktree(f.a1.id)
        Self.press(child, in: h)
        let unselected = Self.writtenID(for: child, in: h)
        #expect(unselected == f.a1.id)

        // Control: once the child is selected too, it travels with its parent
        // instead of on its own.
        h.state.selectedWorktreeIDs = [f.a.id, f.a1.id]
        h.controller.flushPendingRebuild()
        try #require(h.outline.selectedRowIndexes.count == 2, h.evidence(f.names))
        Self.press(child, in: h)
        let selectedChild = Self.writtenID(for: child, in: h)
        let parent = Self.writtenID(for: .worktree(f.a.id), in: h)
        #expect(selectedChild == nil)
        #expect(parent == f.a.id)
    }

    @Test func buttonPressDoesNotStartDrag() throws {
        let h = OutlineHarness("drag.buttons")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.mount()

        // Hover shows the row's pin toggle and nested `+`.
        let id = SidebarNodeID.worktree(f.b.id)
        let tracker = try #require(h.controller.hoverTracker)
        let hoverPoint = try #require(Self.windowCenter(of: id, in: h))
        tracker.pointerMoved(toWindowPoint: hoverPoint)
        let cell = try #require(Self.cell(id, in: h) as? WorktreeRowCell)
        cell.layoutSubtreeIfNeeded()
        try #require(!cell.pinButton.isHidden)
        try #require(!cell.plusButton.isHidden)

        let rows = IndexSet(integer: h.row(id))
        let pin = cell.pinButton.bounds
        let plus = cell.plusButton.bounds
        let name = cell.nameField.frame
        let pinPoint = h.outline.convert(NSPoint(x: pin.midX, y: pin.midY), from: cell.pinButton)
        let plusPoint = h.outline.convert(NSPoint(x: plus.midX, y: plus.midY), from: cell.plusButton)
        let namePoint = h.outline.convert(NSPoint(x: name.midX, y: name.midY), from: cell)

        // A press on either button tracks the button.
        let pressedPin = h.outline.canDragRows(with: rows, at: pinPoint)
        #expect(!pressedPin)
        #expect(h.outline.dragOrigin == nil)
        let pressedPlus = h.outline.canDragRows(with: rows, at: plusPoint)
        #expect(!pressedPlus)
        #expect(h.outline.dragOrigin == nil)

        // The name is a plain label, so a press on it reaches the outline and
        // can start a drag from the row.
        #expect(!cell.nameField.isSelectable)
        let pressedName = h.outline.canDragRows(with: rows, at: namePoint)
        #expect(pressedName)
        #expect(h.outline.dragOrigin == id)

        // A plain click is no drag: the origin it recorded does not outlive
        // it, so a later drag never reads a stale one.
        h.controller.outlineClicked(nil)
        #expect(h.outline.dragOrigin == nil)
    }

    @Test func holdingOptionKeepsTheDropAMove() throws {
        let h = OutlineHarness("drag.modifiers")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.mount()

        // Rows move within the app and never leave it…
        let session = NSDraggingSession()
        let within = h.outline.draggingSession(session, sourceOperationMaskFor: .withinApplication)
        let outside = h.outline.draggingSession(session, sourceOperationMaskFor: .outsideApplication)
        #expect(within == .move)
        #expect(outside == [])
        // …and a modifier key held mid-drag — ⌥ above all — does not narrow
        // that move to an operation the sidebar refuses.
        let ignoresModifiers = h.outline.ignoreModifierKeys(for: session)
        #expect(ignoresModifiers)
    }

    @Test func multiItemPayloadReadsEveryPasteboardItem() async throws {
        let h = OutlineHarness("drag.multiItem")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        let recorder = MoveRecorder()
        recorder.install(on: h.state)
        h.mount()

        // Two items, the lower row's first: a read of the first item alone
        // would carry only `c`, and pasteboard order is not tree order.
        let info = Self.dragInfo(carrying: [f.c.id, f.b.id])
        defer { info.release() }
        let itemCount = info.draggingPasteboard.pasteboardItems?.count
        #expect(itemCount == 2)
        let payload = SidebarOutlineController.dragPayload(from: info.draggingPasteboard)
        #expect(payload == SidebarDragPayload(worktreeIDs: [f.c.id, f.b.id]))

        Self.beginSession(in: h)
        let onto = SidebarNodeID.worktree(f.a.id)
        let operation = try Self.validate(info, parent: onto, childIndex: SidebarDropPolicy.dropOnItemIndex, in: h)
        #expect(operation == .move)
        let accepted = try Self.accept(info, parent: onto, childIndex: SidebarDropPolicy.dropOnItemIndex, in: h)
        #expect(accepted)
        Self.endSession(in: h)

        await recorder.waitForCount(1)
        let sent = recorder.sent.first
        #expect(sent?.worktreeIDs == [f.b.id, f.c.id], "Both rows, in tree order")
        #expect(sent?.newParentID == f.a.id)
        #expect(sent?.beforeWorktreeID == nil)
    }

    // MARK: Where it can go

    @Test func validateDropReturnsMoveForNest() throws {
        let h = OutlineHarness("drag.validateNest")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.mount()

        let info = try Self.startDrag(pressing: .worktree(f.c.id), in: h)
        defer { info.release() }
        let target = SidebarNodeID.worktree(f.b.id)
        let operation = try Self.validate(info, parent: target, childIndex: SidebarDropPolicy.dropOnItemIndex, in: h)
        #expect(operation == .move)

        // The target row draws the nest highlight; no insertion line shows.
        #expect(h.controller.nestTargetID == target)
        let rowView = try #require(h.rowView(target, make: true) as? SidebarRowView)
        #expect(rowView.configuration.isNestTarget)
        #expect(h.controller.dropIndicator.line == nil)

        // Onto the carried row itself: rejected, and the highlight clears.
        let carried = SidebarNodeID.worktree(f.c.id)
        let ontoItself = try Self.validate(info, parent: carried, childIndex: SidebarDropPolicy.dropOnItemIndex, in: h)
        #expect(ontoItself == [])
        #expect(h.controller.nestTargetID == nil)
        #expect(!rowView.configuration.isNestTarget)
        Self.endSession(in: h)
    }

    @Test func dropIndicatorDrawsAtTheDestinationDepthAndClears() throws {
        let h = OutlineHarness("drag.indicator")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.mount()
        let info = try Self.startDrag(pressing: .worktree(f.c.id), in: h)
        defer { info.release() }
        let repo = SidebarNodeID.repoHeader(f.repo.id)
        let a = SidebarNodeID.worktree(f.a.id)
        let inset = h.controller.dropDepthInset
        let step = SidebarNativeMetrics.indentation
        let guide = SidebarNativeMetrics.guideLineOffset
        // The outline draws no feedback of its own; the controller draws it.
        let feedbackStyle = h.outline.draggingDestinationFeedbackStyle
        #expect(feedbackStyle == NSTableView.DraggingDestinationFeedbackStyle.none)

        // Just below main, at the top level: across `a`'s top, from the guide
        // column of depth 0.
        let belowMain = try Self.childIndex(of: a, under: repo, in: h)
        let top = try Self.validate(info, parent: repo, childIndex: belowMain, depth: 0, in: h)
        #expect(top == .move)
        let aTop = h.outline.rect(ofRow: h.row(a)).minY
        #expect(Self.lineStart(in: h) == Self.point(x: inset - guide, y: aTop, in: h))
        #expect(h.controller.nestTargetID == nil)

        // The line stops short of the clip view's edge, and of a vertical
        // scroller when one shows; the overlay never takes a click.
        let line = try #require(h.controller.dropIndicator.line)
        let clipEdge = h.controller.dropIndicator.convert(
            NSPoint(x: h.clip.frame.maxX, y: 0), from: h.controller.scrollView).x
        #expect(line.endX == h.controller.dropLineEndX)
        #expect(line.endX <= clipEdge - SidebarDropIndicatorView.trailingInset)
        #expect(line.endX > line.x)
        let probe = NSPoint(x: line.x, y: line.y)
        #expect(h.controller.dropIndicator.hitTest(probe) == nil)

        // The gap below `a1`, the end of `a`'s children: the pointer's depth
        // picks the level. One step in, the rows join `a`'s children…
        let a1Bottom = h.outline.rect(ofRow: h.row(.worktree(f.a1.id))).maxY
        let nested = try Self.validate(info, parent: a, childIndex: 1, depth: 1, in: h)
        #expect(nested == .move)
        #expect(Self.lineStart(in: h) == Self.point(x: inset + step - guide, y: a1Bottom, in: h))
        // …and at depth 0 they land at the top level, between `a`'s subtree
        // and `b`.
        let shallow = try Self.validate(info, parent: a, childIndex: 1, depth: 0, in: h)
        #expect(shallow == .move)
        #expect(Self.lineStart(in: h) == Self.point(x: inset - guide, y: a1Bottom, in: h))
        Self.endSession(in: h)
        #expect(h.controller.dropIndicator.line == nil)
    }

    @Test func retargetsOnlyWhenTheAnswerDiffers() throws {
        let h = OutlineHarness("drag.retarget")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.mount()
        let info = try Self.startDrag(pressing: .worktree(f.c.id), in: h)
        defer { info.release() }
        let repo = SidebarNodeID.repoHeader(f.repo.id)
        let a = SidebarNodeID.worktree(f.a.id)
        let b = SidebarNodeID.worktree(f.b.id)
        let onto = SidebarDropPolicy.dropOnItemIndex

        // Proposals the policy takes as they are: no retarget.
        let belowMain = try Self.childIndex(of: a, under: repo, in: h)
        let gap = try Self.validate(info, parent: repo, childIndex: belowMain, depth: 0, in: h)
        let nested = try Self.validate(info, parent: a, childIndex: 1, depth: 1, in: h)
        let nest = try Self.validate(info, parent: b, childIndex: onto, in: h)
        #expect([gap, nested, nest] == [.move, .move, .move])
        #expect(h.outline.dropRetargetCount == 0)

        // The end of `a`'s children with the pointer at depth 0 means the top
        // level, between `a`'s subtree and `b`: retargeted there.
        let shallow = try Self.validate(info, parent: a, childIndex: 1, depth: 0, in: h)
        #expect(shallow == .move)
        #expect(h.outline.dropRetargetCount == 1)
        let aboveB = try Self.childIndex(of: b, under: repo, in: h)
        #expect(h.outline.lastDropRetarget?.item == repo)
        #expect(h.outline.lastDropRetarget?.childIndex == aboveB)

        // Onto the main row un-nests directly below it: retargeted there too.
        let main = SidebarNodeID.worktree(f.main.id)
        let ontoMain = try Self.validate(info, parent: main, childIndex: onto, in: h)
        #expect(ontoMain == .move)
        #expect(h.outline.dropRetargetCount == 2)
        #expect(h.outline.lastDropRetarget?.item == repo)
        #expect(h.outline.lastDropRetarget?.childIndex == belowMain)

        // A rejected proposal is not retargeted.
        let ontoItself = try Self.validate(info, parent: .worktree(f.c.id), childIndex: onto, in: h)
        #expect(ontoItself == [])
        #expect(h.outline.dropRetargetCount == 2)
        Self.endSession(in: h)
    }

    @Test func dragEndingMessagesClearTheFeedback() throws {
        let h = OutlineHarness("drag.feedbackEnds")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        h.mount()
        let info = try Self.startDrag(pressing: .worktree(f.c.id), in: h)
        defer { info.release() }
        let repo = SidebarNodeID.repoHeader(f.repo.id)
        let b = SidebarNodeID.worktree(f.b.id)
        let aboveB = try Self.childIndex(of: b, under: repo, in: h)
        let onto = SidebarDropPolicy.dropOnItemIndex

        // Leaving the outline.
        _ = try Self.validate(info, parent: repo, childIndex: aboveB, depth: 0, in: h)
        try #require(h.controller.dropIndicator.line != nil)
        h.outline.draggingExited(nil)
        #expect(h.controller.dropIndicator.line == nil)
        _ = try Self.validate(info, parent: b, childIndex: onto, in: h)
        try #require(h.controller.nestTargetID == b)
        h.outline.draggingExited(nil)
        #expect(h.controller.nestTargetID == nil)

        // Concluding over it.
        _ = try Self.validate(info, parent: repo, childIndex: aboveB, depth: 0, in: h)
        try #require(h.controller.dropIndicator.line != nil)
        h.outline.concludeDragOperation(nil)
        #expect(h.controller.dropIndicator.line == nil)
        _ = try Self.validate(info, parent: b, childIndex: onto, in: h)
        try #require(h.controller.nestTargetID == b)
        h.outline.concludeDragOperation(nil)
        #expect(h.controller.nestTargetID == nil)

        // Ending over it.
        _ = try Self.validate(info, parent: repo, childIndex: aboveB, depth: 0, in: h)
        try #require(h.controller.dropIndicator.line != nil)
        h.outline.draggingEnded(info)
        #expect(h.controller.dropIndicator.line == nil)
        _ = try Self.validate(info, parent: b, childIndex: onto, in: h)
        try #require(h.controller.nestTargetID == b)
        h.outline.draggingEnded(info)
        #expect(h.controller.nestTargetID == nil)

        // The session ending clears it too.
        _ = try Self.validate(info, parent: b, childIndex: onto, in: h)
        try #require(h.controller.nestTargetID == b)
        Self.endSession(in: h)
        #expect(h.controller.nestTargetID == nil)
        #expect(h.controller.dropIndicator.line == nil)
    }

    @Test func insertionLineFollowsItsRowsWhenTheOutlineScrolls() throws {
        let h = OutlineHarness("drag.scroll")
        defer { h.tearDown() }
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let rows = (0..<40).map { SidebarOutlineControllerTests.row("row \($0)", repo, order: $0) }
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: rows]
        h.mount(size: NSSize(width: 320, height: 200))
        let header = SidebarNodeID.repoHeader(repo.id)
        let target = SidebarNodeID.worktree(rows[4].id)

        let info = try Self.startDrag(pressing: .worktree(rows[1].id), in: h)
        defer { info.release() }
        let gap = try Self.childIndex(of: target, under: header, in: h)
        let operation = try Self.validate(info, parent: header, childIndex: gap, depth: 0, in: h)
        #expect(operation == .move)
        let before = try #require(h.controller.dropIndicator.line)
        let expectedBefore = Self.point(x: 0, y: h.outline.rect(ofRow: h.row(target)).minY, in: h)
        #expect(before.y == expectedBefore.y)

        // Two rows scroll under the still pointer, and no proposal arrives.
        h.clip.scroll(to: NSPoint(x: 0, y: h.clip.bounds.minY + 2 * WorktreeRowView.rowHeight))
        h.controller.scrollView.reflectScrolledClipView(h.clip)
        try #require(h.clip.bounds.minY > 0, "The clip view did not scroll")

        // The line moved with the row boundary it marks.
        let after = try #require(h.controller.dropIndicator.line)
        let expectedAfter = Self.point(x: 0, y: h.outline.rect(ofRow: h.row(target)).minY, in: h)
        #expect(after.y == expectedAfter.y)
        #expect(after.y < before.y, "The line stayed put while its rows scrolled")
        #expect(after.x == before.x)
        Self.endSession(in: h)
    }

    @Test func dockPayloadRejectedByMainList() throws {
        let h = OutlineHarness("drag.dockPayload")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        let recorder = MoveRecorder()
        recorder.install(on: h.state)
        h.mount()

        let registered = h.outline.registeredDraggedTypes
        #expect(registered.contains(.tbdSidebarWorktrees))
        #expect(!registered.contains(.tbdDockPin))

        // A pinned dock row: the same worktree, under the dock's own type.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let pin = NSPasteboardItem()
        pin.setString(f.c.id.uuidString, forType: .tbdDockPin)
        let wrote = pasteboard.writeObjects([pin])
        try #require(wrote)
        let dock = StubDraggingInfo(pasteboard: pasteboard)

        let target = SidebarNodeID.worktree(f.a.id)
        let onto = SidebarDropPolicy.dropOnItemIndex
        let operation = try Self.validate(dock, parent: target, childIndex: onto, in: h)
        #expect(operation == [])
        #expect(h.controller.nestTargetID == nil)
        let accepted = try Self.accept(dock, parent: target, childIndex: onto, in: h)
        #expect(!accepted)
        #expect(h.state.pendingWorktreeMoves.isEmpty)

        // Control: the same row under the sidebar's own type nests there.
        let sidebar = Self.dragInfo(carrying: [f.c.id])
        defer { sidebar.release() }
        let control = try Self.validate(sidebar, parent: target, childIndex: onto, in: h)
        #expect(control == .move)
    }

    // MARK: The drop

    @Test func acceptDropCallsMoveWorktreesWithDecision() async throws {
        let h = OutlineHarness("drag.accept")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        let recorder = MoveRecorder()
        recorder.install(on: h.state)
        h.mount()
        let repo = SidebarNodeID.repoHeader(f.repo.id)
        let a = SidebarNodeID.worktree(f.a.id)
        let b = SidebarNodeID.worktree(f.b.id)
        let c = SidebarNodeID.worktree(f.c.id)

        // A place: `c` into the gap above `b`, at the top level.
        let place = try Self.startDrag(pressing: c, in: h)
        defer { place.release() }
        let aboveB = try Self.childIndex(of: b, under: repo, in: h)
        let placeOperation = try Self.validate(place, parent: repo, childIndex: aboveB, depth: 0, in: h)
        #expect(placeOperation == .move)
        let placed = try Self.accept(place, parent: repo, childIndex: aboveB, in: h)
        #expect(placed)
        // The rows are not in place until the hold ends: no animation to them.
        #expect(!place.animatesToDestination)
        Self.endSession(in: h)
        let shown = h.shownIDs
        let cRow = try #require(shown.firstIndex(of: c))
        let bRow = try #require(shown.firstIndex(of: b))
        #expect(cRow < bRow, h.evidence(f.names))
        #expect(shown == h.freshTree().visibleIDs)

        // A nest: `b` onto `a`.
        let nest = try Self.startDrag(pressing: b, in: h)
        defer { nest.release() }
        let onto = SidebarDropPolicy.dropOnItemIndex
        let nestOperation = try Self.validate(nest, parent: a, childIndex: onto, in: h)
        #expect(nestOperation == .move)
        let nested = try Self.accept(nest, parent: a, childIndex: onto, in: h)
        #expect(nested)
        Self.endSession(in: h)
        #expect(h.controller.tree.parent(of: b) == a, h.evidence(f.names))

        await recorder.waitForCount(2)
        let sent = recorder.sent
        #expect(sent.count == 2)
        // Each move sends from a task of its own, so neither request's
        // position in the log is part of the contract.
        let placeRequest = sent.first { $0.worktreeIDs == [f.c.id] }
        let nestRequest = sent.first { $0.worktreeIDs == [f.b.id] }
        // The place maps field for field.
        let placeParams = try #require(placeRequest)
        #expect(placeParams.newParentID == nil)
        #expect(placeParams.beforeWorktreeID == f.b.id)
        // The nest is `newParentID: id, before: nil`.
        let nestParams = try #require(nestRequest)
        #expect(nestParams.newParentID == f.a.id)
        #expect(nestParams.beforeWorktreeID == nil)
    }

    /// Review Focus 1: a target or a carried row archived during the drag.
    /// The shown structure is held, so the row is still on screen, but the
    /// drop is checked against `AppState` as it stands: rejected, nothing
    /// moves, and the outline catches up when the drag ends.
    @Test func targetArchivedMidDragRejectsAtAccept() throws {
        let h = OutlineHarness("drag.archived")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        let recorder = MoveRecorder()
        recorder.install(on: h.state)
        h.mount()
        let a = SidebarNodeID.worktree(f.a.id)
        let b = SidebarNodeID.worktree(f.b.id)
        let c = SidebarNodeID.worktree(f.c.id)
        let onto = SidebarDropPolicy.dropOnItemIndex

        // The target goes.
        let first = try Self.startDrag(pressing: c, in: h)
        defer { first.release() }
        let valid = try Self.validate(first, parent: b, childIndex: onto, in: h)
        #expect(valid == .move)
        // Control: before the archive, the same drop checks out.
        let control = h.controller.confirmedMove(.nest(under: f.b.id), at: (b, onto), carried: [f.c.id])
        #expect(control == SidebarDropMove(ids: [f.c.id], newParentID: f.b.id, before: nil))

        h.state.worktrees[f.repo.id]?.removeAll { $0.id == f.b.id }
        h.controller.flushPendingRebuild()
        #expect(h.shownIDs.contains(b), "The held structure still shows the archived row")
        let acceptedOntoGone = try Self.accept(first, parent: b, childIndex: onto, in: h)
        #expect(!acceptedOntoGone)
        #expect(h.state.pendingWorktreeMoves.isEmpty)

        // A carried row goes.
        let second = try Self.startDrag(pressing: c, in: h)
        defer { second.release() }
        let stillValid = try Self.validate(second, parent: a, childIndex: onto, in: h)
        #expect(stillValid == .move)
        h.state.worktrees[f.repo.id]?.removeAll { $0.id == f.c.id }
        h.controller.flushPendingRebuild()
        let acceptedGoneRow = try Self.accept(second, parent: a, childIndex: onto, in: h)
        #expect(!acceptedGoneRow)
        #expect(h.state.pendingWorktreeMoves.isEmpty)

        // The drag ends: the outline drops both rows, and nothing was sent.
        Self.endSession(in: h)
        #expect(h.shownIDs == h.freshTree().visibleIDs, h.evidence(f.names))
        #expect(!h.shownIDs.contains(b))
        #expect(!h.shownIDs.contains(c))
        #expect(h.controller.fallbackReloadCount == 0)
        #expect(recorder.sent.isEmpty)
    }

    // MARK: The session

    @Test func structureHeldDuringDragAppliedAtEnd() throws {
        let h = OutlineHarness("drag.held")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        let recorder = MoveRecorder()
        recorder.install(on: h.state)
        h.mount()
        let shownBefore = h.shownIDs
        let repo = SidebarNodeID.repoHeader(f.repo.id)
        let a = SidebarNodeID.worktree(f.a.id)
        let c = SidebarNodeID.worktree(f.c.id)

        // `c` dropped just below main.
        let info = try Self.startDrag(pressing: c, in: h)
        defer { info.release() }
        #expect(h.controller.isHoldingStructure)
        let belowMain = try Self.childIndex(of: a, under: repo, in: h)
        let operation = try Self.validate(info, parent: repo, childIndex: belowMain, depth: 0, in: h)
        #expect(operation == .move)
        let accepted = try Self.accept(info, parent: repo, childIndex: belowMain, in: h)
        #expect(accepted)

        // `AppState` moved the row at once; the outline holds its structure
        // through a rebuild while the drag lasts.
        #expect(h.freshTree().visibleIDs != shownBefore)
        h.controller.flushPendingRebuild()
        #expect(h.shownIDs == shownBefore, "Structure moved while the drag held it")

        // The session's end applies it at once: no flush, no main-loop turn.
        Self.endSession(in: h)
        #expect(!h.controller.isHoldingStructure)
        #expect(h.shownIDs == h.freshTree().visibleIDs, h.evidence(f.names))
        let shown = h.shownIDs
        let cRow = try #require(shown.firstIndex(of: c))
        let aRow = try #require(shown.firstIndex(of: a))
        #expect(cRow < aRow)
        #expect(h.controller.fallbackReloadCount == 0)
    }

    /// The hardest replay a drop makes: the target was a leaf, so the
    /// outline has no children loaded under it, and the held structure lands
    /// as a reload of the target plus an `expandItem` the drag's veto would
    /// refuse if it were still up.
    @Test func nestOntoLeafLandsWhenTheDragEnds() async throws {
        let h = OutlineHarness("drag.nestOntoLeaf")
        defer { h.tearDown() }
        let f = DragFixture()
        f.install(in: h)
        let recorder = MoveRecorder()
        recorder.install(on: h.state)
        h.mount()
        let b = SidebarNodeID.worktree(f.b.id)
        let c = SidebarNodeID.worktree(f.c.id)
        let bItem = try #require(h.controller.item(for: b))
        try #require(!h.outline.isExpandable(bItem), "`b` must start as a leaf")
        let onto = SidebarDropPolicy.dropOnItemIndex

        let info = try Self.startDrag(pressing: c, in: h)
        defer { info.release() }
        let operation = try Self.validate(info, parent: b, childIndex: onto, in: h)
        #expect(operation == .move)
        let accepted = try Self.accept(info, parent: b, childIndex: onto, in: h)
        #expect(accepted)
        #expect(!info.animatesToDestination)
        Self.endSession(in: h)

        #expect(h.controller.fallbackReloadCount == 0, h.evidence(f.names))
        #expect(h.shownIDs == h.freshTree().visibleIDs, h.evidence(f.names))
        #expect(h.controller.tree.parent(of: c) == b)
        let shownB = try #require(h.controller.item(for: b))
        #expect(h.outline.isItemExpanded(shownB), "The former leaf must show its new child")
        let shownC = try #require(h.controller.item(for: c))
        let shownParent = (h.outline.parent(forItem: shownC) as? SidebarItem)?.id
        #expect(shownParent == b)

        await recorder.waitForCount(1)
        let sent = recorder.sent.first
        #expect(sent?.worktreeIDs == [f.c.id])
        #expect(sent?.newParentID == f.b.id)
        #expect(sent?.beforeWorktreeID == nil)
    }

    @Test func collapsedSectionDoesNotExpandDuringDrag() throws {
        let h = OutlineHarness("drag.collapsed")
        defer { h.tearDown() }
        let f = DragFixture()
        let shut = Repo(path: "/tmp/acme-prod", displayName: "acme-prod", expanded: false)
        let hidden = SidebarOutlineControllerTests.row("hidden", shut)
        f.install(in: h)
        h.state.repos.append(shut)
        h.state.worktrees[shut.id] = [hidden]
        h.mount()
        let header = SidebarNodeID.repoHeader(shut.id)
        let headerItem = try #require(h.controller.item(for: header))
        try #require(!h.outline.isItemExpanded(headerItem))

        let info = try Self.startDrag(pressing: .worktree(f.c.id), in: h)
        defer { info.release() }

        // The outline's own expansion — the spring-loading a drag hovering
        // over a header would trigger — is refused.
        let refused = h.controller.outlineView(h.outline, shouldExpandItem: headerItem)
        #expect(!refused)
        h.outline.expandItem(headerItem)
        #expect(!h.outline.isItemExpanded(headerItem))
        // So is the controller's own, while the drag lasts.
        h.controller.isApplyingStructure = true
        let duringApply = h.controller.outlineView(h.outline, shouldExpandItem: headerItem)
        h.controller.isApplyingStructure = false
        #expect(!duringApply)

        // The model expands the section mid-drag: held.
        let found = h.state.repos.firstIndex { $0.id == shut.id }
        let index = try #require(found)
        h.state.repos[index].expanded = true
        h.controller.flushPendingRebuild()
        #expect(!h.outline.isItemExpanded(headerItem))
        #expect(!h.shownIDs.contains(.worktree(hidden.id)))

        // The veto lifts before the held expansion replays, so it lands.
        Self.endSession(in: h)
        #expect(h.outline.isItemExpanded(headerItem))
        #expect(h.shownIDs.contains(.worktree(hidden.id)))
        #expect(h.shownIDs == h.freshTree().visibleIDs, h.evidence(f.names))
        #expect(h.controller.fallbackReloadCount == 0)
        h.controller.isApplyingStructure = true
        let afterDrag = h.controller.outlineView(h.outline, shouldExpandItem: headerItem)
        h.controller.isApplyingStructure = false
        #expect(afterDrag)
    }

    // MARK: Playing AppKit's part

    /// A press on `id`'s row: what AppKit asks the outline before a drag.
    @discardableResult
    private static func press(_ id: SidebarNodeID, in h: OutlineHarness) -> Bool {
        let row = h.row(id)
        guard row >= 0 else {
            Issue.record(Comment(rawValue: "\(OutlineHarness.label(id, [:])) has no row to press"))
            return false
        }
        let selected = h.outline.selectedRowIndexes
        let rows = selected.contains(row) ? selected : IndexSet(integer: row)
        let rect = h.outline.rect(ofRow: row)
        return h.outline.canDragRows(with: rows, at: NSPoint(x: rect.midX, y: rect.midY))
    }

    /// A press on `origin` turned into a drag: the press, a writer asked for
    /// every selected row — or the pressed row alone — what they return put
    /// on a fresh pasteboard, and the session begun.
    private static func startDrag(pressing origin: SidebarNodeID, in h: OutlineHarness) throws -> StubDraggingInfo {
        let pressed = press(origin, in: h)
        #expect(pressed, "A press on the row's body must be able to start a drag")
        try #require(h.outline.dragOrigin == origin)
        let row = h.row(origin)
        let selected = h.outline.selectedRowIndexes
        let rows = selected.contains(row) ? selected : IndexSet(integer: row)
        var writers: [any NSPasteboardWriting] = []
        for index in rows {
            guard let item = h.outline.item(atRow: index),
                  let writer = h.controller.outlineView(h.outline, pasteboardWriterForItem: item) else { continue }
            writers.append(writer)
        }
        try #require(!writers.isEmpty, "The pressed row wrote nothing")
        let info = StubDraggingInfo(writing: writers)
        beginSession(in: h)
        return info
    }

    private static func beginSession(in h: OutlineHarness) {
        h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), willBeginAt: .zero, forItems: [])
    }

    private static func endSession(in h: OutlineHarness) {
        h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), endedAt: .zero, operation: .move)
    }

    /// A drag carrying `ids` as the sidebar's writer puts rows on the
    /// pasteboard: one item per row, in the order given.
    private static func dragInfo(carrying ids: [UUID]) -> StubDraggingInfo {
        let writers = ids.map { id -> any NSPasteboardWriting in
            let item = NSPasteboardItem()
            item.setString(id.uuidString, forType: .tbdSidebarWorktrees)
            return item
        }
        return StubDraggingInfo(writing: writers)
    }

    /// `validateDrop` for a proposal under `parent` — onto it when
    /// `childIndex` is `dropOnItemIndex` — with the pointer at visual depth
    /// `depth`.
    private static func validate(_ info: StubDraggingInfo, parent: SidebarNodeID, childIndex: Int, depth: Int = 0,
                                 in h: OutlineHarness) throws -> NSDragOperation {
        let item = try #require(h.controller.item(for: parent))
        let x = h.controller.dropDepthInset + CGFloat(depth) * SidebarNativeMetrics.indentation
        info.draggingLocation = h.outline.convert(NSPoint(x: x, y: 1), to: nil)
        return h.controller.outlineView(h.outline, validateDrop: info, proposedItem: item, proposedChildIndex: childIndex)
    }

    /// `acceptDrop` at the position `validateDrop` last showed.
    private static func accept(_ info: StubDraggingInfo, parent: SidebarNodeID, childIndex: Int,
                               in h: OutlineHarness) throws -> Bool {
        let item = try #require(h.controller.item(for: parent))
        return h.controller.outlineView(h.outline, acceptDrop: info, item: item, childIndex: childIndex)
    }

    // MARK: Reading the outline

    /// The ID a row's pasteboard writer carries, or nil when it writes none.
    private static func writtenID(for id: SidebarNodeID, in h: OutlineHarness) -> UUID? {
        guard let item = h.controller.item(for: id),
              let writer = h.controller.outlineView(h.outline, pasteboardWriterForItem: item) as? NSPasteboardItem,
              let string = writer.string(forType: .tbdSidebarWorktrees) else { return nil }
        return UUID(uuidString: string)
    }

    /// The selected rows, top to bottom.
    private static func selectedIDs(in h: OutlineHarness) -> [SidebarNodeID] {
        h.outline.selectedRowIndexes.compactMap { (h.outline.item(atRow: $0) as? SidebarItem)?.id }
    }

    private static func childIndex(of id: SidebarNodeID, under parent: SidebarNodeID,
                                   in h: OutlineHarness) throws -> Int {
        let found = h.controller.tree.children(of: parent).firstIndex { $0.id == id }
        return try #require(found)
    }

    private static func cell(_ id: SidebarNodeID, in h: OutlineHarness) -> NSView? {
        let index = h.row(id)
        guard index >= 0 else { return nil }
        return h.outline.view(atColumn: 0, row: index, makeIfNecessary: true)
    }

    /// The centre of the row showing `id`, in window coordinates.
    private static func windowCenter(of id: SidebarNodeID, in h: OutlineHarness) -> NSPoint? {
        let index = h.row(id)
        guard index >= 0 else { return nil }
        let rect = h.outline.rect(ofRow: index)
        return h.outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// Outline coordinates `x`, `y`, in the indicator's coordinates.
    private static func point(x: CGFloat, y: CGFloat, in h: OutlineHarness) -> NSPoint {
        h.controller.dropIndicator.convert(NSPoint(x: x, y: y), from: h.outline)
    }

    /// Where the shown insertion line starts: its ring's centre.
    private static func lineStart(in h: OutlineHarness) -> NSPoint? {
        h.controller.dropIndicator.line.map { NSPoint(x: $0.x, y: $0.y) }
    }
}

// MARK: - Fixtures

/// One repo: main, then `a` with its child `a1`, `b` and `c`, top to bottom.
@MainActor
private struct DragFixture {
    let repo = Repo(path: "/tmp/acme", displayName: "acme")
    let main: Worktree
    let a: Worktree
    let a1: Worktree
    let b: Worktree
    let c: Worktree

    init() {
        main = SidebarOutlineControllerTests.row("main", repo, status: .main)
        a = SidebarOutlineControllerTests.row("a", repo, order: 0)
        a1 = SidebarOutlineControllerTests.row("a1", repo, parent: a.id, order: 0)
        b = SidebarOutlineControllerTests.row("b", repo, order: 1)
        c = SidebarOutlineControllerTests.row("c", repo, order: 2)
    }

    func install(in h: OutlineHarness) {
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [main, a, a1, b, c]]
    }

    var names: [UUID: String] {
        [main.id: "main", a.id: "a", a1.id: "a1", b.id: "b", c.id: "c"]
    }
}

/// Stands in for `worktree.moveMany`: records each request and answers at
/// once.
@MainActor
private final class MoveRecorder {
    private(set) var sent: [WorktreeMoveManyParams] = []

    func install(on state: AppState) {
        state.worktreeMoveManySender = { [self] params in sent.append(params) }
    }

    /// Waits until `count` requests have been sent: `moveWorktrees` sends
    /// from a task of its own.
    func waitForCount(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { self.sent.count >= count }
        }
        guard outcome == .timedOut else { return }
        Issue.record(
            BoundedWaitTimeout(
                what: "\(count) worktree.moveMany request(s)", observed: "\(sent.count) sent",
                deadline: TestDeadlines.saturatedPass),
            sourceLocation: sourceLocation)
    }
}

/// An `NSDraggingInfo` over a uniquely named pasteboard, for driving
/// `validateDrop` and `acceptDrop` without a drag session. Call `release()`
/// once done with it.
@MainActor
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
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
