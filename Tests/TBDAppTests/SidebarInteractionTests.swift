import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// The native sidebar's interactions: context menus built from the SwiftUI
/// path's models, hover recomputed under a scrolling pointer, the repo
/// header's 80 ms debounce on an injected clock, the chevron's dimming,
/// rename-on-create holding structure, and the hover-only controls offered to
/// VoiceOver. Spec: docs/specs/2026-10-31-native-sidebar-design.md,
/// "Interaction".
///
/// The pointer is driven through the hover tracker's own entry points with
/// window coordinates, as its tracking area would; nothing moves the real
/// mouse. Tier 1: the one timed behaviour, the debounce, runs on
/// `EventDrivenTestClock`.
@MainActor
@Suite("Native sidebar interactions", .clockDriven)
struct SidebarInteractionTests {
    // MARK: Context menus

    @Test func worktreeMenuMatchesRowActionMenu() throws {
        let h = OutlineHarness("interaction.worktreeMenu")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = SidebarOutlineControllerTests.row("parent", repo, order: 0)
        let child = SidebarOutlineControllerTests.row("child", repo, parent: parent.id)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [parent, child]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.mount()

        let node = try #require(h.controller.tree.node(.worktree(parent.id)))
        let menu = try #require(h.controller.menus.menu(for: node))
        let model = RowActionMenuActions(appState: h.state, worktree: parent, onRename: {}).items()
        let expected = model.map { Self.title(of: $0) } + [Self.separator, "New Remote Session…"]
        let shown = Self.titles(of: menu)
        #expect(shown == expected)
        // The fixture reaches the sections the comparison is about.
        #expect(expected.contains(RowActionMenu.archiveHasChildrenLabel))
        #expect(expected.contains("Create Nested Worktree"))

        // Enabled state follows the model: the parent of an active row cannot
        // be archived.
        let archiveItem = menu.items.first { $0.title == RowActionMenu.archiveHasChildrenLabel }
        let archive = try #require(archiveItem)
        #expect(!archive.isEnabled)
        let copyPathItem = menu.items.first { $0.title == "Copy Path" }
        let copyPath = try #require(copyPathItem)
        #expect(copyPath.isEnabled)

        // Rename… runs through `RowActionMenuActions.run` into the inline editor.
        let renamePosition = menu.items.firstIndex { $0.title == "Rename..." }
        let renameIndex = try #require(renamePosition)
        menu.performActionForItem(at: renameIndex)
        #expect(h.controller.renamingID == .worktree(parent.id))
        #expect(h.controller.isHoldingStructure)
        h.controller.finishRename(commitPending: false)
        #expect(!h.controller.isHoldingStructure)

        // Rows with no menu in the SwiftUI sidebar have none here either.
        let provider = try #require(h.controller.tree.node(.providerHeader("acme")))
        #expect(h.controller.menus.menu(for: provider) == nil)
    }

