import AppKit
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

/// `MainToolbarController`, the AppKit main window's toolbar, mounted on a
/// real offscreen window over a `MainSplitViewController`. Spec:
/// docs/specs/2026-11-01-appkit-window-chrome-design.md, "The toolbar" and
/// "Width".
///
/// Every toolbar has an identifier of its own, so toolbars from tests that
/// interleave at each wait never mirror each other's item changes.
///
/// `apply` defers through `DispatchQueue.main.async` and toolbar layout runs
/// on the run loop, so tests wait by suspending (`waitForMainActorCondition`,
/// over `pollUntilTrue`), never by pumping (Tests/CLAUDE.md, "`@MainActor` tests:
/// suspend to drain, never pump"). Assertions after a direct `apply` run
/// before any suspension, so a scheduled apply cannot land between the two.
@MainActor
@Suite("Main toolbar controller")
struct MainToolbarControllerTests {
    // MARK: - Install

    /// The one test of real `viewDidAppear` delivery: nothing here installs
    /// the toolbar except the split's own appearance in the window.
    @Test func installsOnAppear() async throws {
        let fixture = ToolbarFixture(label: "installsOnAppear")
        defer { fixture.tearDown() }

        let installed = try await waitForMainActorCondition("the split's viewDidAppear to install the toolbar") {
            fixture.window.toolbar === fixture.controller.toolbar
        }
        try #require(installed)
        let applied = try await waitForMainActorCondition("the first apply") {
            fixture.controller.appliedSnapshot != nil
        }
        try #require(applied)

        #expect(fixture.identifiers == fixture.expectedIdentifiers())
        #expect(fixture.window.toolbar?.delegate === fixture.controller)
        #expect(fixture.window.toolbarStyle == .unified)
        #expect(fixture.window.titleVisibility == .hidden)
        #expect(fixture.controller.toolbar.displayMode == .iconOnly)
        #expect(fixture.controller.toolbar.allowsUserCustomization == false)
        #expect(fixture.controller.toolbar.autosavesConfiguration == false)
        #expect(fixture.controller.item(MainToolbarItemID.title)?.view === fixture.titleView)

        // Unique per controller, so no two toolbars mirror each other.
        let identifier = fixture.controller.toolbar.identifier
        #expect(identifier.hasPrefix("tbd.mainToolbar."))
        let otherSplit = ToolbarFixture.makeSplit()
        let other = MainToolbarController(
            appState: fixture.state, split: otherSplit, titleView: NSView(), requestRemoteStop: { _ in })
        #expect(other.toolbar.identifier.hasPrefix("tbd.mainToolbar."))
        #expect(other.toolbar.identifier != identifier)
    }

    /// An item AppKit asks for without inserting it must not take the one
    /// shared title view out of the toolbar's title item.
    @Test func throwawayTitleItemLeavesTheTitleViewAlone() async throws {
        let fixture = ToolbarFixture(label: "throwawayTitleItemLeavesTheTitleViewAlone")
        defer { fixture.tearDown() }
        try await fixture.ready()
        try #require(fixture.controller.item(MainToolbarItemID.title)?.view === fixture.titleView)

        let constraintsBefore = TitleWidthConstraints(of: fixture.titleView)
        let throwaway = fixture.controller.toolbar(
            fixture.controller.toolbar, itemForItemIdentifier: MainToolbarItemID.title,
            willBeInsertedIntoToolbar: false)
        #expect(throwaway != nil)
        #expect(throwaway?.view == nil)
        #expect(fixture.controller.item(MainToolbarItemID.title)?.view === fixture.titleView)
        // Its overflow row is the title's inert one, and the shared view's
        // width constraints, set once at init, are neither added to nor lost.
        let form = try #require(throwaway?.menuFormRepresentation)
        #expect(form.action == nil)
        #expect(!form.isEnabled)
        #expect(form.title == "No Selection")
        #expect(!form.isHidden)
        let constraintsAfter = TitleWidthConstraints(of: fixture.titleView)
        #expect(constraintsAfter == constraintsBefore)
        #expect(constraintsAfter.isTheFlexibleSet)
    }

