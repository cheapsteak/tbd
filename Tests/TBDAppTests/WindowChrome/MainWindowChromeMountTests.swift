import AppKit
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 2: the whole `ContentView` hosted in an offscreen window. Waits are
// bounded: pump counts for the mount, `pollUntilTrue` for main-queue work.

/// `ContentView` mounts a `MainSplitViewController` and puts a
/// `MainToolbarController`'s toolbar on the window. Unlike the toolbar
/// controller's own suite, which builds the split into a window by hand, this
/// is the production hosting path: the split inside SwiftUI's hosting view,
/// reached through `MainWindowSplitView`. Spec:
/// docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window structure"
/// and "Testing".
///
/// The toolbar is applied through `DispatchQueue.main.async`, so waits on it
/// suspend (`waitForMainActorCondition`, over `pollUntilTrue`) rather than pump
/// (Tests/CLAUDE.md, "`@MainActor` tests: suspend to drain, never pump").
@MainActor
@Suite("Main window chrome mount")
struct MainWindowChromeMountTests {
    // MARK: - Structure

    @Test func mountsTheSplitAndToolbar() async throws {
        let mount = ChromeMount(label: "mounts")
        defer { mount.tearDown() }
        let controller = try await mount.appKitReady()

        #expect(mount.splitRoots.count == 1)
        #expect(mount.host.window.toolbar?.delegate is MainToolbarController)
        #expect(controller.split === mount.mountedSplit)

        // Nothing of SwiftUI's toolbar: every item is one the AppKit toolbar
        // declares.
        let identifiers = mount.toolbarIdentifiers
        let allowed = Set(MainToolbarItemID.allowed)
        let stray = identifiers.filter { !allowed.contains($0) }
        #expect(identifiers.contains(MainToolbarItemID.leadingButtons))
        #expect(stray.isEmpty)

        // The state's store is a test suite, not `.standard`, so the divider
        // autosaves nowhere.
        let split = try #require(mount.mountedSplit)
        #expect(split.splitView.autosaveName == nil)

        // The sidebar pane holds exactly one native sidebar.
        let sidebarPane = split.sidebarItem.viewController.view
        let nativeSidebar = try await waitForMainActorCondition("the hosted sidebar to mount the native outline") {
            ChromeMount.nativeSidebarRoots(in: sidebarPane).count == 1
        }
        #expect(nativeSidebar)

        // The detail starts below the toolbar. Asserted on that outcome, the
        // detail's top edge against the window's content layout rect, rather
        // than on `safeAreaInsets.top > 0`: it holds however AppKit and
        // SwiftUI share the inset between them, and an inset SwiftUI ignored
        // would still pass the other. The first wait makes it non-vacuous: the
        // layout rect must already leave room for the toolbar, not only the
        // titlebar.
        let toolbarTakesRoom = try await waitForMainActorCondition(
            "the toolbar to take room above the content layout rect"
        ) {
            mount.heightAboveContentLayout > ChromeMount.titlebarOnlyHeight
        }
        try #require(toolbarTakesRoom)
        let detailBelowToolbar = try await waitForMainActorCondition("the hosted detail to start below the toolbar") {
            mount.detailStartsBelowToolbar(in: split)
        }
        #expect(detailBelowToolbar)
    }

    /// The status bar is the content pane's, not the window's. The split
    /// reaches the bottom of the window's root, so the sidebar column runs to
    /// the window's bottom edge, and the content pane ends its detail area one
    /// bottom-bar height above the pane's foot: the band `StatusBarView`
    /// fills. With the bar below the split instead, the split would end above
    /// the root's bottom and the detail would reach the pane's foot. Nothing
    /// is selected, so the band is the bar's fixed height, not its content's.
    ///
    /// The content pane is the hosting controller's own view, the root the
    /// SwiftUI pane lays out in, so the band is measured inside the pane
    /// whatever frame the split gives it.
    @Test func statusBarSitsAtTheFootOfTheContentPane() async throws {
        let mount = ChromeMount(label: "statusBar")
        defer { mount.tearDown() }
        _ = try await mount.appKitReady()
        let split = try #require(mount.mountedSplit)

        _ = try await waitForMainActorCondition("the split to reach the window's foot over a status bar band") {
            mount.bottomEdges(in: split)?.placeTheStatusBarInTheContentPane == true
        }
        let edges = try #require(mount.bottomEdges(in: split), "The content pane never laid out its detail area")
        #expect(abs(edges.splitAboveRoot) < 0.5)
        #expect(abs(edges.bandBelowDetail - WindowBottomBarMetrics.height) < 0.5)
    }

    /// The sidebar column has no bar of its own: `SidebarView` holds only the
    /// native sidebar, which fills the sidebar pane down to the pane's foot,
    /// so a bar beneath the native sidebar would leave a band between the
    /// native sidebar's foot and the pane's. On macOS 26 the sidebar item is
    /// AppKit's floating glass sidebar: AppKit puts the pane in a glass view
    /// inset 8 pt from the split item's leading, top and bottom edges
    /// (measured on macOS 26.6), so this test does not assert where the pane
    /// ends. That the split reaches the window's foot is
    /// `statusBarSitsAtTheFootOfTheContentPane()`'s assertion.
    @Test func nothingSitsBeneathTheNativeSidebar() async throws {
        let mount = ChromeMount(label: "sidebarFoot")
        defer { mount.tearDown() }
        _ = try await mount.appKitReady()
        let split = try #require(mount.mountedSplit)

        _ = try await waitForMainActorCondition("the native sidebar to reach the sidebar pane's foot") {
            mount.sidebarBottomEdges(in: split)?.sidebarReachesThePanesFoot == true
        }
        let edges = try #require(mount.sidebarBottomEdges(in: split), "The native sidebar never laid out")
        let sidebarGap = abs(edges.sidebarAbovePane)
        #expect(sidebarGap < 0.5, "The native sidebar ends \(edges.sidebarAbovePane) pt above its pane's foot")
    }

