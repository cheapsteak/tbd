import AppKit
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 2: the whole `ContentView` hosted in an offscreen window. Waits are
// bounded: pump counts for the mount, `pollUntilTrue` for main-queue work.

/// `ContentView` built with each `MainWindowChrome`. The AppKit chrome mounts
/// a `MainSplitViewController` and puts a `MainToolbarController`'s toolbar on
/// the window; the SwiftUI chrome mounts neither. Unlike the toolbar
/// controller's own suite, which builds the split into a window by hand, this
/// is the production hosting path: the split inside SwiftUI's hosting view,
/// reached through `MainWindowSplitView`. Spec:
/// docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window structure",
/// "Switching" and "Testing".
///
/// The toolbar is applied through `DispatchQueue.main.async`, so waits on it
/// suspend (`waitForMainActorCondition`, over `pollUntilTrue`) rather than pump
/// (Tests/CLAUDE.md, "`@MainActor` tests: suspend to drain, never pump").
@MainActor
@Suite("Main window chrome mount")
struct MainWindowChromeMountTests {
    // MARK: - Each chrome's structure

    @Test func appKitChromeMountsTheSplitAndToolbar() async throws {
        let mount = ChromeMount(chrome: .appKit, label: "appKitMounts")
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
        #expect(identifiers.contains(MainToolbarItemID.toggleSidebar))
        #expect(stray.isEmpty)

        // The state's store is a test suite, not `.standard`, so the divider
        // autosaves nowhere.
        let split = try #require(mount.mountedSplit)
        #expect(split.splitView.autosaveName == nil)

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

    @Test func swiftUIChromeMountsNoAppKitSplit() async throws {
        let mount = ChromeMount(chrome: .swiftUI, label: "swiftUIMounts")
        defer { mount.tearDown() }

        // Positive control: `NavigationSplitView` lowers to an `NSSplitView`.
        let splitMounted = await mount.host.settle { !mount.host.descendants(NSSplitView.self).isEmpty }
        try #require(splitMounted, "The NavigationSplitView never mounted; the negatives below would be vacuous")

        #expect(mount.splitRoots.isEmpty)
        #expect(mount.toolbarController == nil)
    }

    // MARK: - Hosted panes' storage

    /// The hosted panes read `@AppStorage` from the store `ContentView` was
    /// given for them, which here mirrors the root's `.defaultAppStorage`,
    /// not from `.standard`: a hosted tree starts from a fresh environment.
    /// Observed through the sidebar, whose `@AppStorage(appKitSidebarKey)`
    /// picks the native outline or the `List`. The suite is flipped both
    /// ways, so the test discriminates whatever `.standard` holds for that
    /// key on the machine running it.
    @Test func hostedPanesReadTheRootsStore() async throws {
        let mount = ChromeMount(chrome: .appKit, label: "hostedStore")
        defer { mount.tearDown() }
        _ = try await mount.appKitReady()
        let split = try #require(mount.mountedSplit)
        let sidebarPane = split.sidebarItem.viewController.view

        mount.suite.defaults.set(true, forKey: AppState.appKitSidebarKey)
        let native = try await waitForMainActorCondition(
            "the hosted sidebar to mount the native outline from the suite"
        ) {
            !ChromeMount.nativeSidebarRoots(in: sidebarPane).isEmpty
        }
        #expect(native)

        mount.suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        let list = try await waitForMainActorCondition("the hosted sidebar to mount the List from the suite") {
            ChromeMount.nativeSidebarRoots(in: sidebarPane).isEmpty
                && !OffscreenHost<AnyView>.descendants(NSTableView.self, of: sidebarPane).isEmpty
        }
        #expect(list)
    }

    /// The app builds `ContentView` without the seam, so its hosted panes get
    /// no store of their own and keep `.standard`, the store the window's
    /// root and the menu commands read. The seam carries a test's store.
    @Test func hostedStoreIsNilWithoutTheSeam() {
        let suite = TestDefaultsSuite("MainWindowChromeMountTests.seam")
        defer { suite.tearDown() }
        let app = ContentView(chrome: .appKit)
        let seamed = ContentView(chrome: .appKit, hostedAppStorage: suite.defaults)
        #expect(app.hostedAppStorage == nil)
        #expect(seamed.hostedAppStorage === suite.defaults)
    }

    // MARK: - The toolbar in the hosted window

    /// Positive control for `toolbarSurvivesAnAppStateChange`: in this
    /// harness, a root hosting view given `.all` does bridge the scene, so
    /// SwiftUI puts a toolbar on the window for a tree that declares one.
    /// The root hosting view is a subview of the host's ground, not the
    /// window's content view; without this, the survival test could pass
    /// only because SwiftUI never reached the window's toolbar.
    @Test func swiftUIChromeBridgesItsToolbarOntoTheWindow() async throws {
        let mount = ChromeMount(chrome: .swiftUI, label: "bridges", sceneBridgingOptions: .all)
        defer { mount.tearDown() }

        let bridged = try await waitForMainActorCondition("SwiftUI to put the scene's toolbar on the window") {
            mount.host.window.toolbar != nil
        }
        try #require(bridged)
        let swiftUIOwned = !(mount.host.window.toolbar?.delegate is MainToolbarController)
        #expect(swiftUIOwned)
    }

    /// Review focus 1: a SwiftUI update of the window's hierarchy must leave
    /// the AppKit toolbar on the window, or the next apply must put it back.
    /// The root hosting view bridges the scene, as the app window's root does,
    /// so SwiftUI is free to claim the window's toolbar; that the bridging is
    /// live in this harness is `swiftUIChromeBridgesItsToolbarOntoTheWindow`'s
    /// job, and this test proves nothing without it passing.
    @Test func toolbarSurvivesAnAppStateChange() async throws {
        let mount = ChromeMount(chrome: .appKit, label: "survives", sceneBridgingOptions: .all)
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
    @Test func appKitChromeBindsTheTrackingSeparatorToTheHostedSplit() async throws {
        let mount = ChromeMount(chrome: .appKit, label: "trackingSeparator")
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

    // MARK: - The selection's server refresh, on both chromes

    /// The `.task(id:)` that fetches a selected worktree's servers hangs on
    /// the container of both chromes. On the AppKit one, the Servers item
    /// appearing is what that fetch is for.
    @Test func appKitChromeRefreshesTheSelectedWorktreesServers() async throws {
        let mount = ChromeMount(chrome: .appKit, label: "serversAppKit")
        defer { mount.tearDown() }
        let fetches = mount.recordServerFetches()
        _ = try await mount.appKitReady()
        try #require(!mount.toolbarIdentifiers.contains(MainToolbarItemID.servers))

        let worktreeID = mount.worktrees[1].id
        mount.state.selectedWorktreeIDs = [worktreeID]

        let fetched = try await waitForMainActorCondition("the selection's server fetch") {
            fetches.worktreeIDs.contains(worktreeID)
        }
        #expect(fetched)
        let shown = try await waitForMainActorCondition("the Servers item") {
            mount.toolbarIdentifiers.contains(MainToolbarItemID.servers)
        }
        #expect(shown)
    }

    @Test func swiftUIChromeRefreshesTheSelectedWorktreesServers() async throws {
        let mount = ChromeMount(chrome: .swiftUI, label: "serversSwiftUI")
        defer { mount.tearDown() }
        let fetches = mount.recordServerFetches()
        let splitMounted = await mount.host.settle { !mount.host.descendants(NSSplitView.self).isEmpty }
        try #require(splitMounted, "The NavigationSplitView never mounted")

        let worktreeID = mount.worktrees[1].id
        mount.state.selectedWorktreeIDs = [worktreeID]

        let fetched = try await waitForMainActorCondition("the selection's server fetch") {
            fetches.worktreeIDs.contains(worktreeID)
        }
        #expect(fetched)
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

/// `ContentView` with one chrome, its `AppState` holding a repo and two
/// worktrees, hosted offscreen in a titled window at the app's default size.
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

    /// - Parameter sceneBridgingOptions: for the root hosting view; `nil`
    ///   keeps `NSHostingView`'s default.
    init(chrome: MainWindowChrome, label: String, sceneBridgingOptions: NSHostingSceneBridgingOptions? = nil) {
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
        let root = ContentView(chrome: chrome, hostedAppStorage: suite.defaults)
            .environment(state)
            .environmentObject(appearance)
            .environmentObject(TranscriptOverlayCoordinator())
            .defaultAppStorage(suite.defaults)
        host = OffscreenHost(
            root: AnyView(root), size: ChromeMount.size, styleMask: ChromeMount.styleMask,
            sceneBridgingOptions: sceneBridgingOptions)
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

    /// Waits for the AppKit split to mount and for its appearance to install
    /// the toolbar and apply it once, and returns the toolbar's controller.
    func appKitReady() async throws -> MainToolbarController {
        let splitMounted = await host.settle { !self.splitRoots.isEmpty }
        try #require(splitMounted, "The AppKit split never mounted with the AppKit chrome")
        let installed = try await waitForMainActorCondition("the AppKit toolbar to be installed and applied") {
            self.toolbarController?.appliedSnapshot != nil
        }
        try #require(installed)
        let controller = try #require(toolbarController)
        readyController = controller
        return controller
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

/// The worktrees a fixture's server fetcher was asked for.
@MainActor
private final class ServerFetchLog {
    var worktreeIDs: [UUID] = []
}