    /// The split nested in a container, as SwiftUI's hosting view nests it in
    /// the app. The toolbar's tracking separator is the item its delegate
    /// made for TBD's own identifier, bound to the split's first divider from
    /// the start, wherever the split sits in the window.
    @Test func trackingSeparatorFollowsANestedSplit() async throws {
        let fixture = ToolbarFixture(label: "trackingSeparatorFollowsANestedSplit", nested: true)
        defer { fixture.tearDown() }
        try #require(fixture.window.contentViewController !== fixture.split)
        try #require(fixture.split.parent === fixture.window.contentViewController)
        try await fixture.ready()

        let separator = try #require(
            fixture.controller.item(MainToolbarItemID.sidebarSeparator) as? NSTrackingSeparatorToolbarItem)
        let bound: NSSplitView? = separator.splitView
        #expect(bound === fixture.split.splitView)
        #expect(separator.dividerIndex == 0)
    }

    /// AppKit builds and binds its own item for the standard
    /// `.sidebarTrackingSeparator`, and re-binding that item raises, so the
    /// toolbar never holds one: not after install, not with every
    /// conditional item shown, and not across a collapse and an expansion.
    /// Its one tracking separator is under TBD's own identifier.
    @Test func noStandardTrackingSeparatorEverAppears() async throws {
        let fixture = ToolbarFixture(label: "noStandardTrackingSeparatorEverAppears")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let standard = NSToolbarItem.Identifier.sidebarTrackingSeparator
        #expect(!fixture.identifiers.contains(standard))
        #expect(fixture.identifiers.contains(MainToolbarItemID.sidebarSeparator))

        fixture.showServers(url: "http://localhost:3000")
        fixture.showRemoteSession()
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        try #require(fixture.identifiers.contains(MainToolbarItemID.remoteStop))
        #expect(!fixture.identifiers.contains(standard))

        // Not animated: an offscreen window need not run an animation through.
        fixture.split.sidebarItem.isCollapsed = true
        let collapsed = try await waitForMainActorCondition("the filter to leave on collapse") {
            !fixture.identifiers.contains(MainToolbarItemID.repoFilter)
        }
        try #require(collapsed)
        #expect(!fixture.identifiers.contains(standard))

        fixture.split.sidebarItem.isCollapsed = false
        let expanded = try await waitForMainActorCondition("the filter to return on expansion") {
            fixture.identifiers.contains(MainToolbarItemID.repoFilter)
        }
        try #require(expanded)
        #expect(!fixture.identifiers.contains(standard))

        let separators = fixture.controller.toolbar.items.filter { $0 is NSTrackingSeparatorToolbarItem }
        let separatorIDs = separators.map(\.itemIdentifier)
        let expectedIDs: [NSToolbarItem.Identifier] = [MainToolbarItemID.sidebarSeparator]
        #expect(separatorIDs == expectedIDs)
    }

    @Test func noSwiftUIItems() async throws {
        let fixture = ToolbarFixture(label: "noSwiftUIItems")
        defer { fixture.tearDown() }
        try await fixture.ready()

        // Every conditional item present too, so each kind is checked.
        fixture.showServers(url: "http://localhost:3000")
        fixture.showRemoteSession()
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))

        let identifiers = fixture.identifiers
        let allowed = Set(MainToolbarItemID.allowed)
        let stray = identifiers.filter { !allowed.contains($0) }
        #expect(identifiers.contains(MainToolbarItemID.servers))
        #expect(identifiers.contains(MainToolbarItemID.remoteStop))
        #expect(stray.isEmpty)
        #expect(fixture.window.toolbar?.delegate === fixture.controller)
    }

    // MARK: - Collapse

    /// The toggle and the arrows lead the toolbar, ahead of the tracking
    /// separator, and stay visible beside the window buttons with the sidebar
    /// shown, collapsed and shown again.
    ///
    /// - **Position.** Every item here is a view item, so each is checked
    ///   by its frame in window coordinates against the zoom button and the
    ///   divider the separator tracks, as well as by order: the toggle and
    ///   arrows open `toolbar.items`, before the separator. Shown, the toggle
    ///   and arrows sit in order right of the zoom button, each its compact
    ///   width, then the filter left of the divider, and the title right of
    ///   it. Collapsed, the toggle and arrows still sit right of the zoom
    ///   button, and the title after them and left of where the shown
    ///   sidebar ended, so the toolbar followed the collapse, which a stale
    ///   sidebar section would fail.
    @Test func toggleAndArrowsSurviveACollapse() async throws {
        let fixture = ToolbarFixture(label: "toggleAndArrowsSurviveACollapse")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let toggle = try #require(fixture.controller.item(MainToolbarItemID.toggleSidebar))
        #expect(toggle.target === fixture.split)
        #expect(toggle.action == #selector(NSSplitViewController.toggleSidebar(_:)))
        #expect(toggle.view is NSButton)
        let compactWidths = [CGFloat](repeating: MainToolbarMetrics.iconButtonWidth, count: 3)
        let leading: [NSToolbarItem.Identifier] = [
            MainToolbarItemID.toggleSidebar, MainToolbarItemID.back, MainToolbarItemID.forward,
        ]

        // Shown.
        #expect(fixture.leadsBeforeTheSeparator(leading))
        let shownPlaced = try await waitForMainActorCondition("the shown sidebar's items to be visible and placed") {
            fixture.showsAll(leading) && fixture.edges()?.placedOverAShownSidebar == true
        }
        #expect(shownPlaced)
        #expect(fixture.showsAll(leading))
        let shown = try #require(fixture.edges())
        let shownFilter = try #require(shown.filter)
        #expect(shown.leadingPlaced(before: shownFilter.minX))
        let shownWidths = shown.leading.map(\.width)
        #expect(shownWidths == compactWidths)
        #expect(shownFilter.maxX <= shown.dividerX)
        #expect(shown.dividerX <= shown.title.minX)
        let shownDividerX = shown.dividerX

        // Collapsed. Not animated: an offscreen window need not run an
        // animation through.
        fixture.split.sidebarItem.isCollapsed = true
        let filterLeft = try await waitForMainActorCondition("the filter to leave on collapse") {
            !fixture.identifiers.contains(MainToolbarItemID.repoFilter)
        }
        try #require(filterLeft)
        #expect(fixture.leadsBeforeTheSeparator(leading))
        #expect(fixture.identifiers == fixture.expectedIdentifiers())
        let collapsedPlaced = try await waitForMainActorCondition("the collapsed sidebar's items to be visible and placed") {
            fixture.showsAll(leading)
                && fixture.edges()?.placedBesideTheWindowButtons(shownDividerX: shownDividerX) == true
        }
        #expect(collapsedPlaced)
        #expect(fixture.showsAll(leading))
        let collapsed = try #require(fixture.edges())
        #expect(collapsed.leadingPlaced(before: collapsed.title.minX))
        #expect(collapsed.title.minX < shownDividerX)

        // Shown again.
        fixture.split.sidebarItem.isCollapsed = false
        let filterBack = try await waitForMainActorCondition("the filter to return on expansion") {
            fixture.identifiers.contains(MainToolbarItemID.repoFilter)
        }
        try #require(filterBack)
        let expanded = fixture.identifiers
        let filterIndex = try #require(expanded.firstIndex(of: MainToolbarItemID.repoFilter))
        let separatorIndex = try #require(expanded.firstIndex(of: MainToolbarItemID.sidebarSeparator))
        #expect(filterIndex < separatorIndex)
        #expect(fixture.leadsBeforeTheSeparator(leading))
        #expect(expanded == fixture.expectedIdentifiers())
        let reshownPlaced = try await waitForMainActorCondition("the re-shown sidebar's items to be visible and placed") {
            fixture.showsAll(leading) && fixture.edges()?.placedOverAShownSidebar == true
        }
        #expect(reshownPlaced)
        #expect(fixture.showsAll(leading))
        let reshown = try #require(fixture.edges())
        let reshownFilter = try #require(reshown.filter)
        #expect(reshown.leadingPlaced(before: reshownFilter.minX))
        #expect(reshownFilter.maxX <= reshown.dividerX)
        #expect(reshown.dividerX <= reshown.title.minX)

        // No `visibleItems` drop control: narrowing the sidebar does not take
        // in the offscreen harness, so no item can be made to drop. The test
        // pins placement through the view items' frames and the order instead.
    }

    // MARK: - Compact leading buttons

    /// The toggle, back and forward are view items, each a bordered button
    /// that shows its border only under the pointer, held at the compact size
    /// by required constraints, with its tool tip, label and accessibility
    /// description, and its target and action on the button, on the item,
    /// which forwards them, and on its overflow row.
    @Test func leadingButtonsAreCompactViewItems() async throws {
        let fixture = ToolbarFixture(label: "leadingButtonsAreCompactViewItems")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let expectedWidth: [CGFloat] = [MainToolbarMetrics.iconButtonWidth]
        let expectedHeight: [CGFloat] = [MainToolbarMetrics.iconButtonHeight]

        let buttons: [(NSToolbarItem.Identifier, String, AnyObject?, Selector)] = [
            (MainToolbarItemID.toggleSidebar, "Toggle Sidebar", fixture.split,
             #selector(NSSplitViewController.toggleSidebar(_:))),
            (MainToolbarItemID.back, "Back", controller, #selector(MainToolbarController.navigateBack(_:))),
            (MainToolbarItemID.forward, "Forward", controller,
             #selector(MainToolbarController.navigateForward(_:))),
        ]
        for (identifier, tip, target, action) in buttons {
            let item = try #require(controller.item(identifier))
            let button = try #require(item.view as? NSButton)
            #expect(item.label == tip)
            #expect(item.toolTip == tip)
            #expect(button.toolTip == tip)
            #expect(button.image?.accessibilityDescription == tip)
            #expect(button.imagePosition == .imageOnly)
            #expect(button.bezelStyle == .accessoryBar)
            #expect(button.isBordered)
            #expect(button.showsBorderOnlyWhileMouseInside)
            #expect(button.target === target)
            #expect(button.action == action)
            #expect(item.target === target)
            #expect(item.action == action)
            #expect(button.translatesAutoresizingMaskIntoConstraints == false)
            let widths = ToolbarFixture.requiredConstants(of: button, .width)
            let heights = ToolbarFixture.requiredConstants(of: button, .height)
            #expect(widths == expectedWidth)
            #expect(heights == expectedHeight)
            let row = try #require(item.menuFormRepresentation)
            #expect(row.title == tip)
            #expect(row.target === target)
            #expect(row.action == action)
        }
        let leading: [NSToolbarItem.Identifier] = [
            MainToolbarItemID.toggleSidebar, MainToolbarItemID.back, MainToolbarItemID.forward,
        ]
        #expect(fixture.leadsBeforeTheSeparator(leading))
    }

    /// Each leading glyph, as its button carries it, against the size the
    /// same glyph draws at in the reference toolbar: about 16 by 13 pt for
    /// the sidebar toggle and 6 by 11 pt for each chevron. The image's own
    /// size includes the symbol's padding, so what is compared is its ink:
    /// the extent of what it draws (`inkSize(of:)`). A glyph outside the
    /// tolerance records its image and ink sizes, so the failure carries the
    /// real numbers. The button does not scale its image, so the image must
    /// also fit the button's width.
    @Test func leadingGlyphsMatchTheReferenceSizes() async throws {
        let fixture = ToolbarFixture(label: "leadingGlyphsMatchTheReferenceSizes")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let tolerance: CGFloat = 2
        let references: [(NSToolbarItem.Identifier, String, NSSize)] = [
            (MainToolbarItemID.toggleSidebar, "sidebar.left", NSSize(width: 16, height: 13)),
            (MainToolbarItemID.back, "chevron.left", NSSize(width: 6, height: 11)),
            (MainToolbarItemID.forward, "chevron.right", NSSize(width: 6, height: 11)),
        ]
        for (identifier, symbol, reference) in references {
            let button = try #require(fixture.controller.item(identifier)?.view as? NSButton)
            #expect(button.imageScaling == .scaleNone)
            let glyph = try #require(button.image)
            let imageSize = glyph.size
            #expect(imageSize.width <= MainToolbarMetrics.iconButtonWidth)
            let ink = try #require(Self.inkSize(of: glyph))
            let widthOff = abs(ink.width - reference.width) > tolerance
            let heightOff = abs(ink.height - reference.height) > tolerance
            if widthOff || heightOff {
                Issue.record(GlyphSizeOutsideReference(
                    symbol: symbol, ink: ink, image: imageSize, reference: reference, tolerance: tolerance))
            }
        }
    }

    // MARK: - Back and forward

    @Test func backForwardEnablementFollowsTheSnapshot() async throws {
        let fixture = ToolbarFixture(label: "backForwardEnablementFollowsTheSnapshot")
        defer { fixture.tearDown() }
        try await fixture.ready()

        var snapshot = MainToolbarSnapshot.make(from: fixture.state)
        snapshot.canGoBack = true
        snapshot.canGoForward = false
        fixture.controller.apply(snapshot)
        let back = try #require(fixture.controller.item(MainToolbarItemID.back))
        let forward = try #require(fixture.controller.item(MainToolbarItemID.forward))
        let backButton = try #require(back.view as? NSButton)
        let forwardButton = try #require(forward.view as? NSButton)
        let backRow = try #require(back.menuFormRepresentation)
        let forwardRow = try #require(forward.menuFormRepresentation)
        #expect(back.isEnabled == true)
        #expect(backButton.isEnabled == true)
        #expect(backRow.isEnabled == true)
        #expect(forward.isEnabled == false)
        #expect(forwardButton.isEnabled == false)
        #expect(forwardRow.isEnabled == false)
        #expect(back.isNavigational == false)
        #expect(forward.isNavigational == false)
        #expect(back.autovalidates == false)
        #expect(forward.autovalidates == false)

        snapshot.canGoBack = false
        snapshot.canGoForward = true
        fixture.controller.apply(snapshot)
        #expect(back.isEnabled == false)
        #expect(backButton.isEnabled == false)
        #expect(backRow.isEnabled == false)
        #expect(forward.isEnabled == true)
        #expect(forwardButton.isEnabled == true)
        #expect(forwardRow.isEnabled == true)
    }

    /// The Back and Forward overflow rows validate against history, as their
    /// buttons are enabled from it; any other row targeting the controller,
    /// or one with no action, is enabled.
    @Test func historyRowsValidateAgainstHistory() async throws {
        let fixture = ToolbarFixture(label: "historyRowsValidateAgainstHistory")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let state = fixture.state
        let backRow = try #require(controller.item(MainToolbarItemID.back)?.menuFormRepresentation)
        let forwardRow = try #require(controller.item(MainToolbarItemID.forward)?.menuFormRepresentation)

        try #require(!state.canGoBack && !state.canGoForward)
        #expect(controller.validateMenuItem(backRow) == false)
        #expect(controller.validateMenuItem(forwardRow) == false)

        state.recordNavigation(.worktrees([fixture.worktrees[0].id]))
        state.recordNavigation(.worktrees([fixture.worktrees[1].id]))
        try #require(state.canGoBack && !state.canGoForward)
        #expect(controller.validateMenuItem(backRow))
        #expect(controller.validateMenuItem(forwardRow) == false)

        state.navigateBack()
        try #require(state.canGoForward)
        #expect(controller.validateMenuItem(forwardRow))

        let other = NSMenuItem(
            title: "acme", action: #selector(MainToolbarController.filterChosen(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(other))
        let inert = NSMenuItem(title: "inert", action: nil, keyEquivalent: "")
        #expect(controller.validateMenuItem(inert))
    }

    // MARK: - Repo filter

    @Test func filterPopupShowsAndSetsTheFilter() async throws {
        let fixture = ToolbarFixture(label: "filterPopupShowsAndSetsTheFilter")
        defer { fixture.tearDown() }
        try await fixture.ready()

        fixture.state.repoFilter = fixture.repos[1].id
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let popup = try #require(fixture.filterPopup)
        let titles = popup.itemArray.map { $0.isSeparatorItem ? "-" : $0.title }
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets"]
        #expect(titles == expectedTitles)
        #expect(popup.titleOfSelectedItem == "widgets")
        #expect(popup.toolTip == "Filter sidebar by repository")

        popup.selectItem(at: 0)
        let sent = popup.sendAction(popup.action, to: popup.target)
        #expect(sent)
        #expect(fixture.state.repoFilter == nil)
    }

    @Test func filterNamingAMissingRepoChecksNothing() async throws {
        let fixture = ToolbarFixture(label: "filterNamingAMissingRepoChecksNothing")
        defer { fixture.tearDown() }
        try await fixture.ready()

        // Control: a known repo is checked, so -1 below is the missing case.
        fixture.state.repoFilter = fixture.repos[0].id
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let popup = try #require(fixture.filterPopup)
        #expect(popup.indexOfSelectedItem == 2)

        fixture.state.repoFilter = UUID()
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(popup.indexOfSelectedItem == -1)
    }

    /// The filter's row is selected only when the popup does not already
    /// show it: an apply with the filter unchanged sets no selection, for a
    /// known repo or a missing one. A popup whose selection something else
    /// moved is set back, which is also what shows the count does move when
    /// a selection is set. Every apply here is direct and nothing suspends,
    /// so no scheduled apply lands in between.
    @Test func anUnchangedFilterIsNotSelectedAgain() async throws {
        let fixture = ToolbarFixture(label: "anUnchangedFilterIsNotSelectedAgain")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller

        fixture.state.repoFilter = fixture.repos[1].id
        let known = MainToolbarSnapshot.make(from: fixture.state)
        let before = controller.filterSelectionCount
        controller.apply(known)
        let popup = try #require(fixture.filterPopup)
        #expect(popup.indexOfSelectedItem == 3)
        #expect(controller.filterSelectionCount == before + 1)

        controller.apply(known)
        #expect(popup.indexOfSelectedItem == 3)
        #expect(controller.filterSelectionCount == before + 1)

        popup.selectItem(at: 0)
        controller.apply(known)
        #expect(popup.indexOfSelectedItem == 3)
        #expect(controller.filterSelectionCount == before + 2)

        fixture.state.repoFilter = UUID()
        let missing = MainToolbarSnapshot.make(from: fixture.state)
        controller.apply(missing)
        #expect(popup.indexOfSelectedItem == -1)
        #expect(controller.filterSelectionCount == before + 3)

        controller.apply(missing)
        #expect(popup.indexOfSelectedItem == -1)
        #expect(controller.filterSelectionCount == before + 3)
    }

    @Test func filterWidthIsCapped() async throws {
        let fixture = ToolbarFixture(label: "filterWidthIsCapped")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let long = Repo(path: "/tmp/long", displayName: String(repeating: "acme-widgets-", count: 6) + "xx")
        try #require(long.displayName.count == 80)
        fixture.state.repos.append(long)
        fixture.state.repoFilter = long.id
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let popup = try #require(fixture.filterPopup)
        #expect(popup.titleOfSelectedItem == long.displayName)
        // Uncapped, the name would be wider, so the cap is what holds it.
        #expect(popup.intrinsicContentSize.width > MainToolbarMetrics.filterMaxWidth)

        let laidOut = try await waitForMainActorCondition("the filter to be laid out in the toolbar") {
            fixture.window.layoutIfNeeded()
            return popup.window === fixture.window && popup.frame.width > 0
        }
        try #require(laidOut)
        #expect(popup.frame.width <= MainToolbarMetrics.filterMaxWidth)
        #expect(popup.fittingSize.width <= MainToolbarMetrics.filterMaxWidth)
    }

    // MARK: - Overflow menu

    /// Every item the layout can show, with the Servers item and every remote
    /// item present, sends its overflow row's action from that row, as the
    /// overflow menu does, and each row of a submenu sends its own. An
    /// action that assumed another sender would raise, ending the test
    /// process, which is the regression this guards. The filter's rows run
    /// in order, so the last repo is the filter after them, and Stop asks for
    /// its confirmation.
    ///
    /// - **Toggle Sidebar** is checked, not sent: sending it would collapse
    ///   the sidebar and take the filter away part way through.
    ///   `toggleAndArrowsSurviveACollapse` covers the collapse.
    /// - **Servers** has no main URL, so it carries no action that would open
    ///   one, and its rows are sent from a bare menu item: run, each would
    ///   start or stop servers through the daemon.
    /// - **Remote buttons** have explicit rows titled with their labels.
    @Test func everyOverflowRowToleratesAMenuItemSender() async throws {
        let fixture = ToolbarFixture(label: "everyOverflowRowToleratesAMenuItemSender")
        defer { fixture.tearDown() }
        try await fixture.ready()
        fixture.showServers(url: nil)
        let selection = fixture.showRemoteSession()
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let items = fixture.controller.toolbar.items
        let shownIDs = Set(items.map(\.itemIdentifier))
        let missing = MainToolbarItemID.custom.filter { !shownIDs.contains($0) }
        try #require(missing.isEmpty)

        let toggle = try #require(fixture.controller.item(MainToolbarItemID.toggleSidebar))
        let toggleRow = ToolbarFixture.overflowRow(of: toggle)
        #expect(toggleRow.target === fixture.split)
        #expect(toggleRow.action == #selector(NSSplitViewController.toggleSidebar(_:)))

        let remoteIDs: [NSToolbarItem.Identifier] = [
            MainToolbarItemID.remoteTranscript, MainToolbarItemID.remoteReconnect, MainToolbarItemID.remoteStop,
        ]
        for identifier in remoteIDs {
            let remote = try #require(fixture.controller.item(identifier))
            let form = try #require(remote.menuFormRepresentation)
            #expect(form.title == remote.label)
            #expect(form.target === fixture.controller)
            #expect(form.action == remote.action)
        }

        var unsent: [String] = []
        var sent = 0
        for item in items where ToolbarFixture.hasOverflowRow(item)
            && item.itemIdentifier != MainToolbarItemID.toggleSidebar {
            let row = ToolbarFixture.overflowRow(of: item)
            if let action = row.action {
                sent += 1
                let sender = item.menuFormRepresentation ?? NSMenuItem(title: row.title, action: action, keyEquivalent: "")
                if !NSApplication.shared.sendAction(action, to: row.target, from: sender) {
                    unsent.append(row.title)
                }
            }
            for subrow in row.subrows where !subrow.isSeparatorItem {
                guard let action = subrow.action else { continue }
                sent += 1
                let sender = ToolbarFixture.harmlessSender(for: subrow)
                if !NSApplication.shared.sendAction(action, to: subrow.target, from: sender) {
                    unsent.append(subrow.title)
                }
            }
        }

        #expect(unsent.isEmpty)
        // Back, Forward, three filter rows, Transcript, Reconnect and Stop at
        // least.
        #expect(sent >= 8)
        #expect(fixture.state.repoFilter == fixture.repos[1].id)
        let expectedStops: [RemoteSessionSelection] = [selection]
        #expect(fixture.stopRequests == expectedStops)
    }

    /// The filter's overflow row is "Filter" with a submenu of the popup's
    /// rows. It checks the current choice, or none for a repo that is gone;
    /// choosing a row sets the filter; and it follows the options and the
    /// choice as they change. Each check reads the item's current row, as a
    /// change replaces the row rather than editing it.
    @Test func filterOverflowRowMirrorsThePopup() async throws {
        let fixture = ToolbarFixture(label: "filterOverflowRowMirrorsThePopup")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let chooseAction = #selector(MainToolbarController.filterChosen(_:))

        fixture.state.repoFilter = fixture.repos[1].id
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let form = try #require(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation)
        let rows = try #require(form.submenu)
        #expect(form.title == "Filter")
        // A row with a submenu only opens it; AppKit gives it
        // `submenuAction:`, so its rows are what is checked.
        #expect(form.hasSubmenu)
        #expect(rows.autoenablesItems == false)
        #expect(rows.delegate === controller.filterMenuTracker)
        let titles = Self.describeFilterRows(rows)
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets"]
        #expect(titles == expectedTitles)
        let checkedWidgets = Self.checkedTitles(rows)
        let expectedWidgets: [String] = ["widgets"]
        #expect(checkedWidgets == expectedWidgets)

        let choosable = rows.items.filter { !$0.isSeparatorItem }
        try #require(choosable.count == 3)
        let ids = choosable.map { $0.representedObject as? UUID }
        let expectedIDs: [UUID?] = [nil, fixture.repos[0].id, fixture.repos[1].id]
        #expect(ids == expectedIDs)
        let wired = choosable.allSatisfy { $0.target === controller && $0.action == chooseAction }
        #expect(wired)

        // Choosing a row sets the filter, and the next apply's row checks it.
        let chose = NSApplication.shared.sendAction(chooseAction, to: controller, from: choosable[1])
        #expect(chose)
        #expect(fixture.state.repoFilter == fixture.repos[0].id)
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let acmeRows = try #require(Self.filterOverflowRows(of: controller))
        let checkedAcme = Self.checkedTitles(acmeRows)
        let expectedAcme: [String] = ["acme"]
        #expect(checkedAcme == expectedAcme)

        // A filter naming a repo that is gone checks none.
        fixture.state.repoFilter = UUID()
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let missingRows = try #require(Self.filterOverflowRows(of: controller))
        let checkedMissing = Self.checkedTitles(missingRows)
        #expect(checkedMissing.isEmpty)
        #expect(Self.describeFilterRows(missingRows) == expectedTitles)

        // A new repo is in the next row, and checked when chosen.
        let gadgets = Repo(path: "/tmp/gadgets", displayName: "gadgets")
        fixture.state.repos.append(gadgets)
        fixture.state.repoFilter = gadgets.id
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let grownRows = try #require(Self.filterOverflowRows(of: controller))
        let grownTitles = Self.describeFilterRows(grownRows)
        let expectedGrown: [String] = ["All Repos", "-", "acme", "widgets", "gadgets"]
        #expect(grownTitles == expectedGrown)
        let checkedGadgets = Self.checkedTitles(grownRows)
        let expectedGadgets: [String] = ["gadgets"]
        #expect(checkedGadgets == expectedGadgets)
        #expect(grownRows.delegate === controller.filterMenuTracker)
        let popup = try #require(fixture.filterPopup)
        #expect(popup.titleOfSelectedItem == "gadgets")
    }

    /// The title's and the filter's overflow rows are replaced, never
    /// edited, and only when what they show changes: an apply that changes
    /// nothing leaves the same rows on the items, a new title replaces only
    /// the title's row, and a new choice replaces only the filter's.
    @Test func overflowRowsAreReplacedOnlyWhenTheyChange() async throws {
        let fixture = ToolbarFixture(label: "overflowRowsAreReplacedOnlyWhenTheyChange")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller

        fixture.state.selectedWorktreeIDs = [fixture.worktrees[0].id]
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let firstTitle = try #require(controller.item(MainToolbarItemID.title)?.menuFormRepresentation)
        let firstFilter = try #require(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation)
        #expect(firstTitle.title == "main")

        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(controller.item(MainToolbarItemID.title)?.menuFormRepresentation === firstTitle)
        #expect(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation === firstFilter)

        fixture.state.selectedWorktreeIDs = [fixture.worktrees[1].id]
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let secondTitle = try #require(controller.item(MainToolbarItemID.title)?.menuFormRepresentation)
        #expect(secondTitle !== firstTitle)
        #expect(secondTitle.title == "feature")
        #expect(firstTitle.title == "main")
        #expect(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation === firstFilter)

        fixture.state.repoFilter = fixture.repos[0].id
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let secondFilter = try #require(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation)
        #expect(secondFilter !== firstFilter)
        #expect(controller.item(MainToolbarItemID.title)?.menuFormRepresentation === secondTitle)
        let firstRows = try #require(firstFilter.submenu)
        let secondRows = try #require(secondFilter.submenu)
        let checkedBefore = Self.checkedTitles(firstRows)
        let checkedAfter = Self.checkedTitles(secondRows)
        let expectedBefore: [String] = ["All Repos"]
        let expectedAfter: [String] = ["acme"]
        #expect(checkedBefore == expectedBefore)
        #expect(checkedAfter == expectedAfter)

        // A collapse and an expansion re-insert the filter as a new item,
        // made with a row for the filter the last apply showed, which an
        // apply with that filter keeps. Not animated: an offscreen window
        // need not run an animation through.
        let filterItem = try #require(controller.item(MainToolbarItemID.repoFilter))
        fixture.split.sidebarItem.isCollapsed = true
        let filterLeft = try await waitForMainActorCondition("the filter to leave on collapse") {
            controller.item(MainToolbarItemID.repoFilter) == nil
        }
        try #require(filterLeft)
        fixture.split.sidebarItem.isCollapsed = false
        let filterBack = try await waitForMainActorCondition("the filter to return on expansion, applied") {
            controller.item(MainToolbarItemID.repoFilter) != nil && !controller.applyScheduled
        }
        try #require(filterBack)
        let reinserted = try #require(controller.item(MainToolbarItemID.repoFilter))
        #expect(reinserted !== filterItem)
        let reinsertedRow = try #require(reinserted.menuFormRepresentation)
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation === reinsertedRow)
        let reinsertedRows = try #require(reinsertedRow.submenu)
        let checkedReinserted = Self.checkedTitles(reinsertedRows)
        #expect(checkedReinserted == expectedAfter)
    }

    /// A filter or title item made before any apply carries an empty row:
    /// "Filter" with no repos, and "No Selection". One made after an apply
    /// starts from what that apply showed, so an item the toolbar re-inserts,
    /// as after a collapse, never shows an empty row in between. Made with
    /// `willBeInserted: false`, so the title item leaves the shared title
    /// view where it is.
    @Test func newItemsStartFromTheLastApply() async throws {
        let fixture = ToolbarFixture(label: "newItemsStartFromTheLastApply")
        defer { fixture.tearDown() }
        let unapplied = MainToolbarController(
            appState: fixture.state, split: ToolbarFixture.makeSplit(), titleView: NSView(),
            requestRemoteStop: { _ in })
        try #require(unapplied.appliedSnapshot == nil)
        let emptyFilter = try #require(unapplied.makeItem(MainToolbarItemID.repoFilter, willBeInserted: false))
        let emptyForm = try #require(emptyFilter.menuFormRepresentation)
        #expect(emptyForm.title == "Filter")
        let emptyRows = try #require(emptyForm.submenu)
        #expect(emptyRows.items.isEmpty)
        #expect(emptyRows.delegate === unapplied.filterMenuTracker)
        let emptyTitle = try #require(unapplied.makeItem(MainToolbarItemID.title, willBeInserted: false))
        let emptyTitleRow = try #require(emptyTitle.menuFormRepresentation)
        #expect(emptyTitleRow.title == "No Selection")
        #expect(emptyTitleRow.isHidden == false)
        #expect(emptyTitleRow.isEnabled == false)
        #expect(emptyTitleRow.action == nil)

        try await fixture.ready()
        fixture.state.repoFilter = fixture.repos[1].id
        fixture.state.selectedWorktreeIDs = [fixture.worktrees[1].id]
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let filterItem = try #require(fixture.controller.makeItem(MainToolbarItemID.repoFilter, willBeInserted: false))
        let rows = try #require(filterItem.menuFormRepresentation?.submenu)
        let titles = Self.describeFilterRows(rows)
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets"]
        #expect(titles == expectedTitles)
        let checked = Self.checkedTitles(rows)
        let expectedChecked: [String] = ["widgets"]
        #expect(checked == expectedChecked)
        let titleItem = try #require(fixture.controller.makeItem(MainToolbarItemID.title, willBeInserted: false))
        let titleRow = try #require(titleItem.menuFormRepresentation)
        #expect(titleRow.title == "feature")
        #expect(titleRow.isHidden == false)
        #expect(titleRow.isEnabled == false)
        #expect(titleRow.action == nil)
        #expect(titleItem.view == nil)
        #expect(fixture.controller.item(MainToolbarItemID.title)?.view === fixture.titleView)
    }

    /// While one of the filter's menus is open its row is not replaced under
    /// the pointer; the close catches it up, with no apply but the one it
    /// schedules.
    @Test func filterOverflowRowsWaitForAnOpenMenuToClose() async throws {
        let fixture = ToolbarFixture(label: "filterOverflowRowsWaitForAnOpenMenuToClose")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let openForm = try #require(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation)
        let openRows = try #require(openForm.submenu)
        let before = Self.describeFilterRows(openRows)

        controller.filterMenuTracker.menuWillOpen(openRows)
        fixture.state.repos.append(Repo(path: "/tmp/gadgets", displayName: "gadgets"))
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation === openForm)
        let whileOpen = Self.describeFilterRows(openRows)
        #expect(whileOpen == before)

        controller.filterMenuTracker.menuDidClose(openRows)
        let caughtUp = try await waitForMainActorCondition("the filter's overflow row to catch up once it closes") {
            let rows = MainToolbarControllerTests.filterOverflowRows(of: controller)
            return rows.map { MainToolbarControllerTests.describeFilterRows($0).contains("gadgets") } ?? false
        }
        #expect(caughtUp)
    }

    /// `filterChosen(_:)` reads its sender's class rather than assuming it.
    /// A bare menu item, as AppKit's default overflow row for the filter
    /// would send, carries no repo, which is "All Repos". A sender that is
    /// neither a popup nor a menu item, a popup with no selected row, and no
    /// sender at all change nothing. The popup sender is
    /// `filterPopupShowsAndSetsTheFilter`'s.
    @Test func filterChosenToleratesAnySender() async throws {
        let fixture = ToolbarFixture(label: "filterChosenToleratesAnySender")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let action = #selector(MainToolbarController.filterChosen(_:))
        let acme = fixture.repos[0].id
        fixture.state.repoFilter = acme

        let fromButton = NSApplication.shared.sendAction(action, to: controller, from: NSButton())
        #expect(fromButton)
        #expect(fixture.state.repoFilter == acme)
        let emptyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let fromEmptyPopup = NSApplication.shared.sendAction(action, to: controller, from: emptyPopup)
        #expect(fromEmptyPopup)
        #expect(fixture.state.repoFilter == acme)
        controller.filterChosen(nil)
        #expect(fixture.state.repoFilter == acme)

        let bare = NSMenuItem(title: "Filter", action: action, keyEquivalent: "")
        let fromBareRow = NSApplication.shared.sendAction(action, to: controller, from: bare)
        #expect(fromBareRow)
        #expect(fixture.state.repoFilter == nil)
    }

    /// `serversMenuItemChosen(_:)` runs only a row that carries a command: a
    /// bare menu item, another control and no sender at all run nothing.
    @Test func serversMenuItemChosenToleratesAnySender() async throws {
        let fixture = ToolbarFixture(label: "serversMenuItemChosenToleratesAnySender")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let action = #selector(MainToolbarController.serversMenuItemChosen(_:))
        let worktreeID = fixture.worktrees[0].id

        let bare = NSMenuItem(title: "Start", action: action, keyEquivalent: "")
        let fromBareRow = NSApplication.shared.sendAction(action, to: controller, from: bare)
        #expect(fromBareRow)
        let fromButton = NSApplication.shared.sendAction(action, to: controller, from: NSButton())
        #expect(fromButton)
        controller.serversMenuItemChosen(nil)
        #expect(fixture.state.devServerActionMessages[worktreeID] == nil)
    }

    // MARK: - Title

    /// The title's overflow row is inert, never hidden, and shows the
    /// cluster's main title: "No Selection" with nothing selected, the
    /// worktree's name, a remote session's name when only it is selected,
    /// and "No Selection" again once neither is. Each check reads the item's
    /// current row, as a change replaces it.
    @Test func titleOverflowRowShowsTheTitle() async throws {
        let fixture = ToolbarFixture(label: "titleOverflowRowShowsTheTitle")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let empty = try #require(controller.item(MainToolbarItemID.title)?.menuFormRepresentation)
        #expect(empty.title == "No Selection")
        #expect(empty.isHidden == false)
        #expect(empty.isEnabled == false)
        #expect(empty.action == nil)

        fixture.state.selectedWorktreeIDs = [fixture.worktrees[1].id]
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let worktreeRow = try #require(controller.item(MainToolbarItemID.title)?.menuFormRepresentation)
        #expect(worktreeRow.title == "feature")
        #expect(worktreeRow.isHidden == false)
        #expect(worktreeRow.isEnabled == false)
        #expect(worktreeRow.action == nil)

        fixture.state.selectedWorktreeIDs = []
        let selection = fixture.showRemoteSession()
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let sessionRow = try #require(controller.item(MainToolbarItemID.title)?.menuFormRepresentation)
        let sessionName = fixture.state.remoteSessionDisplayName(for: selection)
        #expect(sessionRow.title == sessionName)
        #expect(sessionRow.isHidden == false)
        #expect(sessionRow.isEnabled == false)

        fixture.state.selectedRemoteSession = nil
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let clearedRow = try #require(controller.item(MainToolbarItemID.title)?.menuFormRepresentation)
        #expect(clearedRow.title == "No Selection")
        #expect(clearedRow.isHidden == false)
        #expect(clearedRow.isEnabled == false)
        #expect(clearedRow.action == nil)

        // An unchanged apply keeps the "No Selection" row.
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(controller.item(MainToolbarItemID.title)?.menuFormRepresentation === clearedRow)
    }

    /// The shared title view holds a flexible width set once at init: a
    /// required minimum and maximum, and a preference for the maximum that
    /// outweighs its hugging but not a fitting measurement's pull, which its
    /// compression resistance outweighs in turn. So a fitting measurement of
    /// the title's hosting view gives the constant ideal width, for a short
    /// title and a long one alike, where plain hosting views of the same
    /// titles fall either side of it.
    @Test func titleViewHoldsAFlexibleWidth() async throws {
        let fixture = ToolbarFixture(label: "titleViewHoldsAFlexibleWidth")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let titleView = fixture.titleView
        #expect(titleView.translatesAutoresizingMaskIntoConstraints == false)
        let constraints = TitleWidthConstraints(of: titleView)
        #expect(constraints.isTheFlexibleSet)
        let hugging = titleView.contentHuggingPriority(for: .horizontal)
        let resistance = titleView.contentCompressionResistancePriority(for: .horizontal)
        #expect(hugging == MainToolbarController.titleHuggingPriority)
        #expect(resistance == MainToolbarController.titleCompressionResistance)
        let huggingValue = MainToolbarController.titleHuggingPriority.rawValue
        let fillValue = MainToolbarController.titleFillPriority.rawValue
        let fittingValue = NSLayoutConstraint.Priority.fittingSizeCompression.rawValue
        let resistanceValue = MainToolbarController.titleCompressionResistance.rawValue
        #expect(huggingValue < fillValue)
        #expect(fillValue < fittingValue)
        #expect(fittingValue < resistanceValue)

        // Measured on fresh hosting views outside the toolbar, so nothing
        // AppKit holds the item's view to enters the measurement.
        let short = Text("x")
        let long = Text(String(repeating: "acme-widgets-", count: 8))
        let shortPlain = NSHostingView(rootView: short).fittingSize.width
        let longPlain = NSHostingView(rootView: long).fittingSize.width
        try #require(shortPlain > 0)
        try #require(shortPlain < MainToolbarMetrics.titleIdealWidth)
        try #require(longPlain > MainToolbarMetrics.titleIdealWidth)
        let shortTitle = MainWindowSplitView.makeTitleView(short)
        let longTitle = MainWindowSplitView.makeTitleView(long)
        MainToolbarController.prepareTitleView(shortTitle)
        MainToolbarController.prepareTitleView(longTitle)
        #expect(shortTitle.fittingSize.width == MainToolbarMetrics.titleIdealWidth)
        #expect(longTitle.fittingSize.width == MainToolbarMetrics.titleIdealWidth)
    }

    // MARK: - Servers

    @Test func serversMenuIsBuiltOnOpen() async throws {
        let fixture = ToolbarFixture(label: "serversMenuIsBuiltOnOpen")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let worktreeID = fixture.worktrees[0].id
        let messages = ["web: failed to stop"]
        let first = fixture.showServers(url: "http://localhost:3000")
        fixture.state.devServerActionMessages[worktreeID] = messages
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let servers = try #require(fixture.controller.item(MainToolbarItemID.servers) as? NSMenuToolbarItem)
        let menu = servers.menu
        #expect(menu.autoenablesItems == false)
        #expect(menu.delegate === fixture.controller)

        fixture.controller.menuNeedsUpdate(menu)
        let expectedFirst = ServersToolbarMenu.entries(list: first, messages: messages).map { Self.describeEntry($0) }
        let rowsFirst = menu.items.map { Self.describeRow($0) }
        #expect(rowsFirst == expectedFirst)
        let note = menu.items.first { $0.title == "web: failed to stop" }
        #expect(note?.isEnabled == false)

        // The list changes between two opens; the second open shows the new one.
        let second = fixture.list(
            [fixture.server("web", .running, url: "http://localhost:3000"), fixture.server("api", .stopped)],
            id: worktreeID)
        fixture.state.devServerLists[worktreeID] = second
        fixture.controller.menuNeedsUpdate(menu)
        let expectedSecond = ServersToolbarMenu.entries(list: second, messages: messages).map { Self.describeEntry($0) }
        let rowsSecond = menu.items.map { Self.describeRow($0) }
        #expect(expectedSecond != expectedFirst)
        #expect(rowsSecond == expectedSecond)
    }

    @Test func serversPrimaryActionOnlyWithAURL() async throws {
        let fixture = ToolbarFixture(label: "serversPrimaryActionOnlyWithAURL")
        defer { fixture.tearDown() }
        try await fixture.ready()

        fixture.showServers(url: "http://localhost:3000")
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let withURL = try #require(fixture.controller.item(MainToolbarItemID.servers) as? NSMenuToolbarItem)
        #expect(withURL.action == #selector(MainToolbarController.openPrimaryServerURL(_:)))
        #expect(withURL.target === fixture.controller)
        #expect(withURL.title == "1 running")
        #expect(withURL.toolTip == "Open http://localhost:3000 · more options")
        #expect(withURL.showsIndicator == true)
        #expect(withURL.visibilityPriority == .high)

        fixture.showServers(url: nil)
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let withoutURL = try #require(fixture.controller.item(MainToolbarItemID.servers) as? NSMenuToolbarItem)
        #expect(withoutURL.action == nil)
        #expect(withoutURL.toolTip == "Dev servers")
    }

    @Test func serversIconReBakesOnAppearance() async throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        #expect(MainToolbarController.colorScheme(for: dark) == .dark)
        #expect(MainToolbarController.colorScheme(for: aqua) == .light)

        let fixture = ToolbarFixture(label: "serversIconReBakesOnAppearance")
        defer { fixture.tearDown() }
        fixture.window.appearance = aqua
        try await fixture.ready()
        fixture.showServers(url: "http://localhost:3000")
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let servers = try #require(fixture.controller.item(MainToolbarItemID.servers))
        let light = try #require(servers.image)
        #expect(light.accessibilityDescription == "Dev servers, 1 running")
        #expect(light.isTemplate == false)

        // The appearance change alone schedules the re-bake, through KVO.
        fixture.window.appearance = dark
        let lightID = ObjectIdentifier(light)
        let followed = try await waitForMainActorCondition("the Servers icon to follow the appearance") {
            servers.image.map { ObjectIdentifier($0) } != lightID
        }
        #expect(followed)

        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let rebaked = try #require(servers.image)
        #expect(rebaked !== light)
        #expect(rebaked.accessibilityDescription == "Dev servers, 1 running")
    }

    // MARK: - Re-install

    /// The replacement alone brings the toolbar back, through KVO on the
    /// window's `toolbar`: `ready()` leaves no apply queued and nothing here
    /// schedules one, so no other apply can stand in for the watch.
    @Test func reinstallsAReplacedToolbar() async throws {
        let fixture = ToolbarFixture(label: "reinstallsAReplacedToolbar")
        defer { fixture.tearDown() }
        try await fixture.ready()
        try #require(fixture.controller.applyScheduled == false)

        fixture.window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.replacement")
        try #require(fixture.window.toolbar !== fixture.controller.toolbar)

        let back = try await waitForMainActorCondition("our toolbar to come back") {
            fixture.window.toolbar === fixture.controller.toolbar
        }
        #expect(back)
        #expect(fixture.identifiers == fixture.expectedIdentifiers())
    }

    /// A change of a visible window's toolbar to none is a replacement, as
    /// another toolbar is: it counts, the clear alone brings ours back, and
    /// it is held to the same cap. Past the cap the window stays without a
    /// toolbar until the cooldown ends, which puts ours back.
    @Test(.clockDriven) func aToolbarClearedOnAVisibleWindowIsAReplacement() async throws {
        let clock = EventDrivenTestClock()
        let fixture = ToolbarFixture(
            label: "aToolbarClearedOnAVisibleWindowIsAReplacement",
            now: TestDateSource().provider, clock: clock)
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window
        try #require(window.isVisible)
        try #require(controller.applyScheduled == false)
        try #require(controller.recentReplacements.isEmpty)

        let cap = MainToolbarController.maxReplacementsInWindow
        for attempt in 1...cap {
            window.toolbar = nil
            // KVO reports synchronously, so the clear is already counted.
            #expect(controller.recentReplacements.count == attempt)
            let back = try await waitForMainActorCondition("clear \(attempt) of \(cap) to be put back") {
                window.toolbar === controller.toolbar
            }
            try #require(back)
        }
        let quiet = try await waitForMainActorCondition("no apply queued before the clear past the cap") {
            !controller.applyScheduled
        }
        try #require(quiet)
        try #require(controller.isInReinstallCooldown == false)

        window.toolbar = nil
        #expect(controller.isInReinstallCooldown)
        #expect(controller.applyScheduled == false)
        #expect(window.toolbar == nil)

        try await clock.requireAdvanceWhenArmed(
            by: MainToolbarController.reinstallCooldown, timeout: TestDeadlines.saturatedPass)
        let restored = try await waitForMainActorCondition("the toolbar to come back when the cooldown ends") {
            window.toolbar === controller.toolbar
        }
        #expect(restored)
    }

    /// A change of a window's toolbar to none once the window is ordered out
    /// is a removal, as teardown makes before the split is dismantled, not a
    /// competing toolbar: it counts no replacement and queues nothing, and a
    /// later apply leaves the window without a toolbar rather than putting
    /// ours back on a closing window. Another toolbar once the window is back
    /// in, with nothing installing on its appearance, is still a replacement
    /// of ours: the removal left ours as the last toolbar the watch saw, so
    /// it counts once, and it is put back.
    @Test func aToolbarClearedOnAHiddenWindowIsNotAReplacement() async throws {
        let fixture = ToolbarFixture(label: "aToolbarClearedOnAHiddenWindowIsNotAReplacement")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        window.orderOut(nil)
        try #require(window.isVisible == false)
        let quiet = try await waitForMainActorCondition("no apply queued after ordering the window out") {
            !controller.applyScheduled
        }
        try #require(quiet)
        try #require(controller.recentReplacements.isEmpty)

        window.toolbar = nil
        // KVO reports synchronously, so a watch that took the removal for a
        // replacement would have counted it and queued an apply by now.
        #expect(controller.recentReplacements.isEmpty)
        #expect(controller.applyScheduled == false)
        #expect(controller.isInstalled)

        let appliesBefore = controller.applyCount
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(controller.applyCount == appliesBefore + 1)
        #expect(window.toolbar == nil)

        // Nothing suspends from ordering the window in to the toolbar set, so
        // no queued apply can put ours back in between.
        fixture.split.onViewDidAppear = nil
        window.orderFront(nil)
        try #require(window.isVisible)
        try #require(window.toolbar == nil)
        window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.afterRemoval")
        #expect(controller.recentReplacements.count == 1)
        let back = try await waitForMainActorCondition("a toolbar set after the removal to be replaced by ours") {
            window.toolbar === controller.toolbar
        }
        #expect(back)
    }

    /// Another toolbar set on a window that is not visible is left alone, as
    /// a clear there is: it counts no replacement and queues nothing, and a
    /// later apply leaves it on the window rather than putting ours back on a
    /// closing window.
    @Test func aToolbarSetOnAHiddenWindowIsNotAReplacement() async throws {
        let fixture = ToolbarFixture(label: "aToolbarSetOnAHiddenWindowIsNotAReplacement")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        window.orderOut(nil)
        try #require(window.isVisible == false)
        let quiet = try await waitForMainActorCondition("no apply queued after ordering the window out") {
            !controller.applyScheduled
        }
        try #require(quiet)
        try #require(controller.recentReplacements.isEmpty)
        try #require(window.toolbar === controller.toolbar)

        let other = NSToolbar(identifier: "MainToolbarControllerTests.onHiddenWindow")
        window.toolbar = other
        // KVO reports synchronously, so a watch that took the change for a
        // replacement would have counted it and queued an apply by now.
        #expect(controller.recentReplacements.isEmpty)
        #expect(controller.applyScheduled == false)
        #expect(controller.isInstalled)

        // The apply runs, which is what makes its leaving the other toolbar
        // on the window mean something.
        let appliesBefore = controller.applyCount
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(controller.applyCount == appliesBefore + 1)
        #expect(window.toolbar === other)
    }

    /// One replacement past `maxReplacementsInWindow` inside one
    /// `replacementWindow` starts the cooldown: that replacement stays and
    /// queues nothing. When the cooldown runs out, the controller puts the
    /// toolbar back with nothing else scheduling an apply. The count then
    /// starts afresh: with the date still frozen, the next replacement is put
    /// back at once, where a count that was never cleared would make it the
    /// fifth inside one window and start another cooldown.
    @Test(.clockDriven) func refusesAToolbarReplacedTooOftenUntilTheCooldownEnds() async throws {
        let clock = EventDrivenTestClock()
        let fixture = ToolbarFixture(
            label: "refusesAToolbarReplacedTooOftenUntilTheCooldownEnds",
            now: TestDateSource().provider, clock: clock)
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        let kept = try await fixture.replaceUntilTheCooldownStarts(label: "refused")
        // KVO reports synchronously, so the refusal is already in place.
        #expect(controller.isInReinstallCooldown)
        #expect(controller.applyScheduled == false)
        #expect(window.toolbar === kept)

        try await clock.requireAdvanceWhenArmed(
            by: MainToolbarController.reinstallCooldown, timeout: TestDeadlines.saturatedPass)
        let back = try await waitForMainActorCondition("the toolbar to come back when the cooldown ends") {
            window.toolbar === controller.toolbar
        }
        try #require(back)
        #expect(controller.isInReinstallCooldown == false)

        window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.refused.afterCooldown")
        #expect(controller.isInReinstallCooldown == false)
        let backAgain = try await waitForMainActorCondition("the first replacement after the cooldown to be put back") {
            window.toolbar === controller.toolbar
        }
        #expect(backAgain)
    }

    /// Applies during the cooldown leave the replacement on the window and do
    /// not extend the cooldown. They run after part of it has passed, and the
    /// rest of the original cooldown still brings the toolbar back; a
    /// cooldown an apply restarted would need the whole of it again. The
    /// partial advance must not end it either: had it, the first apply after
    /// it would have put the toolbar back.
    @Test(.clockDriven) func appliesDuringTheCooldownNeitherReinstallNorExtendIt() async throws {
        let clock = EventDrivenTestClock()
        let fixture = ToolbarFixture(
            label: "appliesDuringTheCooldownNeitherReinstallNorExtendIt",
            now: TestDateSource().provider, clock: clock)
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        let kept = try await fixture.replaceUntilTheCooldownStarts(label: "stream")
        try #require(controller.isInReinstallCooldown)
        let cooldown = MainToolbarController.reinstallCooldown
        let partway: Duration = .seconds(2)
        try #require(partway < cooldown)
        try await clock.requireAdvanceWhenArmed(by: partway, timeout: TestDeadlines.saturatedPass)

        for round in 1...3 {
            let before = controller.applyCount
            controller.scheduleApply()
            let applied = try await waitForMainActorCondition("apply \(round) during the cooldown") {
                controller.applyCount > before
            }
            try #require(applied)
            #expect(window.toolbar === kept)
            #expect(controller.isInReinstallCooldown)
        }

        try await clock.requireAdvanceWhenArmed(by: cooldown - partway, timeout: TestDeadlines.saturatedPass)
        let back = try await waitForMainActorCondition("the toolbar to come back at the original cooldown's end") {
            window.toolbar === controller.toolbar
        }
        #expect(back)
    }

    /// A second install during the cooldown, as a window ordered back in or
    /// unminimized makes through `viewDidAppear`, leaves the replacement on
    /// the window, both at once and after the apply it schedules. Only the
    /// cooldown's end puts the toolbar back.
    @Test(.clockDriven) func installDuringTheCooldownLeavesTheReplacement() async throws {
        let clock = EventDrivenTestClock()
        let fixture = ToolbarFixture(
            label: "installDuringTheCooldownLeavesTheReplacement",
            now: TestDateSource().provider, clock: clock)
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        let kept = try await fixture.replaceUntilTheCooldownStarts(label: "reinstall")
        try #require(controller.isInReinstallCooldown)

        let before = controller.applyCount
        controller.install(on: window)
        #expect(window.toolbar === kept)
        let applied = try await waitForMainActorCondition("the apply the install during the cooldown scheduled") {
            controller.applyCount > before
        }
        try #require(applied)
        #expect(window.toolbar === kept)
        #expect(controller.isInReinstallCooldown)

        try await clock.requireAdvanceWhenArmed(
            by: MainToolbarController.reinstallCooldown, timeout: TestDeadlines.saturatedPass)
        let back = try await waitForMainActorCondition("the toolbar to come back when the cooldown ends") {
            window.toolbar === controller.toolbar
        }
        #expect(back)
    }

    /// During a cooldown the window shows another toolbar, and an apply an
    /// observed change asked for, finding nothing the toolbar shows changed,
    /// still does nothing: no apply runs, so no content is updated on the
    /// detached toolbar. A change the toolbar does show is still applied,
    /// leaving the replacement on the window. The cooldown is never advanced,
    /// so it runs throughout; the fixture's teardown cancels it.
    @Test func anUnchangedObservedChangeDuringTheCooldownDoesNotReapply() async throws {
        let fixture = ToolbarFixture(
            label: "anUnchangedObservedChangeDuringTheCooldownDoesNotReapply",
            now: TestDateSource().provider, clock: EventDrivenTestClock())
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        // The snapshot reads the dev-server lists only with one worktree
        // selected.
        fixture.showServers(url: "http://localhost:3000")
        let shown = try await waitForMainActorCondition("the apply that shows the Servers item, with none queued") {
            controller.appliedSnapshot?.servers?.isRunning == true && !controller.applyScheduled
        }
        try #require(shown)

        let kept = try await fixture.replaceUntilTheCooldownStarts(label: "observed")
        try #require(controller.isInReinstallCooldown)
        let quiet = try await waitForMainActorCondition("no apply queued once the cooldown started") {
            !controller.applyScheduled
        }
        try #require(quiet)

        let appliesBefore = controller.applyCount
        let changesBefore = controller.observedChangeCount
        let other = fixture.worktrees[1].id
        try #require(fixture.state.selectedWorktreeIDs.contains(other) == false)
        fixture.state.devServerLists[other] = fixture.list(
            [fixture.server("api", .running, url: "http://localhost:4000")], id: other)
        let ran = try await waitForMainActorCondition("the change to be observed and its apply to run") {
            controller.observedChangeCount > changesBefore && !controller.applyScheduled
        }
        try #require(ran)
        #expect(controller.observedChangeCount == changesBefore + 1)
        #expect(controller.applyCount == appliesBefore)
        #expect(window.toolbar === kept)
        #expect(controller.isInReinstallCooldown)

        let repoID = fixture.repos[1].id
        fixture.state.repoFilter = repoID
        let applied = try await waitForMainActorCondition("the apply for a change the toolbar shows") {
            controller.applyCount > appliesBefore
        }
        try #require(applied)
        #expect(controller.appliedSnapshot?.filter.selected == repoID)
        #expect(window.toolbar === kept)
        #expect(controller.isInReinstallCooldown)
    }

    /// Replacements older than `replacementWindow` stop counting: after the
    /// cap's worth inside one window and a quiet spell, one more is put back
    /// at once instead of starting the cooldown.
    @Test func oneReplacementAfterAQuietSpellIsPutBackAtOnce() async throws {
        let dates = TestDateSource()
        let fixture = ToolbarFixture(
            label: "oneReplacementAfterAQuietSpellIsPutBackAtOnce",
            now: dates.provider, clock: EventDrivenTestClock())
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        try await fixture.replaceAndWaitForReinstall(
            times: MainToolbarController.maxReplacementsInWindow, label: "beforeQuiet")
        try #require(controller.isInReinstallCooldown == false)

        dates.advance(by: MainToolbarController.replacementWindow + 1)
        window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.afterQuiet")
        #expect(controller.isInReinstallCooldown == false)
        let back = try await waitForMainActorCondition("a replacement after a quiet spell to be put back") {
            window.toolbar === controller.toolbar
        }
        #expect(back)
    }

    /// Uninstalling takes the toolbar off for good: its own removal is not
    /// read as a replacement by the watch, and a later apply does not put it
    /// back either.
    @Test func uninstallTakesTheToolbarOffForGood() async throws {
        let fixture = ToolbarFixture(label: "uninstallTakesTheToolbarOffForGood")
        defer { fixture.tearDown() }
        try await fixture.ready()

        fixture.controller.uninstall()
        #expect(fixture.window.toolbar == nil)
        #expect(fixture.controller.isInstalled == false)
        // KVO reports synchronously, so a watch that took the removal for a
        // replacement would have queued an apply by now.
        #expect(fixture.controller.applyScheduled == false)

        // The apply runs, which is what makes its leaving the window without
        // a toolbar mean something.
        let appliesBefore = fixture.controller.applyCount
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(fixture.controller.applyCount == appliesBefore + 1)
        #expect(fixture.window.toolbar == nil)
    }

    /// Uninstalling lets go of the window and unhooks the split's collapse
    /// report; the split stays the controller's, as it is for the
    /// controller's whole life. A collapse of the split then reaches nothing:
    /// KVO reports it at once, and a report still wired would record the
    /// state. An install on a fresh window, the split moved into it, counts
    /// no replacement from the old one: with the date frozen and the cap's
    /// worth made before the uninstall, one more on the fresh window is put
    /// back at once rather than starting the cooldown. That install wires the
    /// report again and reads the collapse it missed.
    @Test func uninstallLetsGoOfTheWindowAndUnhooksTheSplit() async throws {
        let fixture = ToolbarFixture(
            label: "uninstallLetsGoOfTheWindowAndUnhooksTheSplit",
            now: TestDateSource().provider, clock: EventDrivenTestClock())
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        try await fixture.replaceAndWaitForReinstall(
            times: MainToolbarController.maxReplacementsInWindow, label: "beforeUninstall")
        let quiet = try await waitForMainActorCondition("no apply queued before the uninstall") {
            !controller.applyScheduled
        }
        try #require(quiet)

        controller.uninstall()
        #expect(controller.window == nil)
        #expect(controller.split === fixture.split)
        let reportUnhooked = fixture.split.onSidebarCollapsedChange == nil
        #expect(reportUnhooked)

        let split = fixture.split
        split.sidebarItem.isCollapsed = true
        let collapsed = try await waitForMainActorCondition("the split to collapse") {
            split.isSidebarCollapsed
        }
        try #require(collapsed)
        #expect(controller.sidebarCollapsed == false)
        #expect(controller.applyScheduled == false)

        let freshWindow = fixture.moveSplitToAFreshWindow()
        defer {
            controller.uninstall()
            ToolbarFixture.takeDown(freshWindow)
        }
        let appliesBefore = controller.applyCount
        controller.install(on: freshWindow)
        #expect(controller.window === freshWindow)
        #expect(controller.sidebarCollapsed)
        let reportRehooked = split.onSidebarCollapsedChange != nil
        #expect(reportRehooked)
        try #require(freshWindow.toolbar === controller.toolbar)
        let applied = try await waitForMainActorCondition("the fresh install's apply, with none queued after it") {
            controller.applyCount > appliesBefore && !controller.applyScheduled
        }
        try #require(applied)

        freshWindow.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.freshWindow")
        #expect(controller.isInReinstallCooldown == false)
        let back = try await waitForMainActorCondition("a replacement on the fresh window to be put back") {
            freshWindow.toolbar === controller.toolbar
        }
        #expect(back)
    }

    /// An install on another window while the toolbar is installed on one,
    /// as a split moved into another window makes when it appears there,
    /// uninstalls from the first: ours leaves that window, so one toolbar is
    /// never on two, and goes on the new one. The move clears the split's
    /// appear hook, so only the explicit install acts. The apply the install
    /// schedules leaves the first window without a toolbar.
    @Test func installOnAnotherWindowTakesTheToolbarOffTheFirst() async throws {
        let fixture = ToolbarFixture(label: "installOnAnotherWindowTakesTheToolbarOffTheFirst")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let first = fixture.window

        let second = fixture.moveSplitToAFreshWindow()
        defer {
            controller.uninstall()
            ToolbarFixture.takeDown(second)
        }
        try #require(controller.isInstalled)
        try #require(controller.window === first)
        try #require(first.toolbar === controller.toolbar)

        let appliesBefore = controller.applyCount
        controller.install(on: second)
        #expect(first.toolbar == nil)
        #expect(second.toolbar === controller.toolbar)
        #expect(controller.window === second)
        #expect(controller.isInstalled)

        let applied = try await waitForMainActorCondition("the second install's apply, with none queued after it") {
            controller.applyCount > appliesBefore && !controller.applyScheduled
        }
        try #require(applied)
        #expect(first.toolbar == nil)
        #expect(second.toolbar === controller.toolbar)
    }

    // MARK: - The update loop

    /// Applies that observation did not trigger each arm a registration of
    /// their own, and a one-shot registration cannot be cancelled. A later
    /// `AppState` change must still act once, through the newest
    /// registration, rather than once per registration left outstanding.
    ///
    /// The apply count alone cannot tell: the stale registrations' calls
    /// coalesce into the one queued apply. `observedChangeCount` counts the
    /// registrations that acted, and is what goes wrong without the
    /// generation check.
    @Test func oneObservedChangeActsOnce() async throws {
        let fixture = ToolbarFixture(label: "oneObservedChangeActsOnce")
        defer { fixture.tearDown() }
        try await fixture.ready()

        // Each collapse and expansion schedules an apply of its own, which
        // arms tracking again with no change observed.
        let collapses: [Bool] = [true, false, true, false]
        for collapsed in collapses {
            let before = fixture.controller.applyCount
            fixture.split.sidebarItem.isCollapsed = collapsed
            let applied = try await waitForMainActorCondition("the apply after collapsed = \(collapsed)") {
                fixture.controller.applyCount > before
            }
            try #require(applied)
        }
        let settled = try await waitForMainActorCondition("no apply queued after the collapses") {
            !fixture.controller.applyScheduled
        }
        try #require(settled)

        let changesBefore = fixture.controller.observedChangeCount
        let appliesBefore = fixture.controller.applyCount
        let repoID = fixture.repos[1].id
        fixture.state.repoFilter = repoID
        let applied = try await waitForMainActorCondition("the apply the filter change scheduled") {
            fixture.controller.applyCount > appliesBefore
        }
        try #require(applied)
        #expect(fixture.controller.observedChangeCount == changesBefore + 1)
        #expect(fixture.controller.applyCount == appliesBefore + 1)
        #expect(fixture.controller.appliedSnapshot?.filter.selected == repoID)
    }

    /// The snapshot reads the whole dev-server dictionary, so a list landing
    /// for a worktree other than the selected one is observed and queues an
    /// apply. That apply finds the snapshot, the collapse and the appearance
    /// as the toolbar shows them and does no layout or content work. It still
    /// re-arms the tracking: a change to the selected worktree's list is
    /// applied after it.
    @Test func anotherWorktreesServersDoNotReapply() async throws {
        let fixture = ToolbarFixture(label: "anotherWorktreesServersDoNotReapply")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller

        fixture.showServers(url: "http://localhost:3000")
        let shown = try await waitForMainActorCondition("the apply that shows the Servers item, with none queued") {
            controller.appliedSnapshot?.servers?.isRunning == true && !controller.applyScheduled
        }
        try #require(shown)

        let appliesBefore = controller.applyCount
        let changesBefore = controller.observedChangeCount
        let other = fixture.worktrees[1].id
        try #require(fixture.state.selectedWorktreeIDs.contains(other) == false)
        fixture.state.devServerLists[other] = fixture.list(
            [fixture.server("api", .running, url: "http://localhost:4000")], id: other)
        let ran = try await waitForMainActorCondition("the change to be observed and its apply to run") {
            controller.observedChangeCount > changesBefore && !controller.applyScheduled
        }
        try #require(ran)
        #expect(controller.observedChangeCount == changesBefore + 1)
        #expect(controller.applyCount == appliesBefore)

        fixture.showServers(url: nil)
        let applied = try await waitForMainActorCondition("the apply for the selected worktree's change") {
            controller.applyCount > appliesBefore
        }
        try #require(applied)
        #expect(controller.appliedSnapshot?.servers?.isRunning == false)
    }

    /// An apply asked for by anything but an observed change runs in full
    /// with nothing changed: a repeated install, as a second `viewDidAppear`
    /// makes, and `scheduleApply()`, through which the replacement and
    /// appearance watches, the cooldown's end and the filter menu's close
    /// all ask.
    @Test func requestedAppliesRunWithNothingChanged() async throws {
        let fixture = ToolbarFixture(label: "requestedAppliesRunWithNothingChanged")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller

        let beforeInstall = controller.applyCount
        controller.install(on: fixture.window)
        try #require(controller.applyScheduled)
        let installRan = try await waitForMainActorCondition("the apply a repeated install queued") {
            !controller.applyScheduled
        }
        try #require(installRan)
        #expect(controller.applyCount == beforeInstall + 1)

        let beforeRequest = controller.applyCount
        controller.scheduleApply()
        try #require(controller.applyScheduled)
        let requestRan = try await waitForMainActorCondition("the apply scheduleApply() queued") {
            !controller.applyScheduled
        }
        try #require(requestRan)
        #expect(controller.applyCount == beforeRequest + 1)
    }

    // MARK: - Content

    /// An apply that changes nothing sets nothing: the Transcript and Servers
    /// images are the same objects afterwards. A changed Transcript symbol
    /// does set a new image and tool tip.
    @Test func unchangedContentIsNotSetAgain() async throws {
        let fixture = ToolbarFixture(label: "unchangedContentIsNotSetAgain")
        defer { fixture.tearDown() }
        try await fixture.ready()

        fixture.showServers(url: "http://localhost:3000")
        fixture.showRemoteSession()
        var snapshot = MainToolbarSnapshot.make(from: fixture.state)
        let remote = try #require(snapshot.remote)
        try #require(remote.showsTranscript)
        fixture.controller.apply(snapshot)
        let transcript = try #require(fixture.controller.item(MainToolbarItemID.remoteTranscript))
        let servers = try #require(fixture.controller.item(MainToolbarItemID.servers))
        let transcriptImage = try #require(transcript.image)
        let serversImage = try #require(servers.image)
        let transcriptTip = transcript.toolTip

        fixture.controller.apply(snapshot)
        #expect(transcript.image === transcriptImage)
        #expect(servers.image === serversImage)
        #expect(transcript.toolTip == transcriptTip)

        snapshot.remote?.transcriptShown = !remote.transcriptShown
        let toggledHelp = try #require(snapshot.remote?.transcriptHelp)
        try #require(toggledHelp != remote.transcriptHelp)
        fixture.controller.apply(snapshot)
        let toggled = try #require(transcript.image)
        #expect(toggled !== transcriptImage)
        #expect(toggled.accessibilityDescription == toggledHelp)
        #expect(transcript.toolTip == toggledHelp)
        #expect(servers.image === serversImage)
    }

    // MARK: - Remote

    @Test func stopRoutesToTheConfirmation() async throws {
        let fixture = ToolbarFixture(label: "stopRoutesToTheConfirmation")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let selection = fixture.showRemoteSession()
        let snapshot = MainToolbarSnapshot.make(from: fixture.state)
        try #require(snapshot.remote?.showsStop == true)
        fixture.controller.apply(snapshot)
        let stop = try #require(fixture.controller.item(MainToolbarItemID.remoteStop))
        #expect(stop.toolTip == "Stop this remote session")
        #expect(stop.visibilityPriority == .high)

        let action = try #require(stop.action)
        let sent = NSApplication.shared.sendAction(action, to: stop.target, from: stop)
        #expect(sent)
        let expected: [RemoteSessionSelection] = [selection]
        #expect(fixture.stopRequests == expected)
    }

    /// The Transcript item runs the toggle for the selected session: a click
    /// hides the attached session's transcript, and a second shows it again.
    @Test func transcriptRoutesToTheToggle() async throws {
        let fixture = ToolbarFixture(label: "transcriptRoutesToTheToggle")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let selection = fixture.showRemoteSession()
        let snapshot = MainToolbarSnapshot.make(from: fixture.state)
        try #require(snapshot.remote?.showsTranscript == true)
        let shownBefore = fixture.state.remoteTranscriptPresentation(for: selection).showsPane
        try #require(shownBefore)
        fixture.controller.apply(snapshot)
        let transcript = try #require(fixture.controller.item(MainToolbarItemID.remoteTranscript))
        let action = try #require(transcript.action)

        let hid = NSApplication.shared.sendAction(action, to: transcript.target, from: transcript)
        #expect(hid)
        #expect(fixture.state.remoteTranscriptHiddenSelection == selection)
        let shownAfterHide = fixture.state.remoteTranscriptPresentation(for: selection).showsPane
        #expect(!shownAfterHide)

        let showed = NSApplication.shared.sendAction(action, to: transcript.target, from: transcript)
        #expect(showed)
        #expect(fixture.state.remoteTranscriptHiddenSelection == nil)
        let shownAfterShow = fixture.state.remoteTranscriptPresentation(for: selection).showsPane
        #expect(shownAfterShow)
    }

    // MARK: - Glyph ink

    /// The extent of what `image` draws, in points: the bounding box of the
    /// pixels whose alpha is above one half, with the image drawn at twice
    /// its size into a bitmap of its own. Nil when it draws nothing.
    @MainActor
    static func inkSize(of image: NSImage) -> NSSize? {
        let scale: CGFloat = 2
        let pixelsWide = Int((image.size.width * scale).rounded(.up))
        let pixelsHigh = Int((image.size.height * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        // The context counts in pixels, so the image fills the bitmap at
        // twice its size.
        let pixels = NSRect(x: 0, y: 0, width: CGFloat(pixelsWide), height: CGFloat(pixelsHigh))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: pixels, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var minX = pixelsWide
        var minY = pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    // MARK: - Menu projections

    /// The filter rows' titles, "-" for a separator.
    static func describeFilterRows(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// The submenu of the filter item's current overflow row.
    static func filterOverflowRows(of controller: MainToolbarController) -> NSMenu? {
        controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation?.submenu
    }

    /// The titles of the rows carrying a check.
    static func checkedTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { $0.state == .on }.map(\.title)
    }

    /// A Servers menu row as text: kind, title, enablement and command.
    private static func describeRow(_ row: NSMenuItem) -> String {
        if row.isSeparatorItem { return "separator" }
        if row.isSectionHeader { return "header:\(row.title)" }
        let command = (row.representedObject as? ServersMenuCommandBox).map { "\($0.command)" } ?? "none"
        return "item:\(row.title):\(row.isEnabled):\(command)"
    }

    /// The row `entry` should become, in `describeRow`'s terms: a note is a
    /// disabled row with no command.
    private static func describeEntry(_ entry: ServersMenuEntry) -> String {
        switch entry {
        case .separator:
            return "separator"
        case .header(let title):
            return "header:\(title)"
        case .note(let text):
            return "item:\(text):false:none"
        case .item(let title, let isEnabled, let command):
            return "item:\(title):\(isEnabled):\(command)"
        }
    }
}

// MARK: - Fixture

/// An `AppState`, a split of plain panes, and a toolbar controller, mounted on
/// a titled window far off every display and ordered front.
///
/// The split's `onViewDidAppear` installs the toolbar, as the app wires it.
/// `isReleasedWhenClosed` is set to `false` once and the window is never
/// closed, so the flag is never flipped on the way out — see
/// `OffscreenHostLifecycleTests`.
@MainActor
private final class ToolbarFixture {
    static let windowSize = NSSize(width: 1200, height: 800)
    static let offscreenOrigin = NSPoint(x: -20_000, y: -20_000)

    let suite: TestDefaultsSuite
    let state: AppState
    let repos: [Repo]
    let worktrees: [Worktree]
    let split: MainSplitViewController
    let titleView: NSTextField
    let controller: MainToolbarController
    let window: NSWindow
    var stopRequests: [RemoteSessionSelection] = []

    /// - Parameters:
    ///   - nested: puts the split inside a plain container controller, which
    ///     is the window's `contentViewController`, instead of making the
    ///     split the content itself.
    ///   - now: the controller's date seam, which times its replacements.
    ///   - clock: the controller's clock, which times its re-install cooldown.
    init(
        label: String, nested: Bool = false, now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        _ = NSApplication.shared
        let suite = TestDefaultsSuite("MainToolbarControllerTests.\(label)")
        self.suite = suite
        let state = AppState(userDefaults: suite.defaults)
        let first = Repo(path: "/tmp/acme", displayName: "acme")
        let second = Repo(path: "/tmp/widgets", displayName: "widgets")
        let worktrees = [
            Worktree(repoID: first.id, name: "main", displayName: "main", branch: "main",
                     path: "/tmp/acme", status: .main, tmuxServer: "acme"),
            Worktree(repoID: first.id, name: "feature", displayName: "feature", branch: "feature",
                     path: "/tmp/acme-feature", tmuxServer: "acme"),
        ]
        state.repos = [first, second]
        state.worktrees = [first.id: worktrees]
        self.state = state
        repos = [first, second]
        self.worktrees = worktrees

        let split = ToolbarFixture.makeSplit()
        let titleView = NSTextField(labelWithString: "feature")
        let controller = MainToolbarController(
            appState: state, split: split, titleView: titleView, requestRemoteStop: { _ in },
            now: now, clock: clock)
        split.onViewDidAppear = { [weak controller] window in
            controller?.install(on: window)
        }
        self.split = split
        self.titleView = titleView
        self.controller = controller

        let window = ToolbarFixture.makeWindow()
        self.window = window

        controller.requestRemoteStop = { [weak self] selection in
            self?.stopRequests.append(selection)
        }

        ToolbarFixture.show(split, in: window, nested: nested)
    }

    /// A split of plain panes, the sidebar at its widest, so the leading
    /// section's fit is not what these tests measure; the minimum width is
    /// the live check's.
    static func makeSplit() -> MainSplitViewController {
        let sidebarWidth = MainToolbarMetrics.sidebarMaximumThickness
        return MainSplitViewController(
            sidebar: makePane(width: sidebarWidth),
            content: makePane(width: windowSize.width - sidebarWidth),
            autosaveName: nil)
    }

    /// A titled window at the far-off origin, which its owner never closes.
    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: offscreenOrigin, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Makes `split` the window's content, itself or inside a plain
    /// container, and orders the window front, which is when the split's
    /// `viewDidAppear` runs.
    static func show(_ split: MainSplitViewController, in window: NSWindow, nested: Bool) {
        let size = windowSize
        // The window takes its first size from the view; start it at the
        // final one so no transient narrow layout happens on the way.
        split.view.setFrameSize(size)
        if nested {
            let container = NSViewController()
            container.view = NSView(frame: NSRect(origin: .zero, size: size))
            container.addChild(split)
            split.view.frame = container.view.bounds
            split.view.autoresizingMask = [.width, .height]
            container.view.addSubview(split.view)
            window.contentViewController = container
        } else {
            window.contentViewController = split
        }
        window.setContentSize(size)
        window.setFrameOrigin(offscreenOrigin)
        window.orderFront(nil)
    }

    /// Moves the split out of the fixture's window, which is left with an
    /// empty content view, into a fresh window shown as the fixture's is, and
    /// returns that window. The split installs nothing as it appears there.
    /// The caller uninstalls whatever controller it gave the window before
    /// `takeDown(_:)`.
    func moveSplitToAFreshWindow() -> NSWindow {
        split.onViewDidAppear = nil
        window.contentViewController = nil
        window.contentView = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        split.removeFromParent()
        let fresh = Self.makeWindow()
        Self.show(split, in: fresh, nested: false)
        return fresh
    }

    /// Orders `window` out and empties it.
    static func takeDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.toolbar = nil
        window.contentViewController = nil
    }

    /// Installs the toolbar directly as well, so only `installsOnAppear`
    /// depends on `viewDidAppear` arriving, then waits for the first apply
    /// and for no further apply to be queued, so a test starts with nothing
    /// pending that could stand in for the trigger it is about.
    func ready() async throws {
        controller.install(on: window)
        let controller = self.controller
        let window = self.window
        let applied = try await waitForMainActorCondition("the first apply, with none queued after it") {
            controller.appliedSnapshot != nil && window.toolbar === controller.toolbar
                && !controller.applyScheduled
        }
        try #require(applied)
    }

    /// Replaces the toolbar `count` times, waiting each time for the
    /// controller to put it back.
    func replaceAndWaitForReinstall(times count: Int, label: String) async throws {
        try #require(count > 0)
        let controller = self.controller
        let window = self.window
        for attempt in 1...count {
            window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.\(label).\(attempt)")
            let back = try await waitForMainActorCondition("re-install \(attempt) of \(count) (\(label))") {
                window.toolbar === controller.toolbar
            }
            try #require(back)
        }
    }

    /// Replaces the toolbar `maxReplacementsInWindow` times, each put back,
    /// then once more with no apply queued, and returns that last
    /// replacement, the one the cooldown leaves on the window. The date seam
    /// must be frozen, so every replacement is inside one window.
    func replaceUntilTheCooldownStarts(label: String) async throws -> NSToolbar {
        try await replaceAndWaitForReinstall(times: MainToolbarController.maxReplacementsInWindow, label: label)
        let controller = self.controller
        let quiet = try await waitForMainActorCondition("no apply queued before the replacement past the cap") {
            !controller.applyScheduled
        }
        try #require(quiet)
        try #require(controller.isInReinstallCooldown == false)
        let kept = NSToolbar(identifier: "MainToolbarControllerTests.\(label).kept")
        window.toolbar = kept
        return kept
    }

    /// Uninstalls first, so the controller's watch on `window.toolbar` does
    /// not put back the toolbar the lines after it take off.
    func tearDown() {
        split.onViewDidAppear = nil
        controller.uninstall()
        ToolbarFixture.takeDown(window)
        suite.tearDown()
    }

    var identifiers: [NSToolbarItem.Identifier] {
        controller.toolbar.items.map(\.itemIdentifier)
    }

    func expectedIdentifiers() -> [NSToolbarItem.Identifier] {
        let snapshot = MainToolbarSnapshot.make(from: state)
        return MainToolbarLayout.identifiers(for: snapshot.layoutState(sidebarCollapsed: split.isSidebarCollapsed))
    }

    var filterPopup: NSPopUpButton? {
        controller.item(MainToolbarItemID.repoFilter)?.view as? NSPopUpButton
    }

    // MARK: Placement

    /// The identifiers of the items AppKit shows, leaving out any it dropped.
    var visibleIdentifiers: Set<NSToolbarItem.Identifier> {
        Set((controller.toolbar.visibleItems ?? []).map(\.itemIdentifier))
    }

    /// Whether every item in `wanted` is visible.
    func showsAll(_ wanted: [NSToolbarItem.Identifier]) -> Bool {
        let visible = visibleIdentifiers
        return wanted.allSatisfy { visible.contains($0) }
    }

    /// Whether `leading` opens the toolbar's items, all of it ahead of the
    /// tracking separator.
    func leadsBeforeTheSeparator(_ leading: [NSToolbarItem.Identifier]) -> Bool {
        let ids = identifiers
        guard let separator = ids.firstIndex(of: MainToolbarItemID.sidebarSeparator) else { return false }
        return Array(ids.prefix(leading.count)) == leading && leading.count <= separator
    }

    /// The sidebar's pane as the split arranges it. The first divider, which
    /// the tracking separator follows, sits at its trailing edge.
    var sidebarPane: NSView? {
        split.splitView.arrangedSubviews.first
    }

    /// The toolbar's public frames after a layout pass, or nil until the
    /// window has a zoom button, the split a sidebar pane, and the toggle,
    /// the arrows and the title view a place in the window.
    func edges() -> ToolbarEdges? {
        window.layoutIfNeeded()
        let leadingIDs: [NSToolbarItem.Identifier] = [
            MainToolbarItemID.toggleSidebar, MainToolbarItemID.back, MainToolbarItemID.forward,
        ]
        let leading = leadingIDs.compactMap { identifier in
            controller.item(identifier)?.view.flatMap { Self.placedFrame(of: $0, in: window) }
        }
        guard let zoom = window.standardWindowButton(.zoomButton),
              let pane = sidebarPane,
              leading.count == leadingIDs.count,
              let title = Self.placedFrame(of: titleView, in: window) else { return nil }
        return ToolbarEdges(
            buttonsMaxX: zoom.convert(zoom.bounds, to: nil).maxX,
            dividerX: pane.convert(pane.bounds, to: nil).maxX,
            leading: leading,
            filter: filterPopup.flatMap { Self.placedFrame(of: $0, in: window) },
            title: title)
    }

    /// `view`'s frame in window coordinates, once it sits in `window` with a
    /// width.
    static func placedFrame(of view: NSView, in window: NSWindow) -> NSRect? {
        guard view.window === window, view.frame.width > 0 else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    /// The constants of `view`'s required, equal constraints on its own
    /// `attribute`, such as a fixed width.
    static func requiredConstants(of view: NSView, _ attribute: NSLayoutConstraint.Attribute) -> [CGFloat] {
        view.constraints
            .filter { constraint in
                constraint.firstItem === view && constraint.secondItem == nil
                    && constraint.firstAttribute == attribute && constraint.relation == .equal
                    && constraint.priority == .required
            }
            .map(\.constant)
    }

    // MARK: Overflow rows

    /// Whether `item` is one of TBD's own, which the overflow menu can show:
    /// not a standard space and not the tracking separator.
    static func hasOverflowRow(_ item: NSToolbarItem) -> Bool {
        MainToolbarItemID.custom.contains(item.itemIdentifier) && !(item is NSTrackingSeparatorToolbarItem)
    }

    /// What the overflow menu shows for `item`, as `NSToolbarItem.h`
    /// documents it: the item's menu form, with the item's label, target and
    /// action standing in for any the form lacks, as AppKit's default row
    /// carries them; and the rows of the form's submenu, or, for an
    /// `NSMenuToolbarItem` whose form has none, of its menu, which is its
    /// form unless one is set. For a view item the target and action are
    /// its view's.
    static func overflowRow(of item: NSToolbarItem) -> OverflowRow {
        let form = item.menuFormRepresentation
        let title = form?.title ?? item.label
        // A row with a submenu only opens it: AppKit gives it
        // `submenuAction:`, which is never sent, and it stands in for no
        // item action. Its submenu's rows are what act.
        if let submenu = form?.submenu {
            return OverflowRow(title: title, target: nil, action: nil, subrows: submenu.items)
        }
        let ownAction = form?.action
        return OverflowRow(
            title: title,
            target: ownAction == nil ? item.target : form?.target,
            action: ownAction ?? item.action,
            subrows: (item as? NSMenuToolbarItem)?.menu.items ?? [])
    }

    /// The sender to send `row`'s action from: `row` itself, except for a
    /// Servers row carrying a command, which is sent from a bare menu item
    /// so that no server is started or stopped and no URL opened.
    static func harmlessSender(for row: NSMenuItem) -> NSMenuItem {
        guard row.representedObject is ServersMenuCommandBox else { return row }
        return NSMenuItem(title: row.title, action: row.action, keyEquivalent: "")
    }

    // MARK: State

    /// Selects the first worktree and gives it one server: running with
    /// `url`, or stopped without one.
    @discardableResult
    func showServers(url: String?) -> DevServerListResult {
        let worktreeID = worktrees[0].id
        let running = url.map { server("web", .running, url: $0) } ?? server("web", .stopped)
        let result = list([running], id: worktreeID)
        state.devServerLists[worktreeID] = result
        state.selectedWorktreeIDs = [worktreeID]
        return result
    }

    /// Selects and attaches a running remote session whose provider attaches
    /// and reads transcripts, so the snapshot shows Transcript, Reconnect and
    /// Stop: the Transcript toggle is offered only while attached. Attached
    /// the way the Attach button does it: select, then request the connection.
    @discardableResult
    func showRemoteSession() -> RemoteSessionSelection {
        let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
        let capabilities: [String] = ["attach", RemoteCapability.transcriptRead]
        state.remoteProviders = [RemoteProviderStatus(
            config: RemoteProviderConfig(name: "acme", exec: "/bin/acme"),
            describe: ProviderDescribe(name: "acme", capabilities: capabilities),
            health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)]
        state.remoteSessions = [RemoteSessionInfo(
            provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
            gone: false, dismissed: false, lastSeen: Date())]
        state.selectedRemoteSession = selection
        state.reattachRemoteSession(selection)
        return selection
    }

    func server(_ name: String, _ state: DevServerStateKind, url: String? = nil) -> DevServerInfo {
        DevServerInfo(name: name, label: name, source: "tbd.toml", state: state, exitCode: nil,
                      endpoints: url.map { [DevServerEndpoint(name: "app", url: $0)] } ?? [],
                      terminalID: nil, pid: nil, hasStopCommand: false,
                      stateFromStatusCommand: nil, hasStatusCommand: true, exitedTab: nil)
    }

    func list(_ servers: [DevServerInfo], id: UUID) -> DevServerListResult {
        DevServerListResult(worktreeID: id, servers: servers, parseErrors: [], runningFileDiagnostics: [])
    }

    /// A plain view controller over a sized, empty view.
    private static func makePane(width: CGFloat) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: windowSize.height))
        return controller
    }
}

