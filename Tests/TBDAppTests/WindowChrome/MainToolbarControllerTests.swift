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
/// Every fixture's toolbar has an identifier of its own: toolbars that share
/// one mirror each other's item changes, and tests interleave at each wait.
///
/// `apply` defers through `DispatchQueue.main.async` and toolbar layout runs
/// on the run loop, so tests wait by suspending (`waitUntil`), never by
/// pumping (Tests/CLAUDE.md, "`@MainActor` tests: suspend to drain, never
/// pump"). Assertions after a direct `apply` run before any suspension, so a
/// scheduled apply cannot land between the two.
@MainActor
@Suite("Main toolbar controller")
struct MainToolbarControllerTests {
    // MARK: - Install

    /// The one test of real `viewDidAppear` delivery: nothing here installs
    /// the toolbar except the split's own appearance in the window.
    @Test func installsOnAppear() async throws {
        let fixture = ToolbarFixture(label: "installsOnAppear")
        defer { fixture.tearDown() }

        let installed = try await waitUntil("the split's viewDidAppear to install the toolbar") {
            fixture.window.toolbar === fixture.controller.toolbar
        }
        try #require(installed)
        let applied = try await waitUntil("the first apply") { fixture.controller.appliedSnapshot != nil }
        try #require(applied)

        #expect(fixture.identifiers == fixture.expectedIdentifiers())
        #expect(fixture.window.toolbar?.delegate === fixture.controller)
        #expect(fixture.window.toolbarStyle == .unified)
        #expect(fixture.window.titleVisibility == .hidden)
        #expect(fixture.controller.toolbar.displayMode == .iconOnly)
        #expect(fixture.controller.toolbar.allowsUserCustomization == false)
        #expect(fixture.controller.toolbar.autosavesConfiguration == false)
        #expect(fixture.controller.item(MainToolbarItemID.title)?.view === fixture.titleView)
        #expect(MainToolbarController.toolbarIdentifier == "tbd.mainToolbar")
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
        let filterLeft = try await waitUntil("the filter to leave on collapse") {
            !fixture.identifiers.contains(MainToolbarItemID.repoFilter)
        }
        try #require(filterLeft)
        let collapsedLeading = Array(fixture.identifiers.prefix(3))
        #expect(collapsedLeading == leading)
        #expect(fixture.identifiers == fixture.expectedIdentifiers())
        let leadingVisible = try await waitUntil("the toggle and arrows to be visible") {
            fixture.window.layoutIfNeeded()
            let visible = Set((fixture.controller.toolbar.visibleItems ?? []).map(\.itemIdentifier))
            return leading.allSatisfy { visible.contains($0) }
        }
        #expect(leadingVisible)

        fixture.split.sidebarItem.isCollapsed = false
        let filterBack = try await waitUntil("the filter to return on expansion") {
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

        let laidOut = try await waitUntil("the filter to be laid out in the toolbar") {
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
        let followed = try await waitUntil("the Servers icon to follow the appearance") {
            servers.image !== light
        }
        #expect(followed)

        fixture.controller.apply(MainToolbarSnapshot.make(from: fixture.state))
        let rebaked = try #require(servers.image)
        #expect(rebaked !== light)
        #expect(rebaked.accessibilityDescription == "Dev servers, 1 running")
    }

    // MARK: - Re-install

    @Test func reinstallsAReplacedToolbar() async throws {
        let fixture = ToolbarFixture(label: "reinstallsAReplacedToolbar")
        defer { fixture.tearDown() }
        try await fixture.ready()

        fixture.window.toolbar = NSToolbar()
        try #require(fixture.window.toolbar !== fixture.controller.toolbar)
        fixture.controller.scheduleApply()

        let back = try await waitUntil("our toolbar to come back") {
            fixture.window.toolbar === fixture.controller.toolbar
        }
        #expect(back)
        #expect(fixture.identifiers == fixture.expectedIdentifiers())
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

// MARK: - Waiting

/// Checks `condition` until it holds, suspending between checks so main-queue
/// work and run-loop layout get to run. What it waits for is main-queue or
/// run-loop work, which a suspension of this main-actor body lets run first,
/// so the cap counts hops rather than time.
///
/// The verdict is a fresh read after the last sleep, never the loop's exit,
/// and a cancelled sleep throws rather than spinning (Tests/CLAUDE.md,
/// "Assertion hygiene" 5). A miss is recorded as an error, so its text
/// reaches the CI summary.
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws -> Bool {
    let start = ContinuousClock.now
    for _ in 0..<300 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    if condition() { return true }
    Issue.record(WaitTimedOut(what: what, elapsed: ContinuousClock.now - start))
    return false
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let elapsed: Duration

    var description: String {
        "Timed out waiting for \(what) after \(elapsed) and 300 checks"
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

    init(label: String) {
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
            appState: state, titleView: titleView, requestRemoteStop: { _ in },
            identifier: "tbd.mainToolbar.test.\(UUID().uuidString)")
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
        window.contentViewController = split
        window.setContentSize(size)
        window.setFrameOrigin(ToolbarFixture.offscreenOrigin)
        window.orderFront(nil)
    }

    /// Installs the toolbar directly as well, so only `installsOnAppear`
    /// depends on `viewDidAppear` arriving, then waits for the first apply.
    func ready() async throws {
        controller.install(on: window, split: split)
        let applied = try await waitUntil("the first apply") {
            controller.appliedSnapshot != nil && window.toolbar === controller.toolbar
        }
        try #require(applied)
    }

    func tearDown() {
        split.onViewDidAppear = nil
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

    /// Selects a running remote session whose provider reads transcripts, so
    /// the snapshot shows Transcript and Stop.
    @discardableResult
    func showRemoteSession() -> RemoteSessionSelection {
        let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
        state.remoteProviders = [RemoteProviderStatus(
            config: RemoteProviderConfig(name: "acme", exec: "/bin/acme"),
            describe: ProviderDescribe(name: "acme", capabilities: [RemoteCapability.transcriptRead]),
            health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)]
        state.remoteSessions = [RemoteSessionInfo(
            provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
            gone: false, dismissed: false, lastSeen: Date())]
        state.selectedRemoteSession = selection
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
