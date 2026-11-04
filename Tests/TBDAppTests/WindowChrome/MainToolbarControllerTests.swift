import AppKit
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 2: the toolbar on a real offscreen window. Waits are bounded
// (`pollUntilTrue`), and the cooldown tests drive an `EventDrivenTestClock`.

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
        fixture.showRemoteSession()
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))

        let identifiers = fixture.identifiers
        let allowed = Set(MainToolbarItemID.allowed)
        let stray = identifiers.filter { !allowed.contains($0) }
        #expect(identifiers.contains(MainToolbarItemID.remoteStop))
        #expect(stray.isEmpty)
        #expect(fixture.window.toolbar?.delegate === fixture.controller)
    }

    // MARK: - Collapse

    /// The leading item, holding the toggle and the arrows, leads the
    /// toolbar, ahead of the tracking separator, and stays visible beside the
    /// window buttons with the sidebar shown, collapsed and shown again.
    ///
    /// - **Position.** Every item here is a view item, so each is checked
    ///   by its frame in window coordinates against the zoom button and the
    ///   divider the separator tracks, as well as by order: the leading item
    ///   opens `toolbar.items`, before the separator. Shown, it sits right of
    ///   the zoom button at its full width, then the filter left of the
    ///   divider, and the title right of it. Collapsed, it still sits right of
    ///   the zoom button, and the title after it and left of where the shown
    ///   sidebar ended, so the toolbar followed the collapse, which a stale
    ///   sidebar section would fail.
    @Test func leadingButtonsSurviveACollapse() async throws {
        let fixture = ToolbarFixture(label: "leadingButtonsSurviveACollapse")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let host = try #require(fixture.leadingHost)
        let toggleButton = try #require(host.toggleButton)
        let toggleTargetsTheSplit = toggleButton.target === fixture.split
        #expect(toggleTargetsTheSplit)
        #expect(toggleButton.action == #selector(NSSplitViewController.toggleSidebar(_:)))
        let leading: [NSToolbarItem.Identifier] = [MainToolbarItemID.leadingButtons]
        let leadingWidth: CGFloat = MainToolbarMetrics.leadingButtonsWidth

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
        #expect(shown.leading.width == leadingWidth)
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
        #expect(collapsed.leading.width == leadingWidth)
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
        #expect(reshown.leading.width == leadingWidth)
        #expect(reshownFilter.maxX <= reshown.dividerX)
        #expect(reshown.dividerX <= reshown.title.minX)

        // No `visibleItems` drop control: narrowing the sidebar does not take
        // in the offscreen harness, so no item can be made to drop. The test
        // pins placement through the view items' frames and the order instead.
    }

    // MARK: - Leading buttons

    /// The toggle, back and forward are three buttons in one item, whose view
    /// is a `LeadingToolbarButtonsHost`: the structure that keeps Liquid Glass
    /// off them and puts them one pitch apart. A bordered button as an item's
    /// view makes the item bordered, which gives it glass, so the item is not
    /// bordered and its view answers none of the selectors an item forwards
    /// to its view (`isBordered`, `isEnabled`, `target`, `action` and
    /// `image`, getters and setters). The item does not autovalidate, is not
    /// navigational, keeps no target or action, and is enabled.
    ///
    /// The host holds three pitches by one button's height, 84 × 28 pt, by
    /// required constraints found by their identifiers, and its fitting size
    /// is that. Required constraints chain its buttons from its leading edge
    /// to its trailing edge and pin each to its top and bottom, and each
    /// button holds one pitch by a required width constraint, so once laid
    /// out the buttons tile the host at 0, 28 and 56 pt, each 28 × 28 pt.
    /// Each button is a borderless `ToolbarIconButton`, which draws its hover
    /// square over its whole frame, image-only, untitled and unscaled, with
    /// its identifier, tool tip, accessibility label and glyph description,
    /// and its target and action.
    ///
    /// The overflow row is "Navigation", with a submenu that does not
    /// autoenable, of a row per button carrying the button's target and
    /// action.
    @Test func leadingButtonsShareOneUnborderedItem() async throws {
        let fixture = ToolbarFixture(label: "leadingButtonsShareOneUnborderedItem")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let item = try #require(controller.item(MainToolbarItemID.leadingButtons))
        let host = try #require(item.view as? LeadingToolbarButtonsHost)

        // What keeps the glass off: an unbordered item over a view that
        // forwards nothing.
        #expect(item.isBordered == false)
        let answered = ToolbarFixture.answeredForwardedSelectors(of: host)
        #expect(answered.isEmpty, "the host answers \(answered)")
        #expect(item.autovalidates == false)
        #expect(item.isNavigational == false)
        #expect(item.isEnabled)
        let itemHasNoTarget = item.target == nil
        #expect(itemHasNoTarget)
        #expect(item.action == nil)
        #expect(item.label == "Navigation")
        #expect(host.translatesAutoresizingMaskIntoConstraints == false)

        // The host's size.
        let leadingSize = NSSize(width: MainToolbarMetrics.leadingButtonsWidth, height: MainToolbarMetrics.iconButtonHeight)
        let widths = ToolbarFixture.constraints(of: host, identified: LeadingToolbarButtonsHost.widthID)
        let heights = ToolbarFixture.constraints(of: host, identified: LeadingToolbarButtonsHost.heightID)
        try #require(widths.count == 1)
        try #require(heights.count == 1)
        let width = widths[0]
        let height = heights[0]
        let widthOnHost = width.firstItem === host
        #expect(widthOnHost)
        #expect(width.firstAttribute == .width)
        #expect(width.relation == .equal)
        #expect(width.priority == .required)
        #expect(width.constant == 84)
        let heightOnHost = height.firstItem === host
        #expect(heightOnHost)
        #expect(height.firstAttribute == .height)
        #expect(height.relation == .equal)
        #expect(height.priority == .required)
        #expect(height.constant == 28)
        #expect(host.fittingSize == leadingSize)

        // Its buttons, tiling it.
        let buttons = try ToolbarFixture.buttons(of: host)
        let missingPins = ToolbarFixture.missingTilePins(of: buttons, in: host)
        #expect(missingPins.isEmpty, "the host lacks the pins \(missingPins)")
        host.layoutSubtreeIfNeeded()
        let frames = buttons.map { $0.frame }
        let expectedFrames: [NSRect] = [
            NSRect(x: 0, y: 0, width: 28, height: 28),
            NSRect(x: 28, y: 0, width: 28, height: 28),
            NSRect(x: 56, y: 0, width: 28, height: 28),
        ]
        #expect(frames == expectedFrames)

        let expected: [(NSUserInterfaceItemIdentifier, String, String, AnyObject?, Selector)] = [
            (LeadingToolbarButtonsHost.toggleID, "Toggle Sidebar", "Toggle Sidebar", fixture.split,
             #selector(NSSplitViewController.toggleSidebar(_:))),
            (LeadingToolbarButtonsHost.backID, "Back", "Back (⌘[)", controller,
             #selector(MainToolbarController.navigateBack(_:))),
            (LeadingToolbarButtonsHost.forwardID, "Forward", "Forward (⌘])", controller,
             #selector(MainToolbarController.navigateForward(_:))),
        ]
        for (button, (identifier, tip, help, target, action)) in zip(buttons, expected) {
            let inHost = button.superview === host
            #expect(inHost)
            #expect(button.identifier == identifier)
            #expect(button.toolTip == help)
            #expect(button.accessibilityLabel() == tip)
            #expect(button.image?.accessibilityDescription == tip)
            let isIconButton = button is ToolbarIconButton
            #expect(isIconButton, "\(tip) is a \(type(of: button))")
            #expect(button.isBordered == false)
            #expect(button.imagePosition == .imageOnly)
            #expect(button.imageScaling == .scaleNone)
            #expect(button.title.isEmpty)
            let wired = button.target === target
            #expect(wired, "\(tip) targets \(String(describing: button.target))")
            #expect(button.action == action)
            #expect(button.translatesAutoresizingMaskIntoConstraints == false)
            let buttonWidths = ToolbarFixture.constraints(of: button, identified: LeadingToolbarButtonsHost.buttonWidthID)
            try #require(buttonWidths.count == 1)
            #expect(buttonWidths[0].constant == MainToolbarMetrics.iconButtonPitch)
            #expect(buttonWidths[0].relation == .equal)
            #expect(buttonWidths[0].priority == .required)
        }

        // Its overflow row: "Navigation", with a row per button.
        let form = try #require(item.menuFormRepresentation)
        #expect(form.title == "Navigation")
        #expect(form.hasSubmenu)
        let submenu = try #require(form.submenu)
        #expect(submenu.autoenablesItems == false)
        let rowTitles = submenu.items.map { $0.title }
        let expectedRowTitles: [String] = ["Toggle Sidebar", "Back", "Forward"]
        #expect(rowTitles == expectedRowTitles)
        let rows = try ToolbarFixture.navigationRows(of: item)
        for (row, (_, tip, _, target, action)) in zip(rows, expected) {
            let wired = row.target === target
            #expect(wired, "the \(tip) row targets \(String(describing: row.target))")
            #expect(row.action == action)
        }

        let lead: [NSToolbarItem.Identifier] = [MainToolbarItemID.leadingButtons]
        #expect(fixture.leadsBeforeTheSeparator(lead))
    }

    /// The leading item survives AppKit's copy, which archives the item's
    /// view and unarchives the copy's, so the host decodes rather than
    /// trapping. The copy is still unbordered, over a new
    /// `LeadingToolbarButtonsHost` that answers none of the forwarded
    /// selectors, whose three buttons come back as new subviews, found by
    /// their identifiers, still borderless `ToolbarIconButton`s, carrying the
    /// originals' glyphs and actions, and still tiling the host, with the
    /// host at its size: the constraints are archived with it. The buttons'
    /// targets are not compared: an archive keeps a target only when it
    /// archives the target too.
    ///
    /// The item is fresh from the delegate, as AppKit asks for one it will
    /// not insert, so no window state rides along in the archive.
    @Test func leadingItemSurvivesACopy() async throws {
        let fixture = ToolbarFixture(label: "leadingItemSurvivesACopy")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let leadingSize = NSSize(width: MainToolbarMetrics.leadingButtonsWidth, height: MainToolbarMetrics.iconButtonHeight)

        let made = controller.toolbar(
            controller.toolbar, itemForItemIdentifier: MainToolbarItemID.leadingButtons,
            willBeInsertedIntoToolbar: false)
        let original = try #require(made)
        let originalHost = try #require(original.view as? LeadingToolbarButtonsHost)
        let originalButtons = try ToolbarFixture.buttons(of: originalHost)

        let copied = try #require(original.copy() as? NSToolbarItem)
        let host = try #require(copied.view as? LeadingToolbarButtonsHost)
        let buttons = try ToolbarFixture.buttons(of: host)
        let hostIsNew = host !== originalHost
        #expect(hostIsNew)
        #expect(copied.itemIdentifier == MainToolbarItemID.leadingButtons)
        #expect(copied.isBordered == false)
        let answered = ToolbarFixture.answeredForwardedSelectors(of: host)
        #expect(answered.isEmpty, "the copied host answers \(answered)")
        for (button, originalButton) in zip(buttons, originalButtons) {
            let buttonIsNew = button !== originalButton
            #expect(buttonIsNew)
            let isIconButton = button is ToolbarIconButton
            #expect(isIconButton, "a copied button is a \(type(of: button))")
            #expect(button.isBordered == false)
            let glyphDescription = button.image?.accessibilityDescription
            #expect(glyphDescription == originalButton.image?.accessibilityDescription)
            #expect(button.action == originalButton.action)
        }

        let missingPins = ToolbarFixture.missingTilePins(of: buttons, in: host)
        #expect(missingPins.isEmpty, "the copied host lacks the pins \(missingPins)")
        let widths = ToolbarFixture.constraints(of: host, identified: LeadingToolbarButtonsHost.widthID)
        let heights = ToolbarFixture.constraints(of: host, identified: LeadingToolbarButtonsHost.heightID)
        #expect(widths.count == 1)
        #expect(heights.count == 1)
        #expect(host.fittingSize == leadingSize)
        #expect(copied.menuFormRepresentation != nil)
    }

    /// Each leading glyph, as its button carries it, against the size the
    /// same glyph draws at in a macOS 27 toolbar: about 16 by 13 pt for the
    /// sidebar toggle and 6 by 11 pt for each chevron. The image's own size
    /// includes the symbol's padding, so what is compared is its ink: the
    /// extent of what it draws (`inkSize(of:)`). A glyph outside the
    /// tolerance records its image and ink sizes, so the failure carries the
    /// real numbers. The button does not scale its image, so the image must
    /// also fit the button's width.
    @Test func leadingGlyphsMatchTheReferenceSizes() async throws {
        let fixture = ToolbarFixture(label: "leadingGlyphsMatchTheReferenceSizes")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let tolerance: CGFloat = 2
        let host = try #require(fixture.leadingHost)
        let buttons = try ToolbarFixture.buttons(of: host)
        let references: [(String, NSSize)] = [
            ("sidebar.left", NSSize(width: 16, height: 13)),
            ("chevron.left", NSSize(width: 6, height: 11)),
            ("chevron.right", NSSize(width: 6, height: 11)),
        ]
        for (button, (symbol, reference)) in zip(buttons, references) {
            #expect(button.imageScaling == .scaleNone)
            let glyph = try #require(button.image)
            let imageSize = glyph.size
            #expect(imageSize.width <= MainToolbarMetrics.iconButtonPitch)
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

    /// The leading item made by the delegate, before any apply, has its
    /// toggle enabled and Back and Forward disabled, buttons and overflow
    /// rows alike, while the item itself is enabled. Each apply then sets the
    /// Back and Forward buttons and rows from the snapshot, leaving the
    /// toggle and the item enabled. A row disabled directly while its button
    /// is enabled comes back on the next apply that enables Back, though the
    /// button already shows that value: the apply compares the row as well
    /// as the button.
    @Test func backForwardEnablementFollowsTheSnapshot() async throws {
        let fixture = ToolbarFixture(label: "backForwardEnablementFollowsTheSnapshot")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller

        let made = controller.toolbar(
            controller.toolbar, itemForItemIdentifier: MainToolbarItemID.leadingButtons,
            willBeInsertedIntoToolbar: false)
        let fresh = try #require(made)
        let atStart = try ToolbarFixture.enablement(of: fresh)
        let expectedAtStart = LeadingEnablement(item: true, buttons: [true, false, false], rows: [true, false, false])
        #expect(atStart == expectedAtStart)

        var snapshot = MainToolbarSnapshot.make(from: fixture.state)
        snapshot.canGoBack = true
        snapshot.canGoForward = false
        controller.apply(snapshot)
        let item = try #require(controller.item(MainToolbarItemID.leadingButtons))
        let backOnly = try ToolbarFixture.enablement(of: item)
        let expectedBackOnly = LeadingEnablement(item: true, buttons: [true, true, false], rows: [true, true, false])
        #expect(backOnly == expectedBackOnly)

        snapshot.canGoBack = false
        snapshot.canGoForward = true
        controller.apply(snapshot)
        let forwardOnly = try ToolbarFixture.enablement(of: item)
        let expectedForwardOnly = LeadingEnablement(
            item: true, buttons: [true, false, true], rows: [true, false, true])
        #expect(forwardOnly == expectedForwardOnly)

        snapshot.canGoBack = true
        controller.apply(snapshot)
        let both = try ToolbarFixture.enablement(of: item)
        let expectedBoth = LeadingEnablement(item: true, buttons: [true, true, true], rows: [true, true, true])
        try #require(both == expectedBoth)
        let backRow = try ToolbarFixture.navigationRows(of: item)[1]
        backRow.isEnabled = false
        controller.apply(snapshot)
        let restored = try ToolbarFixture.enablement(of: item)
        #expect(restored == expectedBoth)
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
        let item = try #require(controller.item(MainToolbarItemID.leadingButtons))
        let rows = try ToolbarFixture.navigationRows(of: item)
        let backRow = rows[1]
        let forwardRow = rows[2]

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

    /// The repo filter is one borderless `ToolbarIconButton` in a
    /// `FilterToolbarButtonHost`, the structure that keeps Liquid Glass off
    /// it, as for the leading item: the item is not bordered and its view
    /// answers none of the selectors an item forwards to its view. The item
    /// does not autovalidate, keeps no target, action or tool tip, and is
    /// enabled.
    ///
    /// The host holds one pitch by one button's height, 28 × 28 pt, by
    /// required constraints found by their identifiers, and its fitting size
    /// is that; its button fills it, by the pins that tile the leading host.
    /// The button is image-only, untitled and unscaled, and shows
    /// `line.3.horizontal.decrease` at the leading buttons' configuration:
    /// its image is the size of that symbol at 13 pt, regular weight and
    /// medium scale, and fits the pitch. It carries "Filter" as its glyph's
    /// description and its accessibility label, and the controller as the
    /// target of `filterButtonClicked(_:)`. The host is not an accessibility
    /// element, so VoiceOver lands on the button.
    @Test func filterIsOneIconButtonInAnUnborderedItem() async throws {
        let fixture = ToolbarFixture(label: "filterIsOneIconButtonInAnUnborderedItem")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let item = try #require(controller.item(MainToolbarItemID.repoFilter))
        let host = try #require(item.view as? FilterToolbarButtonHost)

        // What keeps the glass off: an unbordered item over a view that
        // forwards nothing.
        #expect(item.isBordered == false)
        let answered = ToolbarFixture.answeredForwardedSelectors(of: host)
        #expect(answered.isEmpty, "the filter host answers \(answered)")
        #expect(item.autovalidates == false)
        #expect(item.isEnabled)
        let itemHasNoTarget = item.target == nil
        #expect(itemHasNoTarget)
        #expect(item.action == nil)
        #expect(item.toolTip == nil)
        #expect(item.label == "Filter")
        #expect(host.translatesAutoresizingMaskIntoConstraints == false)
        #expect(host.isAccessibilityElement() == false)

        // The host's size.
        let widths = ToolbarFixture.constraints(of: host, identified: FilterToolbarButtonHost.widthID)
        let heights = ToolbarFixture.constraints(of: host, identified: FilterToolbarButtonHost.heightID)
        try #require(widths.count == 1)
        try #require(heights.count == 1)
        #expect(widths[0].constant == 28)
        #expect(widths[0].relation == .equal)
        #expect(widths[0].priority == .required)
        #expect(heights[0].constant == 28)
        #expect(heights[0].relation == .equal)
        #expect(heights[0].priority == .required)
        let filterSize = NSSize(width: 28, height: 28)
        #expect(host.fittingSize == filterSize)

        // Its button, filling it.
        let button = try #require(host.button, "no filter button found by its identifier")
        let inHost = button.superview === host
        #expect(inHost)
        let isIconButton = button is ToolbarIconButton
        #expect(isIconButton, "the filter button is a \(type(of: button))")
        #expect(button.isBordered == false)
        let missingPins = ToolbarFixture.missingTilePins(of: [button], in: host)
        #expect(missingPins.isEmpty, "the filter host lacks the pins \(missingPins)")
        let buttonWidths = ToolbarFixture.constraints(of: button, identified: FilterToolbarButtonHost.buttonWidthID)
        try #require(buttonWidths.count == 1)
        #expect(buttonWidths[0].constant == MainToolbarMetrics.iconButtonPitch)
        #expect(buttonWidths[0].priority == .required)
        host.layoutSubtreeIfNeeded()
        let buttonFrame = button.frame
        let expectedFrame = NSRect(x: 0, y: 0, width: 28, height: 28)
        #expect(buttonFrame == expectedFrame)

        // Its glyph, at the leading buttons' configuration.
        #expect(button.imagePosition == .imageOnly)
        #expect(button.imageScaling == .scaleNone)
        #expect(button.title.isEmpty)
        let glyph = try #require(button.image)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: MainToolbarMetrics.iconGlyphPointSize, weight: .regular, scale: .medium)
        let symbol = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        let reference = try #require(symbol?.withSymbolConfiguration(configuration))
        let glyphSize = glyph.size
        let referenceSize = reference.size
        #expect(glyphSize == referenceSize)
        #expect(glyphSize.width <= MainToolbarMetrics.iconButtonPitch)
        #expect(glyph.accessibilityDescription == "Filter")
        #expect(button.accessibilityLabel() == "Filter")
        let wired = button.target === controller
        #expect(wired, "the filter button targets \(String(describing: button.target))")
        #expect(button.action == #selector(MainToolbarController.filterButtonClicked(_:)))
    }

    /// The filter item survives AppKit's copy, as the leading item does: its
    /// host decodes rather than trapping. The copy is still unbordered, over
    /// a new `FilterToolbarButtonHost` that answers none of the forwarded
    /// selectors, whose button comes back as a new borderless
    /// `ToolbarIconButton`, found by its identifier, carrying the original's
    /// glyph and action and still filling the host, with the host at its
    /// size. The item is fresh from the delegate, as AppKit asks for one it
    /// will not insert.
    @Test func filterItemSurvivesACopy() async throws {
        let fixture = ToolbarFixture(label: "filterItemSurvivesACopy")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller

        let made = controller.toolbar(
            controller.toolbar, itemForItemIdentifier: MainToolbarItemID.repoFilter,
            willBeInsertedIntoToolbar: false)
        let original = try #require(made)
        let originalHost = try #require(original.view as? FilterToolbarButtonHost)
        let originalButton = try #require(originalHost.button)

        let copied = try #require(original.copy() as? NSToolbarItem)
        let host = try #require(copied.view as? FilterToolbarButtonHost)
        let button = try #require(host.button, "no copied filter button found by its identifier")
        let hostIsNew = host !== originalHost
        #expect(hostIsNew)
        let buttonIsNew = button !== originalButton
        #expect(buttonIsNew)
        #expect(copied.itemIdentifier == MainToolbarItemID.repoFilter)
        #expect(copied.isBordered == false)
        let answered = ToolbarFixture.answeredForwardedSelectors(of: host)
        #expect(answered.isEmpty, "the copied filter host answers \(answered)")
        let isIconButton = button is ToolbarIconButton
        #expect(isIconButton, "the copied filter button is a \(type(of: button))")
        #expect(button.isBordered == false)
        let glyphDescription = button.image?.accessibilityDescription
        #expect(glyphDescription == originalButton.image?.accessibilityDescription)
        #expect(button.action == originalButton.action)

        let missingPins = ToolbarFixture.missingTilePins(of: [button], in: host)
        #expect(missingPins.isEmpty, "the copied filter host lacks the pins \(missingPins)")
        let widths = ToolbarFixture.constraints(of: host, identified: FilterToolbarButtonHost.widthID)
        let heights = ToolbarFixture.constraints(of: host, identified: FilterToolbarButtonHost.heightID)
        #expect(widths.count == 1)
        #expect(heights.count == 1)
        let filterSize = NSSize(width: 28, height: 28)
        #expect(host.fittingSize == filterSize)
        #expect(copied.menuFormRepresentation != nil)
    }

    /// The menu the filter button pops up, `filterMenu`, holds "All Repos",
    /// a separator and each repo, the current choice checked and no other,
    /// then a separator and the Show Hidden Repos row. Its rows stay enabled,
    /// its opening is reported to `filterMenuTracker`, and each repo row
    /// carries its repo's ID, or none for "All Repos", and chooses it through
    /// `filterChosen(_:)`: choosing one sets the filter, and the next apply
    /// checks it. A test cannot pop the menu up, which blocks in the menu's
    /// tracking loop, so this reads the menu the click pops up.
    @Test func filterMenuShowsAndSetsTheFilter() async throws {
        let fixture = ToolbarFixture(label: "filterMenuShowsAndSetsTheFilter")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let menu = controller.filterMenu
        let chooseAction = #selector(MainToolbarController.filterChosen(_:))

        fixture.state.repoFilter = fixture.repos[1].id
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let titles = Self.describeFilterRows(menu)
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets", "-", "Show Hidden Repos"]
        #expect(titles == expectedTitles)
        let checkedWidgets = Self.checkedTitles(menu)
        let expectedWidgets: [String] = ["widgets"]
        #expect(checkedWidgets == expectedWidgets)
        #expect(menu.autoenablesItems == false)
        let tracked = menu.delegate === controller.filterMenuTracker
        #expect(tracked)
        let rows = menu.items.filter { !$0.isSeparatorItem }
        let allEnabled = rows.allSatisfy { $0.isEnabled }
        #expect(allEnabled)

        let choosable = Self.repoRows(menu)
        try #require(choosable.count == 3)
        let ids = choosable.map { $0.representedObject as? UUID }
        let expectedIDs: [UUID?] = [nil, fixture.repos[0].id, fixture.repos[1].id]
        #expect(ids == expectedIDs)
        let wired = choosable.allSatisfy { $0.target === controller && $0.action == chooseAction && $0.isEnabled }
        #expect(wired)

        // Choosing "All Repos" clears the filter, and the next apply checks it.
        let choseAll = NSApplication.shared.sendAction(chooseAction, to: controller, from: choosable[0])
        #expect(choseAll)
        #expect(fixture.state.repoFilter == nil)
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let checkedAll = Self.checkedTitles(menu)
        let expectedAll: [String] = ["All Repos"]
        #expect(checkedAll == expectedAll)

        // Choosing a repo sets it.
        let choseAcme = NSApplication.shared.sendAction(chooseAction, to: controller, from: choosable[1])
        #expect(choseAcme)
        #expect(fixture.state.repoFilter == fixture.repos[0].id)
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let checkedAcme = Self.checkedTitles(menu)
        let expectedAcme: [String] = ["acme"]
        #expect(checkedAcme == expectedAcme)
    }

    @Test func filterNamingAMissingRepoChecksNothing() async throws {
        let fixture = ToolbarFixture(label: "filterNamingAMissingRepoChecksNothing")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let menu = fixture.controller.filterMenu

        // Control: a known repo is checked, so none below is the missing case.
        fixture.state.repoFilter = fixture.repos[0].id
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let checkedKnown = Self.checkedTitles(menu)
        let expectedKnown: [String] = ["acme"]
        #expect(checkedKnown == expectedKnown)

        fixture.state.repoFilter = UUID()
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let checkedMissing = Self.checkedTitles(menu)
        #expect(checkedMissing.isEmpty)
        let titles = Self.describeFilterRows(menu)
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets", "-", "Show Hidden Repos"]
        #expect(titles == expectedTitles)
    }

    /// The filter's row is checked only when the menu does not already check
    /// it: an apply with the filter unchanged changes no check, for a known
    /// repo or a missing one. A menu whose check something else moved is set
    /// back, which is also what shows the count does move when a check is
    /// set. Every apply here is direct and nothing suspends, so no scheduled
    /// apply lands in between.
    @Test func anUnchangedFilterIsNotSelectedAgain() async throws {
        let fixture = ToolbarFixture(label: "anUnchangedFilterIsNotSelectedAgain")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let menu = controller.filterMenu
        let expectedWidgets: [String] = ["widgets"]

        fixture.state.repoFilter = fixture.repos[1].id
        let known = MainToolbarSnapshot.make(from: fixture.state)
        let before = controller.filterSelectionCount
        controller.apply(known)
        let checkedFirst = Self.checkedTitles(menu)
        #expect(checkedFirst == expectedWidgets)
        #expect(controller.filterSelectionCount == before + 1)

        controller.apply(known)
        let checkedAgain = Self.checkedTitles(menu)
        #expect(checkedAgain == expectedWidgets)
        #expect(controller.filterSelectionCount == before + 1)

        menu.item(at: 0)?.state = .on
        menu.item(at: 3)?.state = .off
        controller.apply(known)
        let checkedBack = Self.checkedTitles(menu)
        #expect(checkedBack == expectedWidgets)
        #expect(controller.filterSelectionCount == before + 2)

        fixture.state.repoFilter = UUID()
        let missing = MainToolbarSnapshot.make(from: fixture.state)
        controller.apply(missing)
        let checkedMissing = Self.checkedTitles(menu)
        #expect(checkedMissing.isEmpty)
        #expect(controller.filterSelectionCount == before + 3)

        controller.apply(missing)
        let checkedMissingAgain = Self.checkedTitles(menu)
        #expect(checkedMissingAgain.isEmpty)
        #expect(controller.filterSelectionCount == before + 3)
    }

    /// The filter is a 28 pt icon whatever the repo it filters by is called:
    /// a long name reaches the tool tip and the menu, never the toolbar, so
    /// it cannot widen the item past the sidebar's section, where AppKit
    /// would move it into the overflow menu.
    @Test func filterHoldsItsSizeWhateverTheRepoName() async throws {
        let fixture = ToolbarFixture(label: "filterHoldsItsSizeWhateverTheRepoName")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let long = Repo(path: "/tmp/long", displayName: String(repeating: "acme-widgets-", count: 6) + "xx")
        try #require(long.displayName.count == 80)
        fixture.state.repos.append(long)
        fixture.state.repoFilter = long.id
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let host = try #require(fixture.filterHost)
        let button = try #require(host.button)
        #expect(button.toolTip == "Filtering by \(long.displayName)")
        let checked = Self.checkedTitles(fixture.controller.filterMenu)
        let expectedChecked: [String] = [long.displayName]
        #expect(checked == expectedChecked)
        let filterSize = NSSize(width: 28, height: 28)
        #expect(host.fittingSize == filterSize)

        let laidOut = try await waitForMainActorCondition("the filter to be laid out in the toolbar") {
            fixture.window.layoutIfNeeded()
            return host.window === fixture.window && host.frame.width > 0
        }
        try #require(laidOut)
        let pitch = MainToolbarMetrics.iconButtonPitch
        #expect(host.frame.width == pitch)
        #expect(button.frame.width == pitch)
    }

    /// The filter button shows the filter. With no repo filter it is
    /// untinted, the other icons' colour, its tool tip says what it does and
    /// its accessibility value is "All Repos". With one it is tinted system
    /// blue and both name the repo. Naming a repo that is gone still filters
    /// the sidebar, so it stays tinted and says the repo was removed. Cleared,
    /// it is untinted again. Its accessibility label stays "Filter".
    @Test func filterButtonShowsTheFilter() async throws {
        let fixture = ToolbarFixture(label: "filterButtonShowsTheFilter")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let button = try #require(fixture.filterButton)
        let blue = NSColor.systemBlue

        let unfilteredTint = button.contentTintColor
        #expect(unfilteredTint == nil)
        #expect(button.toolTip == "Filter sidebar by repository")
        let unfilteredValue = button.accessibilityValue() as? String
        #expect(unfilteredValue == "All Repos")

        fixture.state.repoFilter = fixture.repos[1].id
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let filteredTint = button.contentTintColor
        #expect(filteredTint == blue)
        #expect(button.toolTip == "Filtering by widgets")
        let filteredValue = button.accessibilityValue() as? String
        #expect(filteredValue == "widgets")
        #expect(button.accessibilityLabel() == "Filter")

        fixture.state.repoFilter = UUID()
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let goneTint = button.contentTintColor
        #expect(goneTint == blue)
        #expect(button.toolTip == "Filtering by a removed repository")
        let goneValue = button.accessibilityValue() as? String
        #expect(goneValue == "Removed repository")

        fixture.state.repoFilter = nil
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let clearedTint = button.contentTintColor
        #expect(clearedTint == nil)
        #expect(button.toolTip == "Filter sidebar by repository")
        let clearedValue = button.accessibilityValue() as? String
        #expect(clearedValue == "All Repos")
        #expect(button.accessibilityLabel() == "Filter")
    }

    /// The filter menu's top leading corner sits `filterMenuGap` below the
    /// button's bottom leading corner: the larger y in a flipped button and
    /// the smaller in one that is not, at the trailing edge under a
    /// right-to-left layout, where `NSMenu` places the menu's top right
    /// corner.
    @Test func filterMenuOpensBelowTheButton() {
        let bounds = NSRect(x: 0, y: 0, width: 28, height: 28)
        #expect(MainToolbarController.filterMenuGap == 4)
        let unflipped = MainToolbarController.filterMenuOrigin(in: bounds, flipped: false, rightToLeft: false)
        let flipped = MainToolbarController.filterMenuOrigin(in: bounds, flipped: true, rightToLeft: false)
        let rightToLeft = MainToolbarController.filterMenuOrigin(in: bounds, flipped: false, rightToLeft: true)
        let expectedUnflipped = NSPoint(x: 0, y: -4)
        let expectedFlipped = NSPoint(x: 0, y: 32)
        let expectedRightToLeft = NSPoint(x: 28, y: -4)
        #expect(unflipped == expectedUnflipped)
        #expect(flipped == expectedFlipped)
        #expect(rightToLeft == expectedRightToLeft)
    }

    // MARK: - Overflow menu

    /// Every item the layout can show, with every remote item present, sends
    /// its overflow row's action from that row, as the overflow menu does,
    /// and each row of a submenu sends its own. An
    /// action that assumed another sender would raise, ending the test
    /// process, which is the regression this guards. The filter's rows run
    /// in order, so the last repo is the filter after them, and Stop asks for
    /// its confirmation.
    ///
    /// - **The leading item's row** is "Navigation", whose submenu holds
    ///   Toggle Sidebar, Back and Forward; like the filter's, it only opens
    ///   its submenu, so its rows are what is sent.
    /// - **Toggle Sidebar** is checked, not sent: sending it would collapse
    ///   the sidebar and take the filter away part way through.
    ///   `leadingButtonsSurviveACollapse` covers the collapse.
    /// - **Remote buttons** have explicit rows titled with their labels.
    @Test func everyOverflowRowToleratesAMenuItemSender() async throws {
        let fixture = ToolbarFixture(label: "everyOverflowRowToleratesAMenuItemSender")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let selection = fixture.showRemoteSession()
        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let items = fixture.controller.toolbar.items
        let shownIDs = Set(items.map(\.itemIdentifier))
        let missing = MainToolbarItemID.custom.filter { !shownIDs.contains($0) }
        try #require(missing.isEmpty)

        let leading = try #require(fixture.controller.item(MainToolbarItemID.leadingButtons))
        let navigation = ToolbarFixture.overflowRow(of: leading)
        #expect(navigation.title == "Navigation")
        #expect(navigation.action == nil)
        let navigationTitles = navigation.subrows.map { $0.title }
        let expectedNavigationTitles: [String] = ["Toggle Sidebar", "Back", "Forward"]
        #expect(navigationTitles == expectedNavigationTitles)
        let toggleAction = #selector(NSSplitViewController.toggleSidebar(_:))
        let toggleRows = navigation.subrows.filter { $0.action == toggleAction }
        try #require(toggleRows.count == 1)
        let toggleTargetsTheSplit = toggleRows[0].target === fixture.split
        #expect(toggleTargetsTheSplit)

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
        for item in items where ToolbarFixture.hasOverflowRow(item) {
            let row = ToolbarFixture.overflowRow(of: item)
            if let action = row.action {
                sent += 1
                let sender = item.menuFormRepresentation ?? NSMenuItem(title: row.title, action: action, keyEquivalent: "")
                if !NSApplication.shared.sendAction(action, to: row.target, from: sender) {
                    unsent.append(row.title)
                }
            }
            for subrow in row.subrows where !subrow.isSeparatorItem && subrow.action != toggleAction {
                guard let action = subrow.action else { continue }
                sent += 1
                if !NSApplication.shared.sendAction(action, to: subrow.target, from: subrow) {
                    unsent.append(subrow.title)
                }
            }
        }

        #expect(unsent.isEmpty)
        // The Back and Forward rows, three filter rows, Show Hidden Repos,
        // Transcript, Reconnect and Stop at least.
        #expect(sent >= 9)
        #expect(fixture.state.repoFilter == fixture.repos[1].id)
        // Show Hidden Repos, sent once from the unset key, turned it on.
        let showsHidden = SidebarBuildOptions.storedShowHiddenRepos(fixture.suite.defaults)
        #expect(showsHidden)
        let expectedStops: [RemoteSessionSelection] = [selection]
        #expect(fixture.stopRequests == expectedStops)
    }

    /// The filter's overflow row is "Filter" with a submenu of the filter
    /// menu's rows. It checks the current choice, or none for a repo that is
    /// gone; choosing a row sets the filter; and it follows the options and
    /// the choice as they change, as the filter button's menu does. Each
    /// check reads the item's current row, as a change replaces the row
    /// rather than editing it.
    @Test func filterOverflowRowMirrorsTheMenu() async throws {
        let fixture = ToolbarFixture(label: "filterOverflowRowMirrorsTheMenu")
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
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets", "-", "Show Hidden Repos"]
        #expect(titles == expectedTitles)
        let checkedWidgets = Self.checkedTitles(rows)
        let expectedWidgets: [String] = ["widgets"]
        #expect(checkedWidgets == expectedWidgets)

        let choosable = Self.repoRows(rows)
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
        let expectedGrown: [String] = ["All Repos", "-", "acme", "widgets", "gadgets", "-", "Show Hidden Repos"]
        #expect(grownTitles == expectedGrown)
        let checkedGadgets = Self.checkedTitles(grownRows)
        let expectedGadgets: [String] = ["gadgets"]
        #expect(checkedGadgets == expectedGadgets)
        #expect(grownRows.delegate === controller.filterMenuTracker)
        let menuTitles = Self.describeFilterRows(controller.filterMenu)
        #expect(menuTitles == expectedGrown)
        let menuChecked = Self.checkedTitles(controller.filterMenu)
        #expect(menuChecked == expectedGadgets)
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
    /// "Filter" with no repos, and "No Selection", and the filter's button
    /// shows no filter. One made after an apply starts from what that apply
    /// showed, its filter button tinted and naming the repo, so an item the
    /// toolbar re-inserts, as after a collapse, never shows an empty row or
    /// a stale button in between. Made with `willBeInserted: false`, so the
    /// title item leaves the shared title view where it is.
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
        let emptyButton = try #require((emptyFilter.view as? FilterToolbarButtonHost)?.button)
        let emptyTint = emptyButton.contentTintColor
        #expect(emptyTint == nil)
        #expect(emptyButton.toolTip == "Filter sidebar by repository")
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
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets", "-", "Show Hidden Repos"]
        #expect(titles == expectedTitles)
        let checked = Self.checkedTitles(rows)
        let expectedChecked: [String] = ["widgets"]
        #expect(checked == expectedChecked)
        let filterButton = try #require((filterItem.view as? FilterToolbarButtonHost)?.button)
        let startTint = filterButton.contentTintColor
        let blue = NSColor.systemBlue
        #expect(startTint == blue)
        #expect(filterButton.toolTip == "Filtering by widgets")
        let titleItem = try #require(fixture.controller.makeItem(MainToolbarItemID.title, willBeInserted: false))
        let titleRow = try #require(titleItem.menuFormRepresentation)
        #expect(titleRow.title == "feature")
        #expect(titleRow.isHidden == false)
        #expect(titleRow.isEnabled == false)
        #expect(titleRow.action == nil)
        #expect(titleItem.view == nil)
        #expect(fixture.controller.item(MainToolbarItemID.title)?.view === fixture.titleView)
    }

    /// While one of the filter's menus is open, neither its overflow row nor
    /// the button's menu is rebuilt under the pointer, and neither's Show
    /// Hidden Repos row takes a new count or check; the close catches both
    /// up, with no apply but the one it schedules. The button's menu is the
    /// one opened here; the overflow submenu reports to the same tracker.
    @Test func filterOverflowRowsWaitForAnOpenMenuToClose() async throws {
        let fixture = ToolbarFixture(label: "filterOverflowRowsWaitForAnOpenMenuToClose")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let menu = controller.filterMenu
        let openForm = try #require(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation)
        let openRows = try #require(openForm.submenu)
        let before = Self.describeFilterRows(openRows)
        let menuBefore = Self.describeFilterRows(menu)
        try #require(menuBefore == before)
        let toggleBefore = Self.showHiddenReposState(menu)
        let plain = ShowHiddenReposRowState(title: "Show Hidden Repos", checked: false)
        try #require(toggleBefore == plain)

        controller.filterMenuTracker.menuWillOpen(menu)
        fixture.state.repos.append(Repo(path: "/tmp/gadgets", displayName: "gadgets", hidden: true))
        fixture.suite.defaults.set(true, forKey: SidebarBuildOptions.showHiddenReposKey)
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        #expect(controller.item(MainToolbarItemID.repoFilter)?.menuFormRepresentation === openForm)
        let whileOpen = Self.describeFilterRows(openRows)
        #expect(whileOpen == before)
        let menuWhileOpen = Self.describeFilterRows(menu)
        #expect(menuWhileOpen == menuBefore)
        let toggleWhileOpen = Self.showHiddenReposState(menu)
        #expect(toggleWhileOpen == plain)
        let overflowToggleWhileOpen = Self.showHiddenReposState(openRows)
        #expect(overflowToggleWhileOpen == plain)

        controller.filterMenuTracker.menuDidClose(menu)
        let caughtUpToggle = ShowHiddenReposRowState(title: "Show Hidden Repos (1)", checked: true)
        let caughtUp = try await waitForMainActorCondition("the filter's menu and overflow row to catch up once it closes") {
            let rows = MainToolbarControllerTests.filterOverflowRows(of: controller)
            let rowCaughtUp = rows.map {
                MainToolbarControllerTests.describeFilterRows($0).contains("gadgets")
                    && MainToolbarControllerTests.showHiddenReposState($0) == caughtUpToggle
            } ?? false
            let menuCaughtUp = MainToolbarControllerTests.describeFilterRows(controller.filterMenu).contains("gadgets")
                && MainToolbarControllerTests.showHiddenReposState(controller.filterMenu) == caughtUpToggle
            return rowCaughtUp && menuCaughtUp
        }
        #expect(caughtUp)
    }

    /// `filterChosen(_:)` reads its sender's class rather than assuming it.
    /// A bare menu item carries no repo, which is "All Repos". A sender that
    /// is not a menu item, such as the filter's own button, and no sender at
    /// all change nothing. The rows of the button's menu are
    /// `filterMenuShowsAndSetsTheFilter`'s.
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
        let filterButton = try #require(fixture.filterButton)
        let fromFilterButton = NSApplication.shared.sendAction(action, to: controller, from: filterButton)
        #expect(fromFilterButton)
        #expect(fixture.state.repoFilter == acme)
        controller.filterChosen(nil)
        #expect(fixture.state.repoFilter == acme)

        let bare = NSMenuItem(title: "Filter", action: action, keyEquivalent: "")
        let fromBareRow = NSApplication.shared.sendAction(action, to: controller, from: bare)
        #expect(fromBareRow)
        #expect(fixture.state.repoFilter == nil)
    }

    // MARK: - Show Hidden Repos

    /// The Show Hidden Repos row closes both filter menus, the button's and
    /// the overflow row's submenu, after a separator. It reads "Show Hidden
    /// Repos" with no repo hidden and carries the count once one is, is
    /// checked exactly while the key is on, stays enabled, and sends
    /// `showHiddenReposChosen(_:)` to the controller. Hiding a repo leaves
    /// the options as they were, hidden repos keeping their rows, so the
    /// button's menu keeps its rows and takes the new title in place. The
    /// key leaves the repo check alone and never tints the button. Every
    /// apply here is direct and nothing suspends between it and its checks.
    @Test func showHiddenReposRowShowsTheCountAndTheKey() async throws {
        let fixture = ToolbarFixture(label: "showHiddenReposRowShowsTheCountAndTheKey")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let menu = controller.filterMenu
        let toggleAction = #selector(MainToolbarController.showHiddenReposChosen(_:))

        let plain = ShowHiddenReposRowState(title: "Show Hidden Repos", checked: false)
        let menuPlain = Self.showHiddenReposState(menu)
        #expect(menuPlain == plain)
        let plainRows = try #require(Self.filterOverflowRows(of: controller))
        let overflowPlain = Self.showHiddenReposState(plainRows)
        #expect(overflowPlain == plain)
        let toggle = try #require(Self.showHiddenReposRow(menu))
        let targetsTheController = toggle.target === controller
        #expect(targetsTheController)
        #expect(toggle.action == toggleAction)
        #expect(toggle.isEnabled)
        let closing = Array(Self.describeFilterRows(menu).suffix(2))
        let expectedClosing: [String] = ["-", "Show Hidden Repos"]
        #expect(closing == expectedClosing)
        let overflowClosing = Array(Self.describeFilterRows(plainRows).suffix(2))
        #expect(overflowClosing == expectedClosing)

        // A repo hidden: its row stays, unmarked, and the count follows.
        let acmeRowBefore = Self.repoRows(menu).first { $0.title == "acme" }
        let widgetsHidden = fixture.state.repos[1].id
        fixture.state.repos[1].hidden = true
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let counted = ShowHiddenReposRowState(title: "Show Hidden Repos (1)", checked: false)
        let menuCounted = Self.showHiddenReposState(menu)
        #expect(menuCounted == counted)
        let countedRows = try #require(Self.filterOverflowRows(of: controller))
        let overflowCounted = Self.showHiddenReposState(countedRows)
        #expect(overflowCounted == counted)
        let acmeRowAfter = Self.repoRows(menu).first { $0.title == "acme" }
        let keptItsRows = acmeRowBefore != nil && acmeRowAfter === acmeRowBefore
        #expect(keptItsRows)
        let repoIDs = Self.repoRows(menu).map { $0.representedObject as? UUID }
        let expectedIDs: [UUID?] = [nil, fixture.repos[0].id, widgetsHidden]
        #expect(repoIDs == expectedIDs)
        let titles = Self.describeFilterRows(menu)
        let expectedTitles: [String] = ["All Repos", "-", "acme", "widgets", "-", "Show Hidden Repos (1)"]
        #expect(titles == expectedTitles)

        // The key on: both rows checked, the repo check and the button as
        // they were.
        fixture.suite.defaults.set(true, forKey: SidebarBuildOptions.showHiddenReposKey)
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let checked = ShowHiddenReposRowState(title: "Show Hidden Repos (1)", checked: true)
        let menuChecked = Self.showHiddenReposState(menu)
        #expect(menuChecked == checked)
        let checkedRows = try #require(Self.filterOverflowRows(of: controller))
        let overflowChecked = Self.showHiddenReposState(checkedRows)
        #expect(overflowChecked == checked)
        let checkedTitles = Self.checkedTitles(menu)
        let expectedChecked: [String] = ["All Repos", "Show Hidden Repos (1)"]
        #expect(checkedTitles == expectedChecked)
        let button = try #require(fixture.filterButton)
        let tint = button.contentTintColor
        #expect(tint == nil)
        #expect(button.toolTip == "Filter sidebar by repository")
        let value = button.accessibilityValue() as? String
        #expect(value == "All Repos")

        // The key off again: unchecked.
        fixture.suite.defaults.set(false, forKey: SidebarBuildOptions.showHiddenReposKey)
        controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let menuOff = Self.showHiddenReposState(menu)
        #expect(menuOff == counted)
        let offRows = try #require(Self.filterOverflowRows(of: controller))
        let overflowOff = Self.showHiddenReposState(offRows)
        #expect(overflowOff == counted)
    }

    /// Choosing Show Hidden Repos flips the key both ways in `AppState`'s
    /// store, the one the app hands the sidebar's outline: on from the
    /// button's menu, off from the overflow row's submenu. No test applies
    /// after either: the defaults watch queues the apply that checks or
    /// unchecks both rows.
    @Test func showHiddenReposChosenFlipsTheKeyBothWays() async throws {
        let fixture = ToolbarFixture(label: "showHiddenReposChosenFlipsTheKeyBothWays")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let defaults = fixture.suite.defaults
        let sharesTheStore = defaults === fixture.state.userDefaults
        try #require(sharesTheStore)
        let action = #selector(MainToolbarController.showHiddenReposChosen(_:))
        let unset = SidebarBuildOptions.storedShowHiddenRepos(defaults)
        try #require(unset == false)

        let menuRow = try #require(Self.showHiddenReposRow(controller.filterMenu))
        let sentOn = NSApplication.shared.sendAction(action, to: controller, from: menuRow)
        #expect(sentOn)
        let on = SidebarBuildOptions.storedShowHiddenRepos(defaults)
        #expect(on)
        let checkedOn = try await waitForMainActorCondition("the defaults watch's apply to check both rows") {
            let menuChecked = MainToolbarControllerTests.showHiddenReposState(controller.filterMenu)?.checked
            let rows = MainToolbarControllerTests.filterOverflowRows(of: controller)
            let overflowChecked = rows.flatMap { MainToolbarControllerTests.showHiddenReposState($0) }?.checked
            return menuChecked == true && overflowChecked == true
        }
        #expect(checkedOn)

        let overflowRows = try #require(Self.filterOverflowRows(of: controller))
        let overflowRow = try #require(Self.showHiddenReposRow(overflowRows))
        let sentOff = NSApplication.shared.sendAction(action, to: controller, from: overflowRow)
        #expect(sentOff)
        let off = SidebarBuildOptions.storedShowHiddenRepos(defaults)
        #expect(off == false)
        let uncheckedOff = try await waitForMainActorCondition("the defaults watch's apply to uncheck both rows") {
            let menuChecked = MainToolbarControllerTests.showHiddenReposState(controller.filterMenu)?.checked
            let rows = MainToolbarControllerTests.filterOverflowRows(of: controller)
            let overflowChecked = rows.flatMap { MainToolbarControllerTests.showHiddenReposState($0) }?.checked
            return menuChecked == false && overflowChecked == false
        }
        #expect(uncheckedOff)
    }

    /// The defaults watch's gate, driven directly so the test does not
    /// depend on when the notification arrives. A change to another key in
    /// the store queues nothing, since the store holds many keys the toolbar
    /// never shows. A change to the Show Hidden Repos key queues the apply
    /// that compares first, which then checks the row. A controller that is
    /// not installed queues nothing.
    @Test func defaultsWatchQueuesAnApplyOnlyForTheShowHiddenReposKey() async throws {
        let fixture = ToolbarFixture(label: "defaultsWatchQueuesAnApplyOnlyForTheShowHiddenReposKey")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let defaults = fixture.suite.defaults

        try await fixture.withNoApplyQueued("before the store changes") {
            defaults.set("acme", forKey: "MainToolbarControllerTests.unrelatedKey")
            controller.defaultsChanged()
            let queuedForAnotherKey = controller.applyScheduled
            #expect(queuedForAnotherKey == false)

            defaults.set(true, forKey: SidebarBuildOptions.showHiddenReposKey)
            controller.defaultsChanged()
            let queuedForTheKey = controller.applyScheduled
            #expect(queuedForTheKey)
            let runsInFull = controller.queuedApplyRunsInFull
            #expect(runsInFull == false)
        }
        let checked = try await waitForMainActorCondition("the queued apply to check the row") {
            MainToolbarControllerTests.showHiddenReposState(controller.filterMenu)?.checked == true
        }
        #expect(checked)

        let uninstalled = MainToolbarController(
            appState: fixture.state, split: ToolbarFixture.makeSplit(), titleView: NSView(),
            requestRemoteStop: { _ in })
        defaults.set(false, forKey: SidebarBuildOptions.showHiddenReposKey)
        uninstalled.defaultsChanged()
        #expect(uninstalled.applyScheduled == false)
    }

    /// While installed, the controller measures what the panes' top rows
    /// read: the content pane's top safe-area inset, which the toolbar takes,
    /// and the leading item's trailing edge from the content pane's leading
    /// edge, left of it while the sidebar is shown and over the pane once it
    /// collapses. Uninstalled, it measures nothing.
    @Test func publishesTheChromeGeometry() async throws {
        let fixture = ToolbarFixture(label: "publishesTheChromeGeometry")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let chrome = fixture.state.windowChrome
        let pane = fixture.split.contentItem.viewController.view

        let measured = try await waitForMainActorCondition("the inset and the leading edge to be published") {
            chrome.topSafeAreaInset > 0 && chrome.topSafeAreaInset == pane.safeAreaInsets.top
                && chrome.leadingItemTrailingEdge != nil
        }
        try #require(measured)
        let shownEdge = try #require(chrome.leadingItemTrailingEdge)
        #expect(shownEdge < 0)
        let shownInset = MainTabRowMetrics.leadingInset(leadingItemTrailingEdge: shownEdge)
        #expect(shownInset == MainTabRowMetrics.shownSidebarInset)

        fixture.split.sidebarItem.isCollapsed = true
        let overThePane = try await waitForMainActorCondition("the leading edge to reach over the pane") {
            (chrome.leadingItemTrailingEdge ?? 0) > 0
        }
        try #require(overThePane)
        let collapsedEdge = try #require(chrome.leadingItemTrailingEdge)
        let leading = try #require(fixture.controller.item(MainToolbarItemID.leadingButtons)?.view)
        let leadingEnd = leading.convert(leading.bounds, to: nil).maxX
        let paneStart = pane.convert(pane.bounds, to: nil).minX
        let expectedEdge = leadingEnd - paneStart
        #expect(abs(collapsedEdge - expectedEdge) < 0.5)

        fixture.controller.uninstall()
        let scheduledAfterUninstall: Bool = {
            fixture.controller.scheduleChromeGeometryPublish()
            return fixture.controller.chromeGeometryPublishScheduled
        }()
        #expect(scheduledAfterUninstall == false)
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

    // MARK: - Re-install

    /// The replacement alone brings the toolbar back, through KVO on the
    /// window's `toolbar`: it is made in the turn that found no apply queued,
    /// and in that same turn the replacement has counted and queued the apply
    /// that puts ours back, so the watch is what brings it back rather than
    /// some later apply.
    @Test func reinstallsAReplacedToolbar() async throws {
        let fixture = ToolbarFixture(label: "reinstallsAReplacedToolbar")
        defer { fixture.tearDown() }
        try await fixture.ready()

        try await fixture.withNoApplyQueued("before the replacement") {
            fixture.window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.replacement")
            try #require(fixture.window.toolbar !== fixture.controller.toolbar)
            // KVO reports synchronously, so the watch has already counted the
            // replacement and queued the reinstall.
            #expect(fixture.controller.recentReplacements.count == 1)
            #expect(fixture.controller.applyScheduled)
        }

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
        try #require(controller.recentReplacements.isEmpty)

        let cap = MainToolbarController.maxReplacementsInWindow
        for attempt in 1...cap {
            // Made with no apply queued, so the clear alone brings ours back.
            try await fixture.withNoApplyQueued("before clear \(attempt) of \(cap)") {
                window.toolbar = nil
                // KVO reports synchronously, so the clear is already counted.
                #expect(controller.recentReplacements.count == attempt)
            }
            let back = try await waitForMainActorCondition("clear \(attempt) of \(cap) to be put back") {
                window.toolbar === controller.toolbar
            }
            try #require(back)
        }

        try await fixture.withNoApplyQueued("before the clear past the cap") {
            try #require(controller.isInReinstallCooldown == false)
            window.toolbar = nil
            #expect(controller.isInReinstallCooldown)
            #expect(controller.applyScheduled == false)
            #expect(window.toolbar == nil)
        }

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
        // Everything from the removal to the toolbar set after it runs in the
        // turn that found no apply queued, with nothing that can suspend.
        try await fixture.withNoApplyQueued("after ordering the window out") {
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

            // Nothing suspends from ordering the window in to the toolbar set,
            // so no queued apply can put ours back in between.
            fixture.split.onViewDidAppear = nil
            window.orderFront(nil)
            try #require(window.isVisible)
            try #require(window.toolbar == nil)
            window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.afterRemoval")
            #expect(controller.recentReplacements.count == 1)
        }
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
        try await fixture.withNoApplyQueued("after ordering the window out") {
            try #require(controller.recentReplacements.isEmpty)
            try #require(window.toolbar === controller.toolbar)

            let other = NSToolbar(identifier: "MainToolbarControllerTests.onHiddenWindow")
            window.toolbar = other
            // KVO reports synchronously, so a watch that took the change for a
            // replacement would have counted it and queued an apply by now.
            #expect(controller.recentReplacements.isEmpty)
            #expect(controller.applyScheduled == false)
            #expect(controller.isInstalled)

            // The apply runs, which is what makes its leaving the other
            // toolbar on the window mean something.
            let appliesBefore = controller.applyCount
            controller.apply(MainToolbarSnapshot.make(from: fixture.state))
            #expect(controller.applyCount == appliesBefore + 1)
            #expect(window.toolbar === other)
        }
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

        _ = try await fixture.replaceUntilTheCooldownStarts(label: "refused") { replacement in
            // KVO reports synchronously, so the refusal is already in place.
            #expect(controller.isInReinstallCooldown)
            #expect(controller.applyScheduled == false)
            #expect(window.toolbar === replacement)
        }

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
    /// still does nothing: no apply runs for that change, so no content is
    /// updated on the detached toolbar. A change the toolbar does show is
    /// still applied, leaving the replacement on the window. The cooldown is
    /// never advanced, so it runs throughout; the fixture's teardown cancels
    /// it.
    ///
    /// The count asserted is `comparedApplyCount`, not `applyCount`: only an
    /// apply that compared first moves it, as the change's apply does.
    /// Anything that asks through `scheduleApply()`, such as a second install
    /// from the split's `viewDidAppear`, can do so at any turn of a loaded
    /// pass, after the check that found none queued: its apply either joins
    /// the one the change queued, which then runs in full, or runs after it.
    /// Either adds to `applyCount` and neither moves the count asserted.
    @Test func anUnchangedObservedChangeDuringTheCooldownDoesNotReapply() async throws {
        let fixture = ToolbarFixture(
            label: "anUnchangedObservedChangeDuringTheCooldownDoesNotReapply",
            now: TestDateSource().provider, clock: EventDrivenTestClock())
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let window = fixture.window

        // The snapshot reads the worktree lists only with a worktree
        // selected, to find the title's.
        fixture.selectFirstWorktree()
        let titled = fixture.worktrees[0].displayName
        let shown = try await waitForMainActorCondition("the apply that shows the worktree's title, with none queued") {
            controller.appliedSnapshot?.title == titled && !controller.applyScheduled
        }
        try #require(shown)

        let kept = try await fixture.replaceUntilTheCooldownStarts(label: "observed")
        try #require(controller.isInReinstallCooldown)

        let other = fixture.worktrees[1].id
        let before = try await fixture.withNoApplyQueued("once the cooldown started") {
            () throws -> (comparedApplies: Int, changes: Int) in
            let counts = (comparedApplies: controller.comparedApplyCount, changes: controller.observedChangeCount)
            try #require(fixture.state.selectedWorktreeIDs.contains(other) == false)
            fixture.renameWorktree(at: 1, to: "acme-renamed")
            return counts
        }
        let comparedAppliesBefore = before.comparedApplies
        let changesBefore = before.changes
        let ran = try await waitForMainActorCondition("the change to be observed and its apply to run") {
            controller.observedChangeCount > changesBefore && !controller.applyScheduled
        }
        try #require(ran)
        #expect(controller.observedChangeCount == changesBefore + 1)
        #expect(controller.comparedApplyCount == comparedAppliesBefore)
        #expect(window.toolbar === kept)
        #expect(controller.isInReinstallCooldown)

        let repoID = fixture.repos[1].id
        fixture.state.repoFilter = repoID
        let applied = try await waitForMainActorCondition("the apply for a change the toolbar shows") {
            controller.appliedSnapshot?.filter.selected == repoID
        }
        try #require(applied)
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

        try await fixture.withNoApplyQueued("before the uninstall") {
            fixture.controller.uninstall()
            #expect(fixture.window.toolbar == nil)
            #expect(fixture.controller.isInstalled == false)
            // KVO reports synchronously, so a watch that took the removal for a
            // replacement would have queued an apply by now.
            #expect(fixture.controller.applyScheduled == false)

            // The apply runs, which is what makes its leaving the window
            // without a toolbar mean something.
            let appliesBefore = fixture.controller.applyCount
            fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
            #expect(fixture.controller.applyCount == appliesBefore + 1)
            #expect(fixture.window.toolbar == nil)
        }
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
        try await fixture.withNoApplyQueued("before the uninstall") {
            controller.uninstall()
            #expect(controller.window == nil)
            #expect(controller.split === fixture.split)
            let reportUnhooked = fixture.split.onSidebarCollapsedChange == nil
            #expect(reportUnhooked)
        }

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
    /// generation check. Both counts are read in the turn behind the
    /// change's apply, so an apply something else asks for after it is not
    /// counted against the change.
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
        let after = try await fixture.countsBehindTheQueuedApply()
        #expect(after.observedChanges == changesBefore + 1)
        #expect(after.applies == appliesBefore + 1)
        #expect(fixture.controller.appliedSnapshot?.filter.selected == repoID)
    }

    /// The snapshot looks the selected worktree up among all of them, so a
    /// rename of a worktree other than the selected one is observed and
    /// queues an apply. That apply finds the snapshot and the collapse as the
    /// toolbar shows them and does no layout or content work. It still
    /// re-arms the tracking: a rename of the selected worktree is applied
    /// after it. The count asserted is the one only an apply that compared
    /// first moves, for the reason
    /// `anUnchangedObservedChangeDuringTheCooldownDoesNotReapply` gives.
    @Test func anotherWorktreesRenameDoesNotReapply() async throws {
        let fixture = ToolbarFixture(label: "anotherWorktreesRenameDoesNotReapply")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller

        fixture.selectFirstWorktree()
        let titled = fixture.worktrees[0].displayName
        let shown = try await waitForMainActorCondition("the apply that shows the worktree's title, with none queued") {
            controller.appliedSnapshot?.title == titled && !controller.applyScheduled
        }
        try #require(shown)

        let other = fixture.worktrees[1].id
        let before = try await fixture.withNoApplyQueued("before another worktree's rename") {
            () throws -> (comparedApplies: Int, changes: Int) in
            let counts = (comparedApplies: controller.comparedApplyCount, changes: controller.observedChangeCount)
            try #require(fixture.state.selectedWorktreeIDs.contains(other) == false)
            fixture.renameWorktree(at: 1, to: "acme-renamed")
            return counts
        }
        let comparedAppliesBefore = before.comparedApplies
        let changesBefore = before.changes
        let ran = try await waitForMainActorCondition("the change to be observed and its apply to run") {
            controller.observedChangeCount > changesBefore && !controller.applyScheduled
        }
        try #require(ran)
        #expect(controller.observedChangeCount == changesBefore + 1)
        #expect(controller.comparedApplyCount == comparedAppliesBefore)

        fixture.renameWorktree(at: 0, to: "acme-selected")
        let applied = try await waitForMainActorCondition("the apply for the selected worktree's rename") {
            controller.appliedSnapshot?.title == "acme-selected"
        }
        #expect(applied)
    }

    /// An apply asked for through `scheduleApply()` runs in full with nothing
    /// changed: a repeated install, as a second `viewDidAppear` makes, and
    /// `scheduleApply()` itself, through which the replacement watch, a
    /// collapse report, the cooldown's end and the filter menu's close all
    /// ask. Each count is read in the turn behind the request's apply, so an
    /// apply something else asks for after it is not counted against the
    /// request. Neither request's apply compares first, so
    /// `comparedApplyCount` stays where it was.
    @Test func requestedAppliesRunWithNothingChanged() async throws {
        let fixture = ToolbarFixture(label: "requestedAppliesRunWithNothingChanged")
        defer { fixture.tearDown() }
        try await fixture.ready()
        let controller = fixture.controller
        let comparedAppliesBefore = controller.comparedApplyCount

        let beforeInstall = controller.applyCount
        controller.install(on: fixture.window)
        try #require(controller.applyScheduled)
        let afterInstall = try await fixture.countsBehindTheQueuedApply()
        #expect(afterInstall.applies == beforeInstall + 1)

        let beforeRequest = controller.applyCount
        controller.scheduleApply()
        try #require(controller.applyScheduled)
        let afterRequest = try await fixture.countsBehindTheQueuedApply()
        #expect(afterRequest.applies == beforeRequest + 1)
        #expect(controller.comparedApplyCount == comparedAppliesBefore)
    }

    // MARK: - Content

    /// An apply that changes nothing sets nothing: the Transcript image is
    /// the same object afterwards. A changed Transcript symbol does set a new
    /// image and tool tip.
    @Test func unchangedContentIsNotSetAgain() async throws {
        let fixture = ToolbarFixture(label: "unchangedContentIsNotSetAgain")
        defer { fixture.tearDown() }
        try await fixture.ready()

        fixture.showRemoteSession()
        var snapshot = MainToolbarSnapshot.make(from: fixture.state)
        let remote = try #require(snapshot.remote)
        try #require(remote.showsTranscript)
        fixture.controller.apply(snapshot)
        let transcript = try #require(fixture.controller.item(MainToolbarItemID.remoteTranscript))
        let transcriptImage = try #require(transcript.image)
        let transcriptTip = transcript.toolTip

        fixture.controller.apply(snapshot)
        #expect(transcript.image === transcriptImage)
        #expect(transcript.toolTip == transcriptTip)

        snapshot.remote?.transcriptShown = !remote.transcriptShown
        let toggledHelp = try #require(snapshot.remote?.transcriptHelp)
        try #require(toggledHelp != remote.transcriptHelp)
        fixture.controller.apply(snapshot)
        let toggled = try #require(transcript.image)
        #expect(toggled !== transcriptImage)
        #expect(toggled.accessibilityDescription == toggledHelp)
        #expect(transcript.toolTip == toggledHelp)
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

    /// The rows of a filter menu that choose a repo, "All Repos" among them,
    /// found by their action.
    static func repoRows(_ menu: NSMenu) -> [NSMenuItem] {
        let action = #selector(MainToolbarController.filterChosen(_:))
        return menu.items.filter { $0.action == action }
    }

    /// A filter menu's Show Hidden Repos row, found by its action.
    static func showHiddenReposRow(_ menu: NSMenu) -> NSMenuItem? {
        let action = #selector(MainToolbarController.showHiddenReposChosen(_:))
        return menu.items.first { $0.action == action }
    }

    /// The Show Hidden Repos row of a filter menu as its title and whether it
    /// is checked, or `nil` when the menu has none.
    fileprivate static func showHiddenReposState(_ menu: NSMenu) -> ShowHiddenReposRowState? {
        showHiddenReposRow(menu).map { ShowHiddenReposRowState(title: $0.title, checked: $0.state == .on) }
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
    /// What the last quiet probe of `withNoApplyQueued` saw, for its
    /// diagnostic.
    private var quietProbe = (observedChanges: 0, applies: 0)

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
    /// pending that could stand in for the trigger it is about. The wait's
    /// probe runs in an earlier main-actor turn than the caller's next line,
    /// so a test whose assertion needs nothing queued at its own change makes
    /// that change inside `withNoApplyQueued`.
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

    /// How many times `withNoApplyQueued` waits for none to be queued before
    /// it gives up.
    static let quietAttempts = 3

    /// Runs `body` with no apply queued, in the same synchronous main-actor
    /// segment as the check that found none, and returns what `body` returns.
    ///
    /// A wait for none queued is not enough on its own. Its probe runs in an
    /// earlier main-actor turn than the test body, which has to win the main
    /// actor back once the wait returns, and anything that runs in that gap
    /// can queue an apply: `scheduleApply()` from an install, a collapse
    /// report or a cooldown's end, or the comparing apply the defaults watch
    /// or an observed `AppState` change queues. That apply is a
    /// `DispatchQueue.main.async` block queued behind the body, so a body that
    /// then asserts its own change queued nothing would see it. So the check
    /// is made here first, with nothing that can suspend between it and
    /// `body`; when an apply is queued, this waits for none and checks again,
    /// `quietAttempts` times at most. An assertion that a change queued
    /// nothing belongs inside `body`, never after this returns.
    func withNoApplyQueued<T>(_ what: String, _ body: () throws -> T) async throws -> T {
        if !controller.applyScheduled { return try body() }
        var gaps: [String] = []
        for _ in 1...Self.quietAttempts {
            let quiet = try await waitForMainActorCondition("no apply queued \(what)") { [self] in
                guard !controller.applyScheduled else { return false }
                quietProbe = (observedChanges: controller.observedChangeCount, applies: controller.applyCount)
                return true
            }
            try #require(quiet)
            // The probe ran in an earlier main-actor turn than this line.
            if !controller.applyScheduled { return try body() }
            gaps.append("""
                observed changes \(quietProbe.observedChanges) → \(controller.observedChangeCount), \
                applies \(quietProbe.applies) → \(controller.applyCount)
                """)
        }
        throw ApplyQueuedBeforeTheTestsTurn(what: what, gaps: gaps)
    }

    /// The controller's counts in the main-queue turn right behind the apply
    /// queued now: the one the caller's change or request just queued, or
    /// the one already queued that it joined.
    ///
    /// The controller queues each apply with `DispatchQueue.main.async`, and
    /// the main queue runs blocks in the order they were queued, so the
    /// block queued here runs once that apply has, and before any apply
    /// queued after it. A wait's probe gives no such order: it reaches the
    /// main actor after a hop through the cooperative pool, and another
    /// source can queue and run an apply in between. So a count that one
    /// change's apply should move by exactly one is read here. This awaits
    /// one main-queue turn and nothing else, as every `@MainActor` test's own
    /// resumption does, so it takes no deadline.
    func countsBehindTheQueuedApply() async throws -> ApplyCounts {
        try #require(controller.applyScheduled, "no apply is queued to read behind")
        let controller = self.controller
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    continuation.resume(returning: ApplyCounts(
                        applies: controller.applyCount, comparedApplies: controller.comparedApplyCount,
                        observedChanges: controller.observedChangeCount))
                }
            }
        }
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
    ///
    /// `check` runs on that last replacement in the same main-actor turn as
    /// the replacement and the check that found no apply queued before it
    /// (`withNoApplyQueued`), so an assertion that the replacement queued
    /// nothing belongs there.
    func replaceUntilTheCooldownStarts(
        label: String, then check: (NSToolbar) throws -> Void = { _ in }
    ) async throws -> NSToolbar {
        try await replaceAndWaitForReinstall(times: MainToolbarController.maxReplacementsInWindow, label: label)
        let controller = self.controller
        let window = self.window
        let kept = NSToolbar(identifier: "MainToolbarControllerTests.\(label).kept")
        try await withNoApplyQueued("before the replacement past the cap") {
            try #require(controller.isInReinstallCooldown == false)
            window.toolbar = kept
            try check(kept)
        }
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

    /// The filter item's view, holding its button.
    var filterHost: FilterToolbarButtonHost? {
        controller.item(MainToolbarItemID.repoFilter)?.view as? FilterToolbarButtonHost
    }

    /// The filter item's button, which pops up the filter menu.
    var filterButton: NSButton? {
        filterHost?.button
    }

    /// The leading item's view, holding the toggle, back and forward.
    var leadingHost: LeadingToolbarButtonsHost? {
        controller.item(MainToolbarItemID.leadingButtons)?.view as? LeadingToolbarButtonsHost
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
    /// window has a zoom button, the split a sidebar pane, and the leading
    /// item and the title view a place in the window.
    func edges() -> ToolbarEdges? {
        window.layoutIfNeeded()
        guard let zoom = window.standardWindowButton(.zoomButton),
              let pane = sidebarPane,
              let host = leadingHost,
              let leading = Self.placedFrame(of: host, in: window),
              let title = Self.placedFrame(of: titleView, in: window) else { return nil }
        return ToolbarEdges(
            buttonsMaxX: zoom.convert(zoom.bounds, to: nil).maxX,
            dividerX: pane.convert(pane.bounds, to: nil).maxX,
            leading: leading,
            filter: filterHost.flatMap { Self.placedFrame(of: $0, in: window) },
            title: title)
    }

    /// `view`'s frame in window coordinates, once it sits in `window` with a
    /// width.
    static func placedFrame(of view: NSView, in window: NSWindow) -> NSRect? {
        guard view.window === window, view.frame.width > 0 else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    /// `view`'s own constraints carrying `identifier`.
    static func constraints(of view: NSView, identified identifier: String) -> [NSLayoutConstraint] {
        view.constraints.filter { $0.identifier == identifier }
    }

    /// The leading host's toggle, back and forward buttons, in that order,
    /// each found by its identifier.
    static func buttons(of host: LeadingToolbarButtonsHost) throws -> [NSButton] {
        let toggle = try #require(host.toggleButton, "no toggle button found by its identifier")
        let back = try #require(host.backButton, "no back button found by its identifier")
        let forward = try #require(host.forwardButton, "no forward button found by its identifier")
        return [toggle, back, forward]
    }

    /// The selectors `NSToolbarItem` forwards to a view that answers them,
    /// which the leading host must not answer.
    static let forwardedSelectorNames = [
        "isBordered", "setBordered:", "isEnabled", "setEnabled:", "target", "setTarget:",
        "action", "setAction:", "image", "setImage:",
    ]

    /// Which of `forwardedSelectorNames` `view` answers.
    static func answeredForwardedSelectors(of view: NSView) -> [String] {
        forwardedSelectorNames.filter { view.responds(to: NSSelectorFromString($0)) }
    }

    /// The pins that tile `buttons` across `host` which `host`'s constraints
    /// lack, named by button index and edge: each button's leading edge to
    /// the host's leading edge for the first and to the trailing edge of the
    /// one before for the rest, each button's height to its width and its vertical centre to the host's,
    /// and the last one's trailing edge to the host's. Empty when all are
    /// there, required, equal and with no offset.
    static func missingTilePins(of buttons: [NSView], in host: NSView) -> [String] {
        var missing: [String] = []
        for (index, button) in buttons.enumerated() {
            let leadingPinned = index == 0
                ? pinned(button, .leading, to: host, .leading, in: host)
                : pinned(button, .leading, to: buttons[index - 1], .trailing, in: host)
            if !leadingPinned { missing.append("\(index).leading") }
            if !pinned(button, .height, to: button, .width, in: button) { missing.append("\(index).square") }
            if !pinned(button, .centerY, to: host, .centerY, in: host) { missing.append("\(index).centerY") }
        }
        if let last = buttons.last, !pinned(last, .trailing, to: host, .trailing, in: host) {
            missing.append("\(buttons.count - 1).trailing")
        }
        return missing
    }

    /// Whether one of `owner`'s constraints holds `first`'s `firstAttribute`
    /// to `second`'s `secondAttribute`: required, equal, with no offset.
    /// A constraint between two attributes of one view is installed on that
    /// view, so the square pin is searched in the button's own constraints.
    private static func pinned(
        _ first: NSView, _ firstAttribute: NSLayoutConstraint.Attribute,
        to second: NSView, _ secondAttribute: NSLayoutConstraint.Attribute, in owner: NSView
    ) -> Bool {
        owner.constraints.contains { constraint in
            constraint.firstItem === first && constraint.secondItem === second
                && constraint.firstAttribute == firstAttribute && constraint.secondAttribute == secondAttribute
                && constraint.relation == .equal && constraint.priority == .required
                && constraint.multiplier == 1 && constraint.constant == 0
        }
    }

    /// The rows of the leading item's overflow submenu, Toggle Sidebar, Back
    /// and Forward, in that order, each found by its action.
    static func navigationRows(of item: NSToolbarItem) throws -> [NSMenuItem] {
        let rows = item.menuFormRepresentation?.submenu?.items ?? []
        let actions: [Selector] = [
            #selector(NSSplitViewController.toggleSidebar(_:)),
            #selector(MainToolbarController.navigateBack(_:)),
            #selector(MainToolbarController.navigateForward(_:)),
        ]
        var found: [NSMenuItem] = []
        for action in actions {
            let row = rows.first { $0.action == action }
            let sending = try #require(row, "no overflow row sends \(action)")
            found.append(sending)
        }
        return found
    }

    /// Whether the leading item, its three buttons and its three overflow
    /// rows are enabled.
    static func enablement(of item: NSToolbarItem) throws -> LeadingEnablement {
        let host = try #require(item.view as? LeadingToolbarButtonsHost)
        let buttons = try Self.buttons(of: host)
        let rows = try navigationRows(of: item)
        return LeadingEnablement(
            item: item.isEnabled, buttons: buttons.map { $0.isEnabled }, rows: rows.map { $0.isEnabled })
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
    /// form unless one is set. For a view item whose view answers them, the
    /// target and action are its view's.
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

    // MARK: State

    /// Selects the first worktree, so the title names it and the snapshot
    /// reads the worktree lists to find it.
    func selectFirstWorktree() {
        state.selectedWorktreeIDs = [worktrees[0].id]
    }

    /// Renames the worktree at `index` in the first repo's list, which holds
    /// both of the fixture's worktrees.
    func renameWorktree(at index: Int, to name: String) {
        state.worktrees[repos[0].id]?[index].displayName = name
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

    /// A plain view controller over a sized, empty view.
    private static func makePane(width: CGFloat) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: windowSize.height))
        return controller
    }
}

/// The controller's apply, compared-apply and observed-change counts, as
/// `countsBehindTheQueuedApply()` reads them.
private struct ApplyCounts: Sendable {
    let applies: Int
    let comparedApplies: Int
    let observedChanges: Int
}

/// `withNoApplyQueued` never found the test's own turn with no apply queued:
/// after each wait for none, something had queued one again before the test
/// ran. Each gap names the observed-change and apply counts at the quiet
/// probe and at the test's turn; an observed-change count that rose names an
/// observed `AppState` change as the source, and one that did not names the
/// defaults watch or `scheduleApply()` — an install, a collapse report or a
/// cooldown's end.
private struct ApplyQueuedBeforeTheTestsTurn: Error, CustomStringConvertible {
    let what: String
    let gaps: [String]

    var description: String {
        """
        no turn with no apply queued \(what): after each of \(gaps.count) wait(s) for \
        none, an apply was queued again before the test's turn — \
        \(gaps.joined(separator: "; ")). A rise in observed changes names an observed \
        AppState change as the source; none names the defaults watch or \
        scheduleApply() (install, collapse, cooldown end).
        """
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
    /// The leading item, holding the toggle, back and forward buttons.
    var leading: NSRect
    /// The filter's host, while it is in the toolbar and laid out.
    var filter: NSRect?
    var title: NSRect

    /// Whether the leading item sits right of the window buttons and ends at
    /// or before `next`, where the item after it starts.
    func leadingPlaced(before next: CGFloat) -> Bool {
        buttonsMaxX <= leading.minX && leading.maxX <= next
    }

    /// The sidebar shown: the leading item right of the window buttons, then
    /// the filter, left of the divider, and the title right of it.
    var placedOverAShownSidebar: Bool {
        guard let filter else { return false }
        return leadingPlaced(before: filter.minX) && filter.maxX <= dividerX && dividerX <= title.minX
    }

    /// The sidebar collapsed: the leading item right of the window buttons,
    /// then the title, left of `shownDividerX`, where the shown sidebar
    /// ended.
    func placedBesideTheWindowButtons(shownDividerX: CGFloat) -> Bool {
        leadingPlaced(before: title.minX) && title.minX < shownDividerX
    }
}

/// Whether the leading item is enabled, and each of its buttons and its
/// overflow rows, toggle, back and forward in that order.
private struct LeadingEnablement: Equatable {
    var item: Bool
    var buttons: [Bool]
    var rows: [Bool]
}

/// A filter menu's Show Hidden Repos row: its title and whether it is
/// checked.
private struct ShowHiddenReposRowState: Equatable {
    var title: String
    var checked: Bool
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