/// Where the toolbar's parts sit, in window coordinates: the window buttons'
/// trailing edge, the divider the tracking separator follows, and the view
/// items' frames.
private struct ToolbarEdges {
    /// The zoom button's trailing edge, where the window buttons end.
    var buttonsMaxX: CGFloat
    /// The sidebar pane's trailing edge, where the first divider sits.
    var dividerX: CGFloat
    /// The toggle, back and forward buttons, in toolbar order.
    var leading: [NSRect]
    /// The filter popup, while it is in the toolbar and laid out.
    var filter: NSRect?
    var title: NSRect

    /// Whether the toggle and arrows sit right of the window buttons, left to
    /// right without overlapping, and end at or before `next`, where the item
    /// after them starts.
    func leadingPlaced(before next: CGFloat) -> Bool {
        guard let first = leading.first, let last = leading.last else { return false }
        let inOrder = zip(leading, leading.dropFirst()).allSatisfy { pair in pair.0.maxX <= pair.1.minX }
        return buttonsMaxX <= first.minX && inOrder && last.maxX <= next
    }

    /// The sidebar shown: the toggle and arrows right of the window buttons,
    /// then the filter, left of the divider, and the title right of it.
    var placedOverAShownSidebar: Bool {
        guard let filter else { return false }
        return leadingPlaced(before: filter.minX) && filter.maxX <= dividerX && dividerX <= title.minX
    }