    /// The divider autosaves only into the real store, where `NSSplitView`
    /// writes it: never into a test's suite or `TBD_MOCK`'s.
    @Test func dividerAutosavesOnlyForTheStandardStore() {
        let suite = TestDefaultsSuite("MainWindowChromeMountTests.autosave")
        defer { suite.tearDown() }
        let standardName = MainWindowSplitView.splitAutosaveName(for: .standard)
        let suiteName = MainWindowSplitView.splitAutosaveName(for: suite.defaults)
        #expect(standardName == "TBDMainWindowSplit")
        #expect(suiteName == nil)
    }

    // MARK: - Hosted panes' storage

    /// Each pane the split hosts, the sidebar, the detail and the title,
    /// reads `@AppStorage` from the store `ContentView` was given for them,
    /// which here mirrors the root's `.defaultAppStorage`, not from
    /// `.standard`: a hosted tree starts from a fresh environment. Observed
    /// through the probe the split draws behind each real pane's root, inside
    /// the environment it gives that root (`\.hostedPaneProbe`), on a key
    /// `.standard` never holds, written two different values in turn, so a
    /// pane's probe follows the writes only by reading the suite. A pane built
    /// without that environment draws no probe and fails the first wait.
    @Test func hostedPanesReadTheGivenStore() async throws {
        let reads = PaneStoreReads()
        let mount = ChromeMount(label: "hostedStore", hostedPaneProbe: { pane in
            AnyView(PaneStoreProbe(pane: pane, reads: reads))
        })
        defer { mount.tearDown() }
        _ = try await mount.appKitReady()
        // The title draws nothing, so nothing behind it, until a worktree is
        // selected.
        mount.state.selectedWorktreeIDs = [mount.worktrees[0].id]

        let allPanes = Set(MainWindowSplitView.HostedPane.allCases)
        _ = try await waitForMainActorCondition("a store probe to evaluate in every hosted pane") {
            reads.panes == allPanes
        }
        let probed = reads.panes
        try #require(probed == allPanes, "A pane with no probe would make the reads below vacuous for it")

        for value in ["acme-one", "acme-two"] {
            mount.suite.defaults.set(value, forKey: storeProbeKey)
            let expected = PaneStoreReads.everyPane(reading: value)
            _ = try await waitForMainActorCondition("every hosted pane to read \(value) from the suite") {
                reads.values == expected
            }
            // A pane still at "unset" read `.standard`.
            let observed = reads.values
            try #require(observed == expected)
        }
    }

    /// The app builds `ContentView` without the seam, so its hosted panes get
    /// no store of their own and keep `.standard`, the store the window's
    /// root and the menu commands read. The seam carries a test's store.
    @Test func hostedStoreIsNilWithoutTheSeam() {
        let suite = TestDefaultsSuite("MainWindowChromeMountTests.seam")
        defer { suite.tearDown() }
        let app = ContentView()
        let seamed = ContentView(hostedAppStorage: suite.defaults)
        #expect(app.hostedAppStorage == nil)
        #expect(seamed.hostedAppStorage === suite.defaults)
    }

    // MARK: - The toolbar in the hosted window

    /// Positive control for `toolbarSurvivesAnAppStateChange`: in this
    /// harness, a root hosting view given `.all` does bridge the scene, so
    /// SwiftUI puts a toolbar on the window for a tree that declares one.
    /// The root is a test-only view whose one job is to declare a toolbar
    /// item, mounted in the same titled window at the same size as
    /// `ChromeMount`'s. The root hosting view is a subview of the host's
    /// ground, not the window's content view; without this, the survival test
    /// could pass only because SwiftUI never reached the window's toolbar.
    @Test func harnessBridgesASceneToolbarOntoTheWindow() async throws {
        let host = OffscreenHost(
            root: ToolbarDeclaringRoot(), size: ChromeMount.size, styleMask: ChromeMount.styleMask,
            sceneBridgingOptions: .all)
        defer {
            host.window.toolbar = nil
            host.tearDown()
        }

        let bridged = try await waitForMainActorCondition("SwiftUI to put the scene's toolbar on the window") {
            host.window.toolbar != nil
        }
        try #require(bridged)
        let swiftUIOwned = !(host.window.toolbar?.delegate is MainToolbarController)
        #expect(swiftUIOwned)
    }

    /// Review focus 1: a SwiftUI update of the window's hierarchy must leave
    /// the AppKit toolbar on the window, or the next apply must put it back.
    /// The root hosting view bridges the scene, as the app window's root does,
    /// so SwiftUI is free to claim the window's toolbar; that the bridging is
    /// live in this harness is `harnessBridgesASceneToolbarOntoTheWindow`'s
    /// job, and this test proves nothing without it passing.
    @Test func toolbarSurvivesAnAppStateChange() async throws {
        let mount = ChromeMount(label: "survives", sceneBridgingOptions: .all)
        defer { mount.tearDown() }
        let controller = try await mount.appKitReady()
        let toolbar = controller.toolbar
        try #require(mount.host.window.toolbar === toolbar)

        let state = mount.state
        let repoID = mount.repo.id
        let worktreeID = mount.worktrees[1].id
        state.repoFilter = repoID
        state.selectedWorktreeIDs = [worktreeID]

        // Both sides took the change: the toolbar applied it, and
        // `ContentView`'s own `onChange` ran in a SwiftUI update.
        let landed = try await waitForMainActorCondition("the toolbar and ContentView to take the change") {
            controller.appliedSnapshot?.filter.selected == repoID
                && state.recentlyVisitedWorktreeIDs.first == worktreeID
        }
        try #require(landed)
        // A few more turns for anything SwiftUI does to the window after that.
        await mount.host.pump(times: 10)

        #expect(mount.host.window.toolbar === toolbar)
        #expect(mount.host.window.toolbar?.delegate === controller)
        let identifiers = mount.toolbarIdentifiers
        let allowed = Set(MainToolbarItemID.allowed)
        let stray = identifiers.filter { !allowed.contains($0) }
        #expect(stray.isEmpty)
    }

