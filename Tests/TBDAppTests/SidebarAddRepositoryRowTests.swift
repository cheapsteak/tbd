import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// The outline is mounted offscreen through `OutlineHarness` and driven
// through `flushPendingRebuild()`; the pointer through the hover tracker's own
// entry points, as in `SidebarInteractionTests`. No test opens the folder
// picker or pops a menu up: the controller's `addRepositoryForTesting` stands
// in for the picker, and the chevron's menu is read from the builder its
// click pops up.

/// The Add Repository row at the end of the native sidebar: it is the
/// outline's last row, its buttons run the folder picker and open its menu,
/// the clone request reaches the sidebar's sheet presenter, and the row itself
/// is no sidebar item — it takes no selection by mouse or keyboard, has no
/// context menu, is neither a drag source nor a drop target, and draws no
/// highlight or guide line.
@MainActor
@Suite("Sidebar Add Repository row")
struct SidebarAddRepositoryRowTests {
    // MARK: Fixture

    /// A repo with its main row and one worktree, mounted.
    struct Fixture {
        let h: OutlineHarness
        let repo: Repo
        let work: Worktree
    }

    static func mount(_ label: String) -> Fixture {
        let h = OutlineHarness("addRepository.\(label)")
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = SidebarOutlineControllerTests.row("main", repo, status: .main)
        let work = SidebarOutlineControllerTests.row("work", repo)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [main, work]]
        h.mount()
        return Fixture(h: h, repo: repo, work: work)
    }

    /// The row's cell, laid out.
    static func cell(in h: OutlineHarness) throws -> AddRepositoryCell {
        let index = h.row(.addRepository)
        try #require(index >= 0, "The outline shows no Add Repository row")
        let view = h.outline.view(atColumn: 0, row: index, makeIfNecessary: true)
        let cell = try #require(view as? AddRepositoryCell, "The Add Repository row has the wrong cell")
        h.host?.layout()
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// The centre of `view`, in window coordinates.
    static func windowCenter(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    // MARK: Place

    @Test func isTheOutlinesLastRow() throws {
        let f = Self.mount("last")
        defer { f.h.tearDown() }
        #expect(f.h.shownIDs.last == .addRepository, f.h.evidence())
        let count = f.h.shownIDs.filter { $0 == .addRepository }.count
        #expect(count == 1, f.h.evidence())

        // With no repos at all it still shows.
        let empty = OutlineHarness("addRepository.empty")
        defer { empty.tearDown() }
        empty.defaults.set(false, forKey: AppState.showScratchSectionKey)
        empty.mount()
        #expect(empty.shownIDs == [.addRepository], empty.evidence())
    }

    // MARK: Not a sidebar item

    @Test func takesNoSelectionMenuOrClick() throws {
        let f = Self.mount("inert")
        defer { f.h.tearDown() }
        let h = f.h
        h.state.selectedWorktreeIDs = [f.work.id]
        h.controller.flushPendingRebuild()
        let item = try #require(h.controller.item(for: .addRepository))
        let rowItem = try #require(h.controller.item(for: .worktree(f.work.id)))
        let refusesSelection = !h.controller.outlineView(h.outline, shouldSelectItem: item)
        #expect(refusesSelection, "The Add Repository row takes the selection")
        // Positive control: the same question about a worktree row says yes.
        #expect(h.controller.outlineView(h.outline, shouldSelectItem: rowItem))

        let index = h.row(.addRepository)
        #expect(h.controller.contextMenu(forRow: index) == nil, "The Add Repository row has a context menu")
        #expect(h.outline.contextMenuProvider?(index) == nil)

        // A click beside its buttons changes nothing.
        var pickerRuns = 0
        h.controller.addRepositoryForTesting = { pickerRuns += 1 }
        let selectionBefore = h.state.selectedWorktreeIDs
        h.controller.handleClick(row: index)
        h.controller.flushPendingRebuild()
        #expect(pickerRuns == 0)
        #expect(h.controller.sheets.sheet == nil)
        #expect(h.state.selectedWorktreeIDs == selectionBefore)
        #expect(h.state.selectedRepoID == nil)
        #expect(!h.state.selectedScratchSection)
    }

    /// ↓ from the last worktree row would reach the Add Repository row; the
    /// outline refuses it, so the selection stays where it was.
    @Test func arrowKeysPassItBy() throws {
        let f = Self.mount("arrowKey")
        defer { f.h.tearDown() }
        let h = f.h
        h.state.selectedWorktreeIDs = [f.work.id]
        h.controller.flushPendingRebuild()
        let workRow = h.row(.worktree(f.work.id))
        let addRow = h.row(.addRepository)
        let adjacent = workRow >= 0 && addRow == workRow + 1
        try #require(adjacent, "The worktree row must sit just above the Add Repository row")
        try #require(h.outline.selectedRowIndexes == IndexSet(integer: workRow), h.evidence())

        let window = try #require(h.host?.window)
        window.makeFirstResponder(h.outline)
        let down = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        h.outline.keyDown(with: down)

        #expect(!h.outline.selectedRowIndexes.contains(addRow), h.evidence())
        #expect(h.outline.selectedRowIndexes == IndexSet(integer: workRow), h.evidence())
        #expect(h.state.selectedWorktreeIDs == [f.work.id], h.evidence())
    }

    /// It carries nothing when dragged, and no proposal on or below it takes
    /// rows: the gap below it reads as the gap above it, the end of the last
    /// section, as the gap below the last section always has.
    @Test func isNeitherADragSourceNorADropTarget() throws {
        let f = Self.mount("drag")
        defer { f.h.tearDown() }
        let h = f.h
        let item = try #require(h.controller.item(for: .addRepository))
        h.outline.dragOrigin = .addRepository
        let writer = h.controller.outlineView(h.outline, pasteboardWriterForItem: item)
        #expect(writer == nil, "The Add Repository row writes a drag payload")
        h.outline.dragOrigin = nil

        // A press on either of its buttons never starts a drag.
        let cell = try Self.cell(in: h)
        for button in [cell.addButton, cell.menuButton] as [NSButton] {
            let point = h.outline.convert(Self.windowCenter(of: button), from: nil)
            #expect(h.outline.isOnButton(point), "A press on \(button) could start a drag")
        }

        let index = h.controller.dropIndex
        let carried = [f.work.id]
        let onto = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: .addRepository, childIndex: SidebarDropPolicy.dropOnItemIndex,
            pointerDepth: 0, index: index)
        #expect(onto.decision == .reject)
        let into = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: .addRepository, childIndex: 0, pointerDepth: 0, index: index)
        #expect(into.decision == .reject)

        let rootCount = h.controller.tree.roots.count
        try #require(h.controller.tree.roots.last?.id == .addRepository)
        let above = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: nil, childIndex: rootCount - 1, pointerDepth: 0, index: index)
        let below = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: nil, childIndex: rootCount, pointerDepth: 0, index: index)
        #expect(above.decision == .place(parent: nil, before: nil), "The gap above the row is the end of acme")
        #expect(below.decision == above.decision)
        let aboveParent = above.retarget?.parent ?? nil
        let belowParent = below.retarget?.parent ?? nil
        let aboveIndex = above.retarget?.childIndex
        let belowIndex = below.retarget?.childIndex
        #expect(aboveParent == .repoHeader(f.repo.id), "The gap above the row is not shown at the end of acme")
        #expect(belowParent == aboveParent)
        #expect(belowIndex == aboveIndex)
    }

    /// The row draws no highlight, selection or guide line, hovered or not;
    /// the button under the pointer draws its own wash.
    @Test func hoverWashesOnlyTheButtonUnderThePointer() throws {
        let f = Self.mount("hover")
        defer { f.h.tearDown() }
        let h = f.h
        let tracker = try #require(h.controller.hoverTracker)
        let cell = try Self.cell(in: h)

        tracker.pointerMoved(toWindowPoint: Self.windowCenter(of: cell.addButton))
        #expect(h.controller.hoverState.row == .addRepository)
        #expect(h.controller.hoverState.part == .addRepository)
        #expect(cell.addButton.showsHoverWash)
        #expect(!cell.menuButton.showsHoverWash)
        let rowView = try #require(h.rowView(.addRepository, make: true) as? SidebarRowView)
        let configuration = rowView.configuration
        #expect(!configuration.isHovered, "The Add Repository row draws the row hover highlight")
        #expect(!configuration.isSelectedByModel)
        #expect(configuration.guides.isEmpty)
        #expect(!configuration.drawsStub)
        #expect(rowView.highlightAlpha == nil, "The Add Repository row draws a highlight")

        tracker.pointerMoved(toWindowPoint: Self.windowCenter(of: cell.menuButton))
        #expect(h.controller.hoverState.part == .addRepositoryMenu)
        #expect(!cell.addButton.showsHoverWash)
        #expect(cell.menuButton.showsHoverWash)

        tracker.pointerExited()
        #expect(!cell.addButton.showsHoverWash)
        #expect(!cell.menuButton.showsHoverWash)
    }

    // MARK: Its actions

    @Test func buttonsRunThePickerAndOpenTheMenu() throws {
        let f = Self.mount("buttons")
        defer { f.h.tearDown() }
        let h = f.h
        let cell = try Self.cell(in: h)
        #expect(cell.addButton.target === h.controller)
        #expect(cell.addButton.action == #selector(SidebarOutlineController.addRepositoryClicked(_:)))
        #expect(cell.menuButton.target === h.controller)
        #expect(cell.menuButton.action == #selector(SidebarOutlineController.addRepositoryMenuClicked(_:)))

        var pickerRuns = 0
        h.controller.addRepositoryForTesting = { pickerRuns += 1 }
        cell.addButton.performClick(nil)
        #expect(pickerRuns == 1, "A click on the + and label did not run the folder picker")

        // A click anywhere in the + or the label is the button's.
        // `hitTest(_:)` takes a point in the superview's coordinates.
        let rowView = try #require(cell.superview)
        for view in [cell.plusView, cell.titleField] as [NSView] {
            let point = rowView.convert(Self.windowCenter(of: view), from: nil)
            let hit = cell.hitTest(point)
            #expect(hit === cell.addButton, "A click on \(view) lands on \(String(describing: hit))")
        }
    }

    @Test func chevronMenuOffersLocalFolderAndClone() throws {
        let f = Self.mount("menu")
        defer { f.h.tearDown() }
        let h = f.h
        let menu = h.controller.addRepositoryMenu()
        let titles = menu.items.map(\.title)
        #expect(titles == ["Local Folder…", "Clone from URL…"])
        let targets = menu.items.map { $0.target as AnyObject? }
        let targetsController = targets.allSatisfy { $0 === h.controller }
        #expect(targetsController)
        let enabled = menu.items.allSatisfy(\.isEnabled)
        #expect(enabled)

        var pickerRuns = 0
        h.controller.addRepositoryForTesting = { pickerRuns += 1 }
        menu.performActionForItem(at: 0)
        #expect(pickerRuns == 1, "Local Folder… did not run the folder picker")
        #expect(h.controller.sheets.sheet == nil)

        menu.performActionForItem(at: 1)
        #expect(h.state.cloneRepositoryRequested, "Clone from URL… made no clone request")
        h.controller.flushPendingRebuild()
        #expect(h.controller.sheets.sheet?.id == NativeSidebarSheet.cloneRepository.id)
        #expect(!h.state.cloneRepositoryRequested, "The rebuild left the request standing")
        #expect(pickerRuns == 1)
    }

    /// The TBD menu's Clone Repository… calls `requestCloneRepository()`:
    /// the outline takes the request on its next rebuild and asks its
    /// presenter for the clone sheet. A request while another sheet is up is
    /// dropped, as the presenter drops any second sheet, and does not come
    /// back once that sheet closes.
    @Test func cloneRequestReachesThePresenter() throws {
        let f = Self.mount("cloneRequest")
        defer { f.h.tearDown() }
        let h = f.h
        let buildsBefore = h.controller.buildCount
        h.state.requestCloneRepository()
        h.controller.flushPendingRebuild()
        let rebuilt = h.controller.buildCount > buildsBefore
        #expect(rebuilt, "The request never reached the outline's observation")
        #expect(h.controller.sheets.sheet?.id == NativeSidebarSheet.cloneRepository.id)
        #expect(!h.state.cloneRepositoryRequested)

        // Taking the request scheduled no rebuild of its own.
        let settled = h.controller.buildCount
        h.controller.flushPendingRebuild()
        #expect(h.controller.buildCount == settled)

        h.controller.sheets.binding.wrappedValue = nil
        h.controller.present(.scratchInstructions)
        h.state.requestCloneRepository()
        h.controller.flushPendingRebuild()
        #expect(h.controller.sheets.sheet?.id == NativeSidebarSheet.scratchInstructions.id)
        #expect(!h.state.cloneRepositoryRequested, "A dropped request was left standing")

        h.controller.sheets.binding.wrappedValue = nil
        let beforeLater = h.controller.buildCount
        h.state.selectedScratchSection.toggle()
        h.controller.flushPendingRebuild()
        let rebuiltLater = h.controller.buildCount > beforeLater
        try #require(rebuiltLater, "The later write never rebuilt, so the check below would be vacuous")
        #expect(h.controller.sheets.sheet == nil, "A dropped request came back after the sheet closed")
    }

    // MARK: Accessibility

    @Test func readsAsOneButtonAndAMenuButton() throws {
        let f = Self.mount("accessibility")
        defer { f.h.tearDown() }
        let cell = try Self.cell(in: f.h)
        #expect(cell.addButton.accessibilityLabel() == "Add Repository")
        #expect(cell.menuButton.accessibilityLabel() == "More ways to add a repository")
        #expect(!cell.plusView.isAccessibilityElement())
        #expect(!cell.titleField.isAccessibilityElement())
        #expect(cell.titleField.stringValue == AddRepositoryCell.title)
    }
}