    /// The sidebar collapsed: the toggle and arrows right of the window
    /// buttons, then the title, left of `shownDividerX`, where the shown
    /// sidebar ended.
    func placedBesideTheWindowButtons(shownDividerX: CGFloat) -> Bool {
        leadingPlaced(before: title.minX) && title.minX < shownDividerX
    }
}

/// What the overflow menu shows for one toolbar item: its row's title,
/// target and action, and the rows of its submenu.
private struct OverflowRow {
    var title: String
    var target: AnyObject?
    var action: Selector?
    var subrows: [NSMenuItem]
}

/// The title view's own width constraints, found by their identifiers: each
/// one's identifier, relation, priority and constant, in identifier order.
private struct TitleWidthConstraints: Equatable {
    struct Entry: Equatable {
        var identifier: String
        var relation: NSLayoutConstraint.Relation
        var priority: Float
        var constant: CGFloat
    }

    var entries: [Entry]

    @MainActor
    init(of view: NSView) {
        let identifiers: Set<String> = [
            MainToolbarController.titleMinimumWidthID, MainToolbarController.titleMaximumWidthID,
            MainToolbarController.titleFillWidthID,
        ]
        entries = view.constraints
            .filter { constraint in
                constraint.identifier.map { identifiers.contains($0) } ?? false
                    && constraint.firstItem === view && constraint.secondItem == nil
                    && constraint.firstAttribute == .width
            }
            .map { constraint in
                Entry(identifier: constraint.identifier ?? "", relation: constraint.relation,
                      priority: constraint.priority.rawValue, constant: constraint.constant)
            }
            .sorted { $0.identifier < $1.identifier }
    }