    /// The toolbar's tracking separator is bound to the split, with the split
    /// inside SwiftUI's hosting view as in the app, rather than in a container
    /// a test built. It is the item the toolbar made for TBD's own identifier,
    /// and no item for the standard `.sidebarTrackingSeparator`, which AppKit
    /// would build and bind itself, is on the toolbar beside it.
    @Test func bindsTheTrackingSeparatorToTheHostedSplit() async throws {
        let mount = ChromeMount(label: "trackingSeparator")
        defer { mount.tearDown() }
        _ = try await mount.appKitReady()

        let hasSeparator = try await waitForMainActorCondition("a tracking separator in the window's toolbar") {
            mount.trackingSeparator != nil
        }
        try #require(hasSeparator)
        let separator = try #require(mount.trackingSeparator)
        let split = try #require(mount.mountedSplit)
        try #require(split.view.isDescendant(of: mount.host.hostingView))

        let bound: NSSplitView? = separator.splitView
        #expect(bound === split.splitView)
        #expect(separator.dividerIndex == 0)
        let standard = NSToolbarItem.Identifier.sidebarTrackingSeparator
        #expect(!mount.toolbarIdentifiers.contains(standard))
    }

    // MARK: - The title

    /// The title view's width never follows its text: the hosting view
    /// `makeTitleView(_:)` builds reports the constant ideal width as its
    /// intrinsic width, and the same fitting width, for a short title and a
    /// long one. The same two titles in plain hosting views differ widely,
    /// so a width that followed the text would show.
    @Test func titleViewWidthDoesNotFollowItsText() throws {
        let short = Text("main")
        let long = Text(String(repeating: "acme-widgets-", count: 8))
        let shortPlain = NSHostingView(rootView: short).fittingSize.width
        let longPlain = NSHostingView(rootView: long).fittingSize.width
        try #require(shortPlain > 0)
        try #require(longPlain > shortPlain + 100)

        let shortView = MainWindowSplitView.makeTitleView(short)
        let longView = MainWindowSplitView.makeTitleView(long)
        #expect(shortView.intrinsicContentSize.width == MainToolbarMetrics.titleIdealWidth)
        #expect(longView.intrinsicContentSize.width == MainToolbarMetrics.titleIdealWidth)
        #expect(shortView.fittingSize.width == longView.fittingSize.width)
    }

    /// In the mounted window, with the production title view, the title item
    /// keeps its frame as the selected worktree's title goes from short to
    /// long and back, and starts at or after the divider the tracking
    /// separator follows. Each step waits for the toolbar to take the new
    /// title, then gives the hosted title a few turns to draw it: a title
    /// item sized to its text would have changed width by then. The server
    /// fetch each selection makes answers an empty list rather than reaching
    /// for a daemon.
    @Test func titleStaysPutAsTheTitleChanges() async throws {
        let mount = ChromeMount(label: "titleStaysPut")
        defer { mount.tearDown() }
        mount.state.devServerListFetcher = { worktreeID, _ in
            DevServerListResult(worktreeID: worktreeID, servers: [], parseErrors: [], runningFileDiagnostics: [])
        }
        let controller = try await mount.appKitReady()
        let split = try #require(mount.mountedSplit)
        let shortWorktree = mount.worktrees[0]
        let longWorktree = Worktree(
            repoID: mount.repo.id, name: "long", displayName: String(repeating: "acme-widgets-", count: 5) + "panel",
            branch: "long", path: "/tmp/acme-long", tmuxServer: "acme")
        mount.state.worktrees[mount.repo.id, default: []].append(longWorktree)

        let shortFound = try await mount.placedTitleFrame(
            selecting: shortWorktree.id, titled: shortWorktree.displayName, controller: controller)
        let shortFrame = try #require(shortFound)
        let longFound = try await mount.placedTitleFrame(
            selecting: longWorktree.id, titled: longWorktree.displayName, controller: controller)
        let longFrame = try #require(longFound)
        let backFound = try await mount.placedTitleFrame(
            selecting: shortWorktree.id, titled: shortWorktree.displayName, controller: controller)
        let backFrame = try #require(backFound)

        #expect(longFrame.width == shortFrame.width)
        #expect(backFrame.width == shortFrame.width)
        #expect(longFrame.minX == shortFrame.minX)
        #expect(backFrame.minX == shortFrame.minX)
        let pane = try #require(split.splitView.arrangedSubviews.first)
        let dividerX = pane.convert(pane.bounds, to: nil).maxX
        #expect(dividerX <= shortFrame.minX)
        #expect(dividerX <= longFrame.minX)
    }

    // MARK: - The selection's server refresh

    /// `ContentView`'s `.task(id:)` fetches a selected worktree's servers, and
    /// the list landing, which the status bar's Servers chip reads, is what
    /// that fetch is for.
    @Test func selectionRefreshesTheSelectedWorktreesServers() async throws {
        let mount = ChromeMount(label: "servers")
        defer { mount.tearDown() }
        let fetches = mount.recordServerFetches()
        _ = try await mount.appKitReady()

        let worktreeID = mount.worktrees[1].id
        try #require(mount.state.devServerLists[worktreeID] == nil)
        mount.state.selectedWorktreeIDs = [worktreeID]

        let fetched = try await waitForMainActorCondition("the selection's server fetch") {
            fetches.worktreeIDs.contains(worktreeID)
        }
        #expect(fetched)
        let landed = try await waitForMainActorCondition("the selected worktree's server list") {
            mount.state.devServerLists[worktreeID] != nil
        }
        #expect(landed)
    }

    // MARK: - Tabs in the toolbar