/// The one folder picker every Add Repository entry runs, with its panel and
/// its effects handed in so nothing modal opens.
@MainActor
@Suite("Add repository panel")
struct AddRepositoryPanelTests {
    /// Collects what the add step was asked for.
    @MainActor
    final class AddLog {
        var paths: [String] = []
    }

    @Test func panelChoosesOneExistingDirectory() {
        let panel = AddRepositoryPanel.make()
        #expect(panel.title == "Select a Git Repository")
        #expect(!panel.canChooseFiles)
        #expect(panel.canChooseDirectories)
        #expect(!panel.allowsMultipleSelection)
        #expect(!panel.canCreateDirectories)
    }

    @Test func addsTheChosenFolderAndNothingWhenCancelled() async {
        let log = AddLog()
        let cancelled = AddRepositoryPanel.run(choose: { _ in nil }, add: { path in log.paths.append(path) })
        #expect(cancelled == nil)
        #expect(log.paths.isEmpty)

        var shown: NSOpenPanel?
        let chosen = AddRepositoryPanel.run(
            choose: { panel in
                shown = panel
                return URL(fileURLWithPath: "/tmp/acme")
            },
            add: { path in log.paths.append(path) })
        _ = await chosen?.value
        #expect(log.paths == ["/tmp/acme"])
        #expect(shown?.canChooseDirectories == true, "The chooser was handed some other panel")
    }
}