    @Test func repoHeaderMenuHasSixItemsAndCollapseExpand() async throws {
        let h = OutlineHarness("interaction.repoMenu")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [SidebarOutlineControllerTests.row("work", repo)]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider(), Self.cloudProvider()]
        h.state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, claudeCloudEnabled: true)
        h.mount()

        let header = SidebarNodeID.repoHeader(repo.id)
        let node = try #require(h.controller.tree.node(header))
        let menu = try #require(h.controller.menus.menu(for: node))
        let shown = Self.titles(of: menu)
        #expect(shown == [
            "Collapse", "Rename...", "Hide", "New Cloud Session…", "New Remote Session…",
            Self.separator, "Remove from List...",
        ])
        let actionTitles = shown.filter { $0 != Self.separator }
        #expect(actionTitles.count == 6)

        // Collapse writes `Repo.expanded`, and the rebuilt menu offers Expand.
        let headerItem = try #require(h.controller.item(for: header))
        try #require(h.outline.isItemExpanded(headerItem))
        menu.performActionForItem(at: 0)
        let state = h.state
        let persisted = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { state.repos.first?.expanded == false }
        }
        #expect(persisted == .satisfied, "Collapse never wrote Repo.expanded")
        h.controller.flushPendingRebuild()
        #expect(!h.outline.isItemExpanded(headerItem))
        let collapsed = try #require(h.controller.tree.node(header))
        let reopened = try #require(h.controller.menus.menu(for: collapsed))
        #expect(reopened.items.first?.title == "Expand")

        // The Scratch header's two items; Collapse writes its key.
        let scratch = try #require(h.controller.tree.node(.scratchHeader))
        let scratchMenu = try #require(h.controller.menus.menu(for: scratch))
        #expect(Self.titles(of: scratchMenu) == ["Collapse", "Edit Scratch Instructions…"])
        scratchMenu.performActionForItem(at: 0)
        #expect(h.defaults.object(forKey: AppState.scratchSectionExpandedKey) as? Bool == false)
        h.controller.flushPendingRebuild()
        let scratchCollapsed = try #require(h.controller.tree.node(.scratchHeader))
        let scratchReopened = try #require(h.controller.menus.menu(for: scratchCollapsed))
        #expect(scratchReopened.items.first?.title == "Expand")
    }

    // MARK: Hover

    @Test func hoverRecomputedAfterScroll() throws {
        let h = OutlineHarness("interaction.hoverScroll")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let rows = (0..<40).map { SidebarOutlineControllerTests.row("row \($0)", repo, order: $0 + 1) }
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: rows]
        h.mount(size: NSSize(width: 320, height: 200))
        let tracker = try #require(h.controller.hoverTracker)

        let first = SidebarNodeID.worktree(rows[2].id)
        let point = try #require(Self.windowPoint(of: first, in: h))
        tracker.pointerMoved(toWindowPoint: point)
        #expect(h.controller.hoverState.row == first)
        let firstCell = try #require(Self.cell(first, in: h) as? WorktreeRowCell)
        #expect(firstCell.isHovered)

        // Five rows scroll under the still pointer: no tracking-area event
        // arrives, yet the row under it is the hovered one.
        h.clip.scroll(to: NSPoint(x: 0, y: h.clip.bounds.minY + 5 * WorktreeRowView.rowHeight))
        h.controller.scrollView.reflectScrolledClipView(h.clip)
        let scrolledTo = try #require(Self.rowID(at: point, in: h))
        #expect(scrolledTo != first)
        #expect(h.controller.hoverState.row == scrolledTo)
        _ = h.rowView(scrolledTo, make: true)
        let scrolledCell = try #require(Self.cell(scrolledTo, in: h) as? WorktreeRowCell)
        #expect(scrolledCell.isHovered)
        let previous = Self.cell(first, in: h) as? WorktreeRowCell
        #expect(previous?.isHovered != true, "The row that scrolled away still shows hover")

        // An apply that slides another row under the pointer moves the hover
        // with it.
        guard case .worktree(let removedID) = scrolledTo else {
            Issue.record("The row under the pointer is not a worktree row")
            return
        }
        h.state.worktrees[repo.id]?.removeAll { $0.id == removedID }
        h.controller.flushPendingRebuild()
        let afterApply = try #require(Self.rowID(at: point, in: h))
        #expect(afterApply != scrolledTo)
        #expect(h.controller.hoverState.row == afterApply)
    }

    @Test func headerHoverDebouncesEightyMilliseconds() async throws {
        let h = OutlineHarness("interaction.debounce")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let row = SidebarOutlineControllerTests.row("work", repo)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [row]]
        h.mount()

        let clock = EventDrivenTestClock()
        let header = SidebarNodeID.repoHeader(repo.id)
        let hidden = FireRecorder<Bool>()
        let tracker = SidebarHoverTracker(
            outline: h.outline,
            onChange: { state in
                if !state.revealedSections.contains(header) { hidden.record(true) }
            },
            clock: clock)

        // A row of the section reveals its header at once.
        let point = try #require(Self.windowPoint(of: .worktree(row.id), in: h))
        tracker.pointerMoved(toWindowPoint: point)
        #expect(tracker.state.row == .worktree(row.id))
        #expect(tracker.state.revealedSections.contains(header))

        // Leaving keeps it revealed through the debounce…
        tracker.pointerExited()
        #expect(tracker.state.row == nil)
        #expect(tracker.state.revealedSections.contains(header))
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(79), timeout: TestDeadlines.saturatedPass)
        await settle()
        #expect(hidden.values.isEmpty, "The header hid before 80 ms had passed")
        #expect(tracker.state.revealedSections.contains(header))

        // …and hides it on the 80th millisecond.
        await clock.advance(by: .milliseconds(1))
        let fired = await hidden.next(timeout: TestDeadlines.saturatedPass)
        #expect(fired == true)
        #expect(!tracker.state.revealedSections.contains(header))
        #expect(hidden.values.count == 1)
    }

    @Test func chevronHoverDimsSectionRows() throws {
        let h = OutlineHarness("interaction.chevronDim")
        defer { h.tearDown() }
        // Before the title the chevron always shows, so it can be hovered
        // without first revealing the section.
        h.defaults.set(true, forKey: AppState.chevronBeforeProjectNameKey)
        let acme = Repo(path: "/tmp/acme", displayName: "acme")
        let other = Repo(path: "/tmp/acme-other", displayName: "other")
        let parent = SidebarOutlineControllerTests.row("parent", acme, order: 0)
        let child = SidebarOutlineControllerTests.row("child", acme, parent: parent.id)
        let elsewhere = SidebarOutlineControllerTests.row("elsewhere", other)
        h.state.repos = [acme, other]
        h.state.worktrees = [acme.id: [parent, child], other.id: [elsewhere]]
        h.mount()
        let tracker = try #require(h.controller.hoverTracker)

        let header = SidebarNodeID.repoHeader(acme.id)
        let headerCell = try #require(Self.cell(header, in: h) as? SectionHeaderCell)
        try #require(!headerCell.chevronButton.isHidden)
        let chevron = headerCell.chevronButton.frame
        tracker.pointerMoved(toWindowPoint: headerCell.convert(NSPoint(x: chevron.midX, y: chevron.midY), to: nil))
        #expect(h.controller.hoverState.part == .chevron)
        #expect(h.controller.hoverState.dimmedSection == header)

        for id in [parent.id, child.id] {
            let alpha = try #require(h.rowView(.worktree(id), make: true)).alphaValue
            #expect(abs(alpha - 0.7) < 0.001, "A row of the hovered chevron's section is not dimmed")
        }
        let otherAlpha = try #require(h.rowView(.worktree(elsewhere.id), make: true)).alphaValue
        #expect(otherAlpha == 1, "Another section's row dimmed")
        let headerAlpha = try #require(h.rowView(header, make: true)).alphaValue
        #expect(headerAlpha == 1, "The header itself dimmed")

        // Onto the title, off the chevron: the rows come back.
        let title = headerCell.titleField.frame
        tracker.pointerMoved(toWindowPoint: headerCell.convert(NSPoint(x: title.midX, y: title.midY), to: nil))
        #expect(h.controller.hoverState.row == header)
        #expect(h.controller.hoverState.part == .none)
        for id in [parent.id, child.id] {
            let alpha = try #require(h.rowView(.worktree(id), make: false)).alphaValue
            #expect(alpha == 1)
        }
    }

    // MARK: Rename

    @Test func editingWorktreeIDShowsFieldAndHoldsStructure() throws {
        let h = OutlineHarness("interaction.rename")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = SidebarOutlineControllerTests.row("acme", repo, status: .main)
        let row = SidebarOutlineControllerTests.row("work", repo, order: 0)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [main, row]]
        h.mount()
        let id = SidebarNodeID.worktree(row.id)

        h.state.editingWorktreeID = row.id
        h.controller.flushPendingRebuild()
        #expect(h.state.editingWorktreeID == nil, "The request is consumed, as the SwiftUI row consumes it")
        #expect(h.controller.renamingID == id)
        #expect(h.controller.isHoldingStructure)
        let cell = try #require(Self.cell(id, in: h) as? WorktreeRowCell)
        #expect(cell.isRenaming)
        #expect(cell.nameField.isHidden)
        let editor = try #require(cell.renameEditor)
        #expect(editor.view.superview === cell)
        #expect(editor.session.originalText == "work")
        #expect(editor.session.isEditing)

        // Mid-edit, structure waits; content lands, and the label stays
        // hidden under the editor.
        let added = SidebarOutlineControllerTests.row("added", repo, order: 1)
        h.state.worktrees[repo.id]?.append(added)
        let found = h.state.worktrees[repo.id]?.firstIndex { $0.id == row.id }
        let index = try #require(found)
        h.state.worktrees[repo.id]?[index].displayName = "renamed elsewhere"
        h.controller.flushPendingRebuild()
        #expect(!h.shownIDs.contains(.worktree(added.id)), "The insert must wait for the rename")
        #expect(SidebarOutlineControllerTests.worktreeModel(h.controller.tree, row.id)?.name == "renamed elsewhere")
        #expect(cell.renameEditor === editor)
        #expect(cell.nameField.isHidden)

        // Ending the edit puts the label back and lands the held structure.
        h.controller.finishRename(commitPending: false)
        #expect(!h.controller.isHoldingStructure)
        #expect(h.controller.renamingID == nil)
        #expect(!cell.isRenaming)
        #expect(!cell.nameField.isHidden)
        #expect(editor.view.superview == nil)
        #expect(h.shownIDs.contains(.worktree(added.id)))

        // The main row's request is consumed but never edited, as
        // `WorktreeRowView.startRename` refuses it.
        h.state.editingWorktreeID = main.id
        h.controller.flushPendingRebuild()
        #expect(h.state.editingWorktreeID == nil)
        #expect(h.controller.renamingID == nil)
        #expect(!h.controller.isHoldingStructure)
    }

    // MARK: Accessibility

    @Test func pinAndNestedPlusOfferedAsAccessibilityActions() throws {
        let h = OutlineHarness("interaction.accessibility")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = SidebarOutlineControllerTests.row("acme", repo, status: .main)
        let plain = SidebarOutlineControllerTests.row("plain", repo, order: 0)
        var pinned = SidebarOutlineControllerTests.row("pinned", repo, order: 1)
        pinned.pinnedAt = Date()
        let pad = Worktree(repoID: nil, name: "pad", displayName: "pad", branch: "", path: "/tmp/acme-pad",
                           tmuxServer: "acme")
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [main, plain, pinned]]
        h.state.scratchWorktrees = [pad]
        h.mount()

        let plainCell = try #require(Self.cell(.worktree(plain.id), in: h) as? WorktreeRowCell)
        let plainNames = Self.actionNames(plainCell)
        #expect(plainNames == [WorktreeRowCell.pinActionName, WorktreeRowCell.nestedWorktreeActionName])
        let pinnedCell = try #require(Self.cell(.worktree(pinned.id), in: h) as? WorktreeRowCell)
        let pinnedNames = Self.actionNames(pinnedCell)
        #expect(pinnedNames == [WorktreeRowCell.unpinActionName, WorktreeRowCell.nestedWorktreeActionName])
        let mainCell = try #require(Self.cell(.worktree(main.id), in: h) as? WorktreeRowCell)
        let mainNames = Self.actionNames(mainCell)
        #expect(mainNames.isEmpty, "The main row offers neither control")
        let padCell = try #require(Self.cell(.worktree(pad.id), in: h) as? WorktreeRowCell)
        let padNames = Self.actionNames(padCell)
        #expect(padNames == [WorktreeRowCell.pinActionName], "Nesting is repo-only")

        // The controls are hidden without a pointer; their actions are not.
        #expect(plainCell.plusButton.isHidden)
        #expect(plainCell.pinButton.isHidden)
        #expect(!pinnedCell.pinButton.isHidden, "A pinned row shows its pin without hover")

        // The nested action does what a plain click on the `+` does: a
        // creating child under the row. The create RPC is stubbed out.
        h.state.worktreeCreator = { @MainActor _ in throw CancellationError() }
        let actions = plainCell.accessibilityCustomActions() ?? []
        let nestedAction = actions.first { $0.name == WorktreeRowCell.nestedWorktreeActionName }
        let nested = try #require(nestedAction)
        let handler = try #require(nested.handler)
        let handled = handler()
        #expect(handled)
        let placeholders = h.state.worktrees[repo.id]?.filter {
            $0.status == .creating && $0.parentWorktreeID == plain.id
        } ?? []
        #expect(placeholders.count == 1)
    }

    // MARK: Helpers

    static let separator = "—"

    static func title(of item: RowActionMenu.Item) -> String {
        switch item {
        case .action(let action): action.title
        case .divider: separator
        case .caption(let text): text
        }
    }

    static func titles(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? separator : $0.title }
    }

    static func actionNames(_ cell: NSView) -> [String] {
        (cell.accessibilityCustomActions() ?? []).map { $0.name }
    }

    static func cloudProvider() -> RemoteProviderStatus {
        RemoteProviderStatus(config: .init(name: ClaudeCloudProvider.name, exec: "/bin/false"), describe: nil,
                             health: .ok, errorMessage: nil, remediationLabel: nil,
                             remediationCommand: nil, lastSuccessfulSnapshotAt: Date())
    }

    /// The row's cell, made if the outline has not made it yet.
    static func cell(_ id: SidebarNodeID, in h: OutlineHarness) -> NSView? {
        let index = h.row(id)
        guard index >= 0 else { return nil }
        return h.outline.view(atColumn: 0, row: index, makeIfNecessary: true)
    }

    /// The centre of the row showing `id`, in window coordinates.
    static func windowPoint(of id: SidebarNodeID, in h: OutlineHarness) -> NSPoint? {
        let index = h.row(id)
        guard index >= 0 else { return nil }
        let rect = h.outline.rect(ofRow: index)
        return h.outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// The row under a window point.
    static func rowID(at windowPoint: NSPoint, in h: OutlineHarness) -> SidebarNodeID? {
        let index = h.outline.row(at: h.outline.convert(windowPoint, from: nil))
        guard index >= 0 else { return nil }
        return (h.outline.item(atRow: index) as? SidebarItem)?.id
    }
}