    /// With a worktree's tab bar showing, the toolbar's items end at the
    /// tracking separator and the main pane's row takes the toolbar row's
    /// clicks: a hit test at every point along the row's midline over the
    /// visible part of the pane, a tab's centre among them, reaches a view
    /// inside the pane, the worktree's own view and the row's drag gap among
    /// them, and never a toolbar viewer.
    @Test func theRowTakesTheToolbarRowsClicks() async throws {
        let mount = ChromeMount(label: "rowClicks")
        defer { mount.tearDown() }
        _ = try await mount.appKitReady()
        let split = try #require(mount.mountedSplit)
        mount.showSingleWorktree()

        let what = "the main pane's row to take the toolbar row's clicks"
        let log = RowWaitLog()
        let drawn = try await waitForMainActorCondition(what) {
            mount.keepConnected()
            let row = mount.observeRow(in: split)
            return log.note(row, clauses: [
                ("the toolbar ends at the tracking separator",
                 mount.toolbarIdentifiers.last == MainToolbarItemID.sidebarSeparator),
                ("every point reaches the pane", row.allInPane),
                ("no point reaches the title bar or a toolbar item", !row.anyOutsideContent),
                ("a point reaches the worktree's view", row.anyInWorktreeView),
                ("a point reaches the drag gap", row.reachesDragGap),
            ])
        }
        if !drawn {
            Issue.record(RowWaitTimedOut(what: what, observed: log.last))
        }
        #expect(drawn)
        let identifiers = mount.toolbarIdentifiers
        let expected: [NSToolbarItem.Identifier] = [
            MainToolbarItemID.leadingButtons, .flexibleSpace, MainToolbarItemID.repoFilter,
            MainToolbarItemID.sidebarSeparator,
        ]
        #expect(identifiers == expected)
    }

    /// The main pane's row is the toolbar's height, the content pane's top
    /// safe-area inset, and starts at the pane's top edge, so its centre is
    /// the toolbar row's midline. Measured on the row's drag gap, which spans
    /// the row's height.
    @Test func theRowIsTheTopSafeAreaInsetTall() async throws {
        let mount = ChromeMount(label: "rowHeight")
        defer { mount.tearDown() }
        _ = try await mount.appKitReady()
        let split = try #require(mount.mountedSplit)
        let pane = split.contentItem.viewController.view
        mount.showSingleWorktree()

        let measured = try await waitForMainActorCondition("the row to lay out at the toolbar's height") {
            mount.keepConnected()
            let inset = pane.safeAreaInsets.top
            guard inset > ChromeMount.titlebarOnlyHeight,
                  mount.state.windowChrome.topSafeAreaInset == inset,
                  let gap = mount.dragGapFrames(in: split).first else { return false }
            let paneTop = pane.convert(pane.bounds, to: nil).maxY
            return abs(gap.height - inset) < 0.5 && abs(gap.maxY - paneTop) < 0.5
        }
        #expect(measured)
    }

    /// With the sidebar collapsed, the toolbar's leading item still sits over
    /// the main pane's top-left corner and takes its own
    /// clicks: a hit test on Back returns the toolbar's button. The row
    /// starts past it, and every point from there on reaches the pane, the
    /// drag gap among them, never a toolbar viewer.
    @Test func withTheSidebarCollapsedBackStaysTheToolbars() async throws {
        let mount = ChromeMount(label: "rowCollapsed")
        defer { mount.tearDown() }
        let controller = try await mount.appKitReady()
        let split = try #require(mount.mountedSplit)
        mount.showSingleWorktree()
        split.sidebarItem.isCollapsed = true

        let chrome = mount.state.windowChrome
        let what = "the collapsed toolbar and the row past its leading item"
        let log = RowWaitLog()
        let settled = try await waitForMainActorCondition(what) {
            mount.keepConnected()
            let expected: [NSToolbarItem.Identifier] = [
                MainToolbarItemID.leadingButtons, MainToolbarItemID.sidebarSeparator,
            ]
            let edge = chrome.leadingItemTrailingEdge ?? 0
            let rowStart = MainTabRowMetrics.leadingInset(leadingItemTrailingEdge: edge)
            let row = mount.observeRow(in: split, from: rowStart + 4)
            return log.note(row, clauses: [
                ("the toolbar shows only the leading item and the separator",
                 mount.toolbarIdentifiers == expected),
                ("the published leading edge reaches over the pane", edge > 0),
                ("every point past the row's start reaches the pane", row.allInPane),
                ("no point reaches the title bar or a toolbar item", !row.anyOutsideContent),
                ("a point reaches the drag gap", row.reachesDragGap),
            ])
        }
        if !settled {
            Issue.record(RowWaitTimedOut(what: what, observed: log.last))
        }
        try #require(settled)

        let host = try #require(
            controller.item(MainToolbarItemID.leadingButtons)?.view as? LeadingToolbarButtonsHost)
        let back = try #require(host.backButton)
        let frameView = try #require(mount.host.window.contentView?.superview)
        let centre = back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil)
        let hit = frameView.hitTest(centre)
        let reachesBack = hit.map { $0 === back || $0.isDescendant(of: back) } ?? false
        if !reachesBack {
            let hitClass = hit.map { String(describing: type(of: $0)) } ?? "nil"
            Issue.record(RowWaitTimedOut(
                what: "a hit test at Back's centre \(centre) to reach Back",
                observed: "hit \(hitClass), Back \(back.convert(back.bounds, to: nil)), "
                    + "frame view bounds \(frameView.bounds)"))
        }
        #expect(reachesBack)
        // The row's start lies past the leading item it clears.
        let leadingEnd = host.convert(host.bounds, to: nil).maxX
        let pane = split.contentItem.viewController.view
        let paneStart = pane.convert(pane.bounds, to: nil).minX
        let rowStart = paneStart + MainTabRowMetrics.leadingInset(leadingItemTrailingEdge: chrome.leadingItemTrailingEdge)
        #expect(rowStart > leadingEnd)
    }

    // MARK: - Dismantling

    /// SwiftUI dismantling the split takes the AppKit toolbar off the window,
    /// and leaves a toolbar something else put there.
    @Test func dismantleTakesOnlyItsOwnToolbarOffTheWindow() throws {
        let suite = TestDefaultsSuite("MainWindowChromeMountTests.dismantle")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)

        let ownSplit = Self.makeSplit()
        let ownWindow = Self.makeWindow(over: ownSplit)
        let own = MainWindowSplitView.Coordinator()
        own.toolbarController = MainToolbarController(
            appState: state, split: ownSplit, titleView: NSView(), requestRemoteStop: { _ in })
        own.toolbarController?.install(on: ownWindow)
        ownSplit.onViewDidAppear = { _ in }
        try #require(ownWindow.toolbar != nil)
        try #require(ownWindow.toolbar === own.toolbarController?.toolbar)

        MainWindowSplitView.dismantleNSViewController(ownSplit, coordinator: own)
        #expect(ownWindow.toolbar == nil)
        #expect(own.toolbarController == nil)
        let appearHookCleared = ownSplit.onViewDidAppear == nil
        #expect(appearHookCleared)

        let otherSplit = Self.makeSplit()
        let otherWindow = Self.makeWindow(over: otherSplit)
        let replaced = MainWindowSplitView.Coordinator()
        replaced.toolbarController = MainToolbarController(
            appState: state, split: otherSplit, titleView: NSView(), requestRemoteStop: { _ in })
        replaced.toolbarController?.install(on: otherWindow)
        let other = NSToolbar(identifier: "MainWindowChromeMountTests.other")
        otherWindow.toolbar = other

        MainWindowSplitView.dismantleNSViewController(otherSplit, coordinator: replaced)
        #expect(otherWindow.toolbar === other)
        #expect(replaced.toolbarController == nil)
    }

    // MARK: - Helpers

    /// A titled window, never shown, over `split`: a toolbar belongs to a
    /// titlebar, and its tracking separator follows a split in its window.
    private static func makeWindow(over split: MainSplitViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ChromeMount.size),
            styleMask: ChromeMount.styleMask, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The window takes its size from the view; start it at the final one.
        split.view.setFrameSize(ChromeMount.size)
        window.contentViewController = split
        window.setContentSize(ChromeMount.size)
        return window
    }

    private static func makeSplit() -> MainSplitViewController {
        MainSplitViewController(sidebar: makePane(), content: makePane(), autosaveName: nil)
    }

    private static func makePane() -> NSViewController {
        let pane = NSViewController()
        pane.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: ChromeMount.size.height))
        return pane
    }
}

