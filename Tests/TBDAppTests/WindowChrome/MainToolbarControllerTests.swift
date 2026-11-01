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
        let other = MainToolbarController(appState: fixture.state, titleView: NSView(), requestRemoteStop: { _ in })
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
    /// the app. The nesting is meant to keep AppKit's own sidebar discovery
    /// from standing in for the controller's binding, but AppKit may still
    /// find a split nested as a child view controller, so this pins the
    /// binding's outcome without proving discovery would have missed it.
    @Test func trackingSeparatorFollowsANestedSplit() async throws {
        let fixture = ToolbarFixture(label: "trackingSeparatorFollowsANestedSplit", nested: true)
        defer { fixture.tearDown() }
        try #require(fixture.window.contentViewController !== fixture.split)
        try #require(fixture.split.parent === fixture.window.contentViewController)
        try await fixture.ready()

        let separator = try #require(
            fixture.controller.item(.sidebarTrackingSeparator) as? NSTrackingSeparatorToolbarItem)
        let bound: NSSplitView? = separator.splitView
        #expect(bound === fixture.split.splitView)
        #expect(separator.dividerIndex == 0)
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

        // Not animated: an offscreen window need not run an animation through.
        fixture.split.sidebarItem.isCollapsed = true
        let filterLeft = try await waitForMainActorCondition("the filter to leave on collapse") {
            !fixture.identifiers.contains(MainToolbarItemID.repoFilter)
        }
        try #require(filterLeft)
        let collapsedLeading = Array(fixture.identifiers.prefix(3))
        #expect(collapsedLeading == leading)
        #expect(fixture.identifiers == fixture.expectedIdentifiers())
        let leadingVisible = try await waitForMainActorCondition("the toggle and arrows to be visible") {
            fixture.window.layoutIfNeeded()
            let visible = Set((fixture.controller.toolbar.visibleItems ?? []).map { $0.itemIdentifier })
            return leading.allSatisfy { visible.contains($0) }
        }
        #expect(leadingVisible)

        fixture.split.sidebarItem.isCollapsed = false
        let filterBack = try await waitForMainActorCondition("the filter to return on expansion") {
            fixture.identifiers.contains(MainToolbarItemID.repoFilter)
        }
        try #require(filterBack)
        let expanded = fixture.identifiers
        let filterIndex = try #require(expanded.firstIndex(of: MainToolbarItemID.repoFilter))
        let separatorIndex = try #require(expanded.firstIndex(of: .sidebarTrackingSeparator))
        #expect(filterIndex < separatorIndex)
        let expandedLeading = Array(expanded.prefix(3))
        #expect(expandedLeading == leading)
        #expect(expanded == fixture.expectedIdentifiers())
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

        // The sidebar at its widest, so the leading section's fit is not what
        // these tests measure; the minimum width is the live check's.
        let size = ToolbarFixture.windowSize
        let sidebarWidth = MainToolbarMetrics.sidebarMaximumThickness
        let split = MainSplitViewController(
            sidebar: ToolbarFixture.makePane(width: sidebarWidth),
            content: ToolbarFixture.makePane(width: size.width - sidebarWidth),
            autosaveName: nil)
        let titleView = NSTextField(labelWithString: "feature")
        let controller = MainToolbarController(
            appState: state, titleView: titleView, requestRemoteStop: { _ in }, now: now, clock: clock)
        split.onViewDidAppear = { [weak controller, weak split] window in
            guard let controller, let split else { return }
            controller.install(on: window, split: split)
        }
        self.split = split
        self.titleView = titleView
        self.controller = controller

        let window = NSWindow(
            contentRect: NSRect(origin: ToolbarFixture.offscreenOrigin, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.window = window

        controller.requestRemoteStop = { [weak self] selection in
            self?.stopRequests.append(selection)
        }

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
        window.setFrameOrigin(ToolbarFixture.offscreenOrigin)
        window.orderFront(nil)
    }

    /// Installs the toolbar directly as well, so only `installsOnAppear`
    /// depends on `viewDidAppear` arriving, then waits for the first apply
    /// and for no further apply to be queued, so a test starts with nothing
    /// pending that could stand in for the trigger it is about.
    func ready() async throws {
        controller.install(on: window, split: split)
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
        window.orderOut(nil)
        window.toolbar = nil
        window.contentViewController = nil
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
