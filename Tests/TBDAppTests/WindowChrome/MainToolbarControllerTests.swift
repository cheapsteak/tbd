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

        let throwaway = fixture.controller.toolbar(
            fixture.controller.toolbar, itemForItemIdentifier: MainToolbarItemID.title,
            willBeInsertedIntoToolbar: false)
        #expect(throwaway != nil)
        #expect(throwaway?.view == nil)
        #expect(fixture.controller.item(MainToolbarItemID.title)?.view === fixture.titleView)
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
    /// - **Position.** AppKit gives an image item, such as the toggle or an
    ///   arrow, no view and no frame through any public API, so those three
    ///   are placed by order: they open `toolbar.items`, before the
    ///   separator, and are visible. The view-based items do have frames,
    ///   checked in window coordinates against the zoom button and the
    ///   divider the separator tracks. Shown, the filter sits right of the
    ///   zoom button and left of the divider, and the title right of the
    ///   divider. Collapsed, the title sits right of the zoom button and left
    ///   of where the shown sidebar ended, so the toolbar followed the
    ///   collapse. AppKit lays visible items out in order, so the toggle and
    ///   arrows lie between the zoom button and the item after them.
    /// - **Control.** "Visible" means something only if `visibleItems` can
    ///   leave an item out here, and a 1200 pt window fits everything. So the
    ///   sidebar is then narrowed below what its section's items need, and
    ///   one of them must leave `visibleItems` while it stays in `items`, as
    ///   the spec's "Width" says AppKit drops an item that does not fit its
    ///   section. Which one AppKit drops, and whether it squeezes the filter
    ///   first, is AppKit's choice, so any of the four counts. The title, in
    ///   the wide main section, must stay visible, so an empty `visibleItems`
    ///   cannot pass for a drop.
    @Test func toggleAndArrowsSurviveACollapse() async throws {
        let fixture = ToolbarFixture(label: "toggleAndArrowsSurviveACollapse")
        defer { fixture.tearDown() }
        try await fixture.ready()

        let toggle = try #require(fixture.controller.item(MainToolbarItemID.toggleSidebar))
        #expect(toggle.target === fixture.split)
        #expect(toggle.action == #selector(NSSplitViewController.toggleSidebar(_:)))
        #expect(toggle.isBordered == false)
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
        #expect(shown.buttonsMaxX <= shownFilter.minX)
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
        #expect(collapsed.buttonsMaxX <= collapsed.title.minX)
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
        #expect(reshown.buttonsMaxX <= reshownFilter.minX)
        #expect(reshownFilter.maxX <= reshown.dividerX)
        #expect(reshown.dividerX <= reshown.title.minX)

        // Control: a sidebar too narrow for its section's items drops one.
        let narrow = MainToolbarMetrics.windowButtonsWidth + MainToolbarMetrics.iconItemWidth
        try #require(narrow < MainToolbarMetrics.sidebarMinimumThickness)
        // Minimum first, so the minimum never exceeds the maximum.
        fixture.split.sidebarItem.minimumThickness = narrow
        fixture.split.sidebarItem.maximumThickness = narrow
        fixture.split.splitView.setPosition(narrow, ofDividerAt: 0)
        let narrowed = try await waitForMainActorCondition("the sidebar to narrow to \(narrow) pt") {
            fixture.window.layoutIfNeeded()
            guard let pane = fixture.sidebarPane else { return false }
            return abs(pane.frame.width - narrow) < 1
        }
        try #require(narrowed)
        let sidebarSection: [NSToolbarItem.Identifier] = leading + [MainToolbarItemID.repoFilter]
        let dropped = try await waitForMainActorCondition("an item of the narrowed sidebar's section to leave visibleItems") {
            fixture.window.layoutIfNeeded()
            let visible = fixture.visibleIdentifiers
            let present = Set(fixture.identifiers)
            let droppedOne = sidebarSection.contains { present.contains($0) && !visible.contains($0) }
            return droppedOne && visible.contains(MainToolbarItemID.title)
        }
        try #require(dropped)
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
        #expect(back.isEnabled == true)
        #expect(forward.isEnabled == false)
        #expect(back.isNavigational == false)
        #expect(forward.isNavigational == false)
        #expect(back.isBordered == false)
        #expect(forward.isBordered == false)

        snapshot.canGoBack = false
        snapshot.canGoForward = true
        fixture.controller.apply(snapshot)
        #expect(back.isEnabled == false)
        #expect(forward.isEnabled == true)
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
    /// ours back on a closing window. Another toolbar after the removal is
    /// still a replacement of ours: it counts once and is put back.
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

        window.toolbar = NSToolbar(identifier: "MainToolbarControllerTests.afterRemoval")
        #expect(controller.recentReplacements.count == 1)
        let back = try await waitForMainActorCondition("a toolbar set after the removal to be replaced by ours") {
            window.toolbar === controller.toolbar
        }
        #expect(back)
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

    // MARK: - Menu projections

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
    /// window has a zoom button, the split a sidebar pane, and the title
    /// view a place in the window.
    func edges() -> ToolbarEdges? {
        window.layoutIfNeeded()
        guard let zoom = window.standardWindowButton(.zoomButton),
              let pane = sidebarPane,
              let title = Self.placedFrame(of: titleView, in: window) else { return nil }
        return ToolbarEdges(
            buttonsMaxX: zoom.convert(zoom.bounds, to: nil).maxX,
            dividerX: pane.convert(pane.bounds, to: nil).maxX,
            filter: filterPopup.flatMap { Self.placedFrame(of: $0, in: window) },
            title: title)
    }

    /// `view`'s frame in window coordinates, once it sits in `window` with a
    /// width.
    static func placedFrame(of view: NSView, in window: NSWindow) -> NSRect? {
        guard view.window === window, view.frame.width > 0 else { return nil }
        return view.convert(view.bounds, to: nil)
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

/// Where the toolbar's publicly framed parts sit, in window coordinates: the
/// window buttons' trailing edge, the divider the tracking separator follows,
/// and the two view-based items. An image item, such as the toggle or an
/// arrow, has no public frame, so it is placed against these by order.
private struct ToolbarEdges {
    /// The zoom button's trailing edge, where the window buttons end.
    var buttonsMaxX: CGFloat
    /// The sidebar pane's trailing edge, where the first divider sits.
    var dividerX: CGFloat
    /// The filter popup, while it is in the toolbar and laid out.
    var filter: NSRect?
    var title: NSRect

    /// The sidebar shown: the filter right of the window buttons and left of
    /// the divider, and the title right of the divider.
    var placedOverAShownSidebar: Bool {
        guard let filter else { return false }
        return buttonsMaxX <= filter.minX && filter.maxX <= dividerX && dividerX <= title.minX
    }

    /// The sidebar collapsed: the title right of the window buttons and left
    /// of `shownDividerX`, where the shown sidebar ended.
    func placedBesideTheWindowButtons(shownDividerX: CGFloat) -> Bool {
        buttonsMaxX <= title.minX && title.minX < shownDividerX
    }
}