// MARK: - Fixture

/// `ContentView`, its `AppState` holding a repo and two worktrees, hosted
/// offscreen in a titled window at the app's default size.
@MainActor
private final class ChromeMount {
    static let size = NSSize(width: 1200, height: 800)
    /// Titled, as the app's window is: the AppKit toolbar needs a titlebar.
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    let suite: TestDefaultsSuite
    let state: AppState
    let repo: Repo
    let worktrees: [Worktree]
    let host: OffscreenHost<AnyView>
    /// The AppKit toolbar's controller once `appKitReady()` found it, kept so
    /// `tearDown()` reaches it even when another toolbar is on the window.
    private weak var readyController: MainToolbarController?

    /// - Parameters:
    ///   - sceneBridgingOptions: for the root hosting view; `nil` keeps
    ///     `NSHostingView`'s default.
    ///   - hostedPaneProbe: set on the root as `\.hostedPaneProbe`, for the
    ///     split to draw behind each pane it hosts.
    init(
        label: String, sceneBridgingOptions: NSHostingSceneBridgingOptions? = nil,
        hostedPaneProbe: (@MainActor (MainWindowSplitView.HostedPane) -> AnyView)? = nil
    ) {
        let suite = TestDefaultsSuite("MainWindowChromeMountTests.\(label)")
        self.suite = suite
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let worktrees = [
            Worktree(repoID: repo.id, name: "main", displayName: "main", branch: "main",
                     path: "/tmp/acme", status: .main, tmuxServer: "acme"),
            Worktree(repoID: repo.id, name: "feature", displayName: "feature", branch: "feature",
                     path: "/tmp/acme-feature", tmuxServer: "acme"),
        ]
        state.repos = [repo]
        state.worktrees = [repo.id: worktrees]
        // Run and answered before the mount, so `ContentView.onAppear`'s call
        // finds the check done and no "tmux Not Found" alert can be raised
        // over the window, whatever the runner's PATH holds.
        state.checkTmuxAvailabilityAtStartup()
        state.dismissTmuxLocationPrompt()
        self.state = state
        self.repo = repo
        self.worktrees = worktrees

        // A themes directory that does not exist, so the appearance's lookup
        // misses deterministically instead of reading the real `~/tbd`.
        let appearance = AppearanceSettings(
            defaults: suite.defaults,
            userThemesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("TBDAppTests.MainWindowChromeMount.\(UUID().uuidString)"))
        // The hosted panes get the suite too: they do not inherit the root's
        // `.defaultAppStorage` below.
        let root = ContentView(hostedAppStorage: suite.defaults)
            .environment(\.hostedPaneProbe, hostedPaneProbe)
            .environment(state)
            .environmentObject(appearance)
            .environmentObject(TranscriptOverlayCoordinator())
            .defaultAppStorage(suite.defaults)
        host = OffscreenHost(
            root: AnyView(root), size: ChromeMount.size, styleMask: ChromeMount.styleMask,
            sceneBridgingOptions: sceneBridgingOptions)
        // The app's own main window chrome, through the function the app
        // applies it with: a transparent title bar, among the rest, is what
        // lets a click under the toolbar reach the content.
        MainWindowChrome.apply(to: host.window)
    }

    /// Takes the toolbar off the window before the host goes, so the window
    /// shell AppKit keeps holds none of ours whatever SwiftUI's teardown does.
    /// The AppKit toolbar's controller is uninstalled first, so its watch on
    /// `window.toolbar` does not put the toolbar back.
    func tearDown() {
        (readyController ?? toolbarController)?.uninstall()
        host.window.toolbar = nil
        host.tearDown()
        suite.tearDown()
    }