    /// One of each: the fill at the maximum and its low priority, the
    /// required maximum, and the required minimum.
    @MainActor
    var isTheFlexibleSet: Bool {
        let required = NSLayoutConstraint.Priority.required.rawValue
        let expected: [Entry] = [
            Entry(identifier: MainToolbarController.titleFillWidthID, relation: .equal,
                  priority: MainToolbarController.titleFillPriority.rawValue,
                  constant: MainToolbarMetrics.titleMaximumWidth),
            Entry(identifier: MainToolbarController.titleMaximumWidthID, relation: .lessThanOrEqual,
                  priority: required, constant: MainToolbarMetrics.titleMaximumWidth),
            Entry(identifier: MainToolbarController.titleMinimumWidthID, relation: .greaterThanOrEqual,
                  priority: required, constant: MainToolbarMetrics.titleMinimumWidth),
        ]
        return entries == expected
    }
}

/// A leading glyph whose ink lies outside the reference's tolerance, as the
/// error its issue records, so the summary carries its ink and image sizes.
private struct GlyphSizeOutsideReference: Error, CustomStringConvertible {
    let symbol: String
    let ink: NSSize
    let image: NSSize
    let reference: NSSize
    let tolerance: CGFloat

    var description: String {
        "\(symbol) draws \(ink.width) × \(ink.height) pt of ink in a \(image.width) × \(image.height) pt "
            + "image, outside ±\(tolerance) pt of the reference \(reference.width) × \(reference.height) pt"
    }
}