    /// Waits for the split to mount and for its appearance to install the
    /// toolbar and apply it once, and returns the toolbar's controller.
    func appKitReady() async throws -> MainToolbarController {
        let splitMounted = await host.settle { !self.splitRoots.isEmpty }
        try #require(splitMounted, "The AppKit split never mounted")
        let installed = try await waitForMainActorCondition("the AppKit toolbar to be installed and applied") {
            self.toolbarController?.appliedSnapshot != nil
        }
        try #require(installed)
        let controller = try #require(toolbarController)
        readyController = controller
        return controller
    }

    /// Selects `worktreeID`, waits for the toolbar to take `title` and gives
    /// the hosted title a few turns to draw it, then returns the title view's
    /// frame in window coordinates after a layout pass, or nil when it is not
    /// placed in the window.
    func placedTitleFrame(
        selecting worktreeID: UUID, titled title: String, controller: MainToolbarController
    ) async throws -> NSRect? {
        state.selectedWorktreeIDs = [worktreeID]
        let taken = try await waitForMainActorCondition("the toolbar to take the title \(title)") {
            controller.appliedSnapshot?.title == title
        }
        try #require(taken)
        await host.pump(times: 10)
        host.window.layoutIfNeeded()
        let view = controller.titleView
        guard view.window === host.window, view.frame.width > 0 else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    /// Answers the selection's server fetch with one running server, and
    /// records each worktree it was asked for.
    func recordServerFetches() -> ServerFetchLog {
        let log = ServerFetchLog()
        state.devServerListFetcher = { worktreeID, _ in
            log.worktreeIDs.append(worktreeID)
            let server = DevServerInfo(
                name: "web", label: "web", source: "tbd.toml", state: .running, exitCode: nil,
                endpoints: [DevServerEndpoint(name: "app", url: "http://localhost:3000")],
                terminalID: nil, pid: nil, hasStopCommand: false,
                stateFromStatusCommand: nil, hasStatusCommand: true, exitedTab: nil)
            return DevServerListResult(
                worktreeID: worktreeID, servers: [server], parseErrors: [], runningFileDiagnostics: [])
        }
        return log
    }

    // MARK: Tabs in the toolbar

    /// Shows the feature worktree in the detail area: one tab, with Session
    /// History open so no terminal view mounts, and the daemon taken as
    /// connected. The selection's one-shot daemon calls fail in this harness
    /// and can clear `isConnected`; `keepConnected()` sets it back.
    func showSingleWorktree() {
        let worktree = worktrees[1]
        let tabID = UUID()
        state.tabs[worktree.id] = [
            TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: "acme"),
        ]
        state.historyActiveWorktrees.insert(worktree.id)
        state.selectedWorktreeIDs = [worktree.id]
        state.isConnected = true
    }

    /// Takes the daemon as connected again if a failed call cleared it.
    func keepConnected() {
        if !state.isConnected {
            state.isConnected = true
        }
    }

    /// One look at the main pane's top row: the toolbar's items, the window's
    /// and the panes' geometry, and what a hit test through the window's
    /// frame view, as a click is routed, returns at points along the row's
    /// midline. The points lie inside the window's own bounds and the visible
    /// part of the content pane, past the sidebar while it shows, from
    /// `leadingOffset` past the pane's leading edge (and at least 16 pt past
    /// the visible part's) to 16 pt before the visible part's end, 16 pt
    /// apart. Every position comes from the views' own frames, never from
    /// the size the window was asked for: on CI the window comes out smaller
    /// than the root hosting view, which then reaches past it.
    func observeRow(in split: MainSplitViewController, from leadingOffset: CGFloat = 16) -> RowObservation {
        let window = host.window
        let pane = split.contentItem.viewController.view
        let paneFrame = pane.convert(pane.bounds, to: nil)
        let inset = pane.safeAreaInsets.top
        let sidebarFrame: NSRect? = split.sidebarItem.isCollapsed
            ? nil
            : split.splitView.arrangedSubviews.first.map { $0.convert($0.bounds, to: nil) }
        let worktreeView = Self.worktreePagerTabView(in: pane)
        let frameView = window.contentView?.superview
        let windowBounds = frameView?.bounds ?? .zero
        let chrome = state.windowChrome
        let geometry = [
            "window frame \(window.frame)",
            "content layout rect \(window.contentLayoutRect)",
            "frame view bounds \(windowBounds)",
            "split \(split.view.convert(split.view.bounds, to: nil))",
            "sidebar \(sidebarFrame.map { "\($0)" } ?? "collapsed")",
            "pane \(paneFrame)",
            "pane safe area top \(inset) leading \(pane.safeAreaInsets.left)",
            "published inset \(chrome.topSafeAreaInset) leading edge \(chrome.leadingItemTrailingEdge.map { "\($0)" } ?? "nil")",
            "connected \(state.isConnected)",
            "worktree view \(worktreeView.map { "\($0.convert($0.bounds, to: nil))" } ?? "none")",
            "drag gaps \(dragGapFrames(in: split))",
        ].joined(separator: ", ")

        var samples: [RowObservation.Sample] = []
        var midline: CGFloat?
        if let frameView, inset > 0 {
            let visibleMinX = max(paneFrame.minX, sidebarFrame?.maxX ?? paneFrame.minX, windowBounds.minX)
            let visibleMaxX = min(paneFrame.maxX, windowBounds.maxX)
            let top = min(paneFrame.maxY, windowBounds.maxY)
            let y = top - inset / 2
            midline = y
            var x = max(paneFrame.minX + leadingOffset, visibleMinX + 16)
            while x < visibleMaxX - 16 {
                let hit = frameView.hitTest(NSPoint(x: x, y: y))
                samples.append(RowObservation.Sample(
                    x: x,
                    kind: Self.kind(of: hit, pane: pane, worktreeView: worktreeView, content: window.contentView),
                    hitClass: hit.map { String(describing: type(of: $0)) } ?? "nil"))
                x += 16
            }
        }
        return RowObservation(
            toolbar: toolbarIdentifiers.map(\.rawValue), geometry: geometry, midline: midline, samples: samples)
    }

    /// Where a hit test's view lies: a row's drag gap, the worktree's own
    /// view, elsewhere in the content pane, elsewhere in the window's
    /// content, or outside the content view, in the titlebar's hierarchy:
    /// the title bar view itself, or a view in it, which is a toolbar item's.
    ///
    /// The title bar view is told apart by its class name, `NSTitlebarView`,
    /// which is private: a deliberate test seam, as `KeyViewProxy` is in
    /// `TabBarHitAreaTests`, so a hit the title bar takes itself is never
    /// read as one a toolbar item took.
    static func kind(
        of hit: NSView?, pane: NSView, worktreeView: NSView?, content: NSView?
    ) -> RowObservation.HitKind {
        guard let hit else { return .nothing }
        if hit is WindowDragGapView { return .dragGap }
        if let worktreeView, hit.isDescendant(of: worktreeView) { return .worktreeView }
        if hit.isDescendant(of: pane) { return .pane }
        if let content, hit.isDescendant(of: content) { return .otherContent }
        if String(describing: type(of: hit)) == "NSTitlebarView" { return .titlebar }
        return .toolbarItem
    }

    /// The drag gaps drawn in the content pane, in window coordinates.
    func dragGapFrames(in split: MainSplitViewController) -> [NSRect] {
        let pane = split.contentItem.viewController.view
        return OffscreenHost<AnyView>.descendants(WindowDragGapView.self, of: pane).map {
            $0.convert($0.bounds, to: nil)
        }
    }

    /// The worktree pager's tab view: an `NSTabView` nested inside the
    /// detail area's own.
    static func worktreePagerTabView(in pane: NSView) -> NSTabView? {
        let tabViews = OffscreenHost<AnyView>.descendants(NSTabView.self, of: pane)
        return tabViews.first { inner in
            tabViews.contains { outer in outer !== inner && inner.isDescendant(of: outer) }
        }
    }

    // MARK: Lookups

    /// Views carrying the AppKit split's identifier.
    var splitRoots: [NSView] {
        host.descendants(NSView.self).filter { $0.identifier == MainSplitViewController.viewIdentifier }
    }

    /// The AppKit split, found up the responder chain from its view.
    var mountedSplit: MainSplitViewController? {
        var responder: NSResponder? = splitRoots.first
        while let current = responder {
            if let split = current as? MainSplitViewController { return split }
            responder = current.nextResponder
        }
        return nil
    }

    /// The window toolbar's delegate, when that is the AppKit toolbar's.
    var toolbarController: MainToolbarController? {
        host.window.toolbar?.delegate as? MainToolbarController
    }

    var toolbarIdentifiers: [NSToolbarItem.Identifier] {
        (host.window.toolbar?.items ?? []).map(\.itemIdentifier)
    }

    /// A bare titlebar's height, for a window with no toolbar.
    static var titlebarOnlyHeight: CGFloat {
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height - content.height
    }

    /// How far the window's frame reaches above its content layout rect: the
    /// titlebar, and the toolbar once AppKit lays it out.
    var heightAboveContentLayout: CGFloat {
        host.window.frame.height - host.window.contentLayoutRect.maxY
    }

    /// Whether `DetailSectionHostPager`'s tab view, the outermost one in the
    /// split's content pane, is laid out with its top edge at or below the
    /// top of the window's content layout rect.
    func detailStartsBelowToolbar(in split: MainSplitViewController) -> Bool {
        let pane = split.contentItem.viewController.view
        guard let tabView = OffscreenHost<AnyView>.descendants(NSTabView.self, of: pane).first else { return false }
        let frame = tabView.convert(tabView.bounds, to: nil)
        return frame.height > 0 && frame.maxY <= host.window.contentLayoutRect.maxY + 0.5
    }

    /// Where the split and the content pane's detail area end, once the
    /// detail's tab view is laid out; nil before.
    func bottomEdges(in split: MainSplitViewController) -> PaneBottomEdges? {
        let pane = split.contentItem.viewController.view
        guard let tabView = OffscreenHost<AnyView>.descendants(NSTabView.self, of: pane).first,
              tabView.frame.height > 0 else { return nil }
        let rootBottom = Self.bottomInWindow(host.hostingView)
        let paneBottom = Self.bottomInWindow(pane)
        return PaneBottomEdges(
            splitAboveRoot: Self.bottomInWindow(split.view) - rootBottom,
            bandBelowDetail: Self.bottomInWindow(tabView) - paneBottom)
    }

    /// Where the native sidebar and the sidebar pane end, once the native
    /// sidebar is laid out; nil before.
    func sidebarBottomEdges(in split: MainSplitViewController) -> SidebarBottomEdges? {
        let pane = split.sidebarItem.viewController.view
        guard let root = Self.nativeSidebarRoots(in: pane).first, root.frame.height > 0 else { return nil }
        return SidebarBottomEdges(sidebarAbovePane: Self.bottomInWindow(root) - Self.bottomInWindow(pane))
    }

    /// `view`'s bottom edge in window coordinates, which put the origin at the
    /// bottom left.
    private static func bottomInWindow(_ view: NSView) -> CGFloat {
        view.convert(view.bounds, to: nil).minY
    }

    /// The native sidebar's root views under `pane`.
    static func nativeSidebarRoots(in pane: NSView) -> [NSView] {
        OffscreenHost<AnyView>.descendants(NSView.self, of: pane).filter {
            $0.identifier == NativeSidebarView.rootViewIdentifier
        }
    }

    /// The window toolbar's item for `MainToolbarItemID.sidebarSeparator`,
    /// when it is a tracking separator.
    var trackingSeparator: NSTrackingSeparatorToolbarItem? {
        for item in host.window.toolbar?.items ?? [] where item.itemIdentifier == MainToolbarItemID.sidebarSeparator {
            return item as? NSTrackingSeparatorToolbarItem
        }
        return nil
    }
}

/// What `ChromeMount.observeRow(in:from:)` saw.
private struct RowObservation: CustomStringConvertible {
    /// Where a hit test's view lies (`ChromeMount.kind(of:pane:worktreeView:content:)`).
    enum HitKind: String {
        case nothing, dragGap, worktreeView, pane, otherContent, titlebar, toolbarItem

        /// A view inside the content pane.
        var isInPane: Bool {
            switch self {
            case .dragGap, .worktreeView, .pane: return true
            case .nothing, .otherContent, .titlebar, .toolbarItem: return false
            }
        }
    }

    /// One point on the row's midline, in window coordinates, and what a hit
    /// test there returned.
    struct Sample {
        let x: CGFloat
        let kind: HitKind
        let hitClass: String
    }

    /// The toolbar's item identifiers, left to right.
    let toolbar: [String]
    /// The window's and panes' frames, the published chrome geometry and the
    /// connection, as text.
    let geometry: String
    /// The row's midline in window coordinates; nil before the pane has a
    /// toolbar over it or the window has a frame view.
    let midline: CGFloat?
    let samples: [Sample]

    /// Every point reached a view inside the content pane, and there was at
    /// least one point.
    var allInPane: Bool {
        !samples.isEmpty && samples.allSatisfy { $0.kind.isInPane }
    }

    /// Some point reached the worktree's own view, its row's drag gap
    /// included.
    var anyInWorktreeView: Bool {
        samples.contains { $0.kind == .worktreeView || $0.kind == .dragGap }
    }

    /// Some point reached a row's drag gap.
    var reachesDragGap: Bool {
        samples.contains { $0.kind == .dragGap }
    }

    /// Some point reached a view outside the window's content: the title
    /// bar view itself or a toolbar item's.
    var anyOutsideContent: Bool {
        samples.contains { $0.kind == .titlebar || $0.kind == .toolbarItem }
    }

    var description: String {
        let points = samples.map { sample in
            "x \(sample.x): \(sample.kind.rawValue) (\(sample.hitClass))"
        }.joined(separator: "; ")
        let line = midline.map { "\($0)" } ?? "none"
        return "toolbar \(toolbar); \(geometry); midline \(line); points [\(points)]"
    }
}

/// The last observation a wait on the row made, with the clauses it checked,
/// for the diagnostic of a wait that timed out.
@MainActor
private final class RowWaitLog {
    private(set) var last = "nothing observed"

    /// Records `observation` and each clause's value; returns whether every
    /// clause held.
    func note(_ observation: RowObservation, clauses: [(String, Bool)]) -> Bool {
        let failing = clauses.filter { !$0.1 }.map { $0.0 }
        let verdict = failing.isEmpty ? "every clause held" : "failing: \(failing.joined(separator: ", "))"
        last = "\(verdict); \(observation)"
        return failing.isEmpty
    }

    /// Records free text, for a check that is not a row observation.
    func note(_ text: String) {
        last = text
    }
}

/// A wait on the row that timed out, with what it last observed, as the
/// error its issue records so the text reaches the CI summary.
private struct RowWaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let observed: String

    var description: String {
        "\(what) never held. Last observed: \(observed)"
    }
}

/// The bottom of the window's split and of the content pane's detail area,
/// in points.
private struct PaneBottomEdges {
    /// The split's bottom above the bottom of the window's root.
    let splitAboveRoot: CGFloat
    /// The detail area's bottom above the content pane's: the band beneath
    /// the detail area.
    let bandBelowDetail: CGFloat

    /// The split on the root's bottom, with one bottom-bar height between
    /// the content pane's foot and its detail area.
    var placeTheStatusBarInTheContentPane: Bool {
        abs(splitAboveRoot) < 0.5 && abs(bandBelowDetail - WindowBottomBarMetrics.height) < 0.5
    }
}

/// The bottom of the native sidebar and of the sidebar pane, in points.
private struct SidebarBottomEdges {
    /// The native sidebar's bottom above the sidebar pane's.
    let sidebarAbovePane: CGFloat

    /// The native sidebar on the sidebar pane's bottom edge.
    var sidebarReachesThePanesFoot: Bool {
        abs(sidebarAbovePane) < 0.5
    }
}

/// The worktrees a fixture's server fetcher was asked for.
@MainActor
private final class ServerFetchLog {
    var worktreeIDs: [UUID] = []
}

/// What each hosted pane's `PaneStoreProbe` last read.
@MainActor
private final class PaneStoreReads {
    private(set) var values: [MainWindowSplitView.HostedPane: String] = [:]

    /// The panes whose probe has evaluated at least once.
    var panes: Set<MainWindowSplitView.HostedPane> {
        Set(values.keys)
    }

    func note(_ value: String, in pane: MainWindowSplitView.HostedPane) {
        values[pane] = value
    }

    /// `values` once every pane has read `value`.
    static func everyPane(reading value: String) -> [MainWindowSplitView.HostedPane: String] {
        Dictionary(uniqueKeysWithValues: MainWindowSplitView.HostedPane.allCases.map { ($0, value) })
    }
}

/// A key no real store holds, so `.standard` reads `PaneStoreProbe`'s
/// default. Kept free of dots, which key-value observation of a defaults key
/// reads as key path separators.
private let storeProbeKey = "mainWindowChromeMountTestsStoreProbe"

/// Reads one `@AppStorage` key and records what it read, for its pane, on
/// every evaluation. It draws nothing, so it changes nothing behind the
/// pane's root.
private struct PaneStoreProbe: View {
    let pane: MainWindowSplitView.HostedPane
    let reads: PaneStoreReads
    @AppStorage(storeProbeKey) private var value: String = "unset"

    var body: some View {
        let _ = reads.note(value, in: pane)
        Color.clear
    }
}

/// A root that declares one toolbar item and nothing else, standing in for a
/// SwiftUI tree that would claim its window's toolbar.
private struct ToolbarDeclaringRoot: View {
    var body: some View {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Probe") {}
                }
            }
    }
}
