import AppKit
import Testing
@testable import TBDApp

/// `MainSplitViewController`, the AppKit main window's split, and how the
/// sidebar lock treats it. Spec:
/// docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window structure".
///
/// Splits are built with `autosaveName: nil`: a saved divider position would
/// be written to `UserDefaults.standard`, the developer's real app defaults.
@MainActor
@Suite("Main split view controller")
struct MainSplitViewControllerTests {
    private static let windowSize = NSSize(width: 900, height: 600)

    // MARK: - Setup

    @Test func collapseFlagsAfterSetup() {
        let split = Self.makeSplit()
        split.loadViewIfNeeded()

        #expect(split.sidebarItem.canCollapse == true)
        #expect(split.sidebarItem.canCollapseFromWindowResize == false)
    }

    @Test func itemsAndViewIdentifier() {
        let split = Self.makeSplit()
        split.loadViewIfNeeded()

        let items = split.splitViewItems
        #expect(items.count == 2)
        #expect(items.first === split.sidebarItem)
        #expect(items.last === split.contentItem)
        #expect(split.sidebarItem.behavior == .sidebar)
        #expect(split.contentItem.behavior == .default)
        #expect(split.view.identifier == MainSplitViewController.viewIdentifier)
        #expect(split.isSidebarCollapsed == false)
    }

    @Test func separatorStylesAreNone() {
        let split = Self.makeSplit()
        // Spelled out: inside `#expect`, a bare `.none` can resolve to
        // `Optional.none`.
        let none = NSTitlebarSeparatorStyle.none

        #expect(split.sidebarItem.titlebarSeparatorStyle == none)
        #expect(split.contentItem.titlebarSeparatorStyle == none)
    }

    @Test func thicknessFromMetrics() {
        let split = Self.makeSplit()

        #expect(split.sidebarItem.minimumThickness == MainToolbarMetrics.sidebarMinimumThickness)
        #expect(split.sidebarItem.maximumThickness == MainToolbarMetrics.sidebarMaximumThickness)
    }

    // MARK: - In a window

    @Test func collapseFlagsSurviveALayoutPass() throws {
        let split = Self.makeSplit()
        let window = Self.mount(split)
        defer { Self.unmount(window) }

        let settled = Self.settle(split, in: window)
        try #require(settled)

        #expect(split.sidebarItem.canCollapse == true)
        #expect(split.sidebarItem.canCollapseFromWindowResize == false)
    }

    @Test func collapseIsReportedOnce() throws {
        let split = Self.makeSplit()
        let reports = Recorder<Bool>()
        split.onSidebarCollapsedChange = { reports.values.append($0) }
        let window = Self.mount(split)
        defer { Self.unmount(window) }

        let settled = Self.settle(split, in: window)
        try #require(settled)
        // A split that opens expanded has nothing to report.
        let nothing: [Bool] = []
        #expect(reports.values == nothing)

        split.sidebarItem.isCollapsed = true
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoopPump.until { !reports.values.isEmpty }
        // A resize while still collapsed must not report it again.
        window.setContentSize(NSSize(width: Self.windowSize.width + 40, height: Self.windowSize.height))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoopPump.turn()
        let collapsed: [Bool] = [true]
        #expect(reports.values == collapsed)
        #expect(split.isSidebarCollapsed == true)

        split.sidebarItem.isCollapsed = false
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoopPump.until { reports.values.count >= 2 }
        let collapsedThenExpanded: [Bool] = [true, false]
        #expect(reports.values == collapsedThenExpanded)
        #expect(split.isSidebarCollapsed == false)
    }

    @Test func viewDidAppearHandsOverTheWindow() {
        let split = Self.makeSplit()
        let windows = Recorder<NSWindow>()
        split.onViewDidAppear = { windows.values.append($0) }
        let window = Self.mount(split)
        defer { Self.unmount(window) }

        // Driven directly: AppKit may or may not have sent it on `orderFront`,
        // so every call is checked rather than how many there were.
        split.viewDidAppear()

        let target = ObjectIdentifier(window)
        let received = windows.values.map { ObjectIdentifier($0) }
        let allThisWindow = received.allSatisfy { $0 == target }
        #expect(received.isEmpty == false)
        #expect(allThisWindow)
    }

    // MARK: - The sidebar lock

    /// The flag-on branch. Mounted exactly as the plain split below is, whose
    /// test proves the lock's search reaches a split hosted this way, so this
    /// one cannot pass by the search missing the controller.
    @Test func lockSidebarOpenLeavesTheAppKitSplitAlone() {
        let split = Self.makeSplit()
        let window = Self.mount(split)
        defer { Self.unmount(window) }

        AppDelegate.lockSidebarOpen(in: window)

        #expect(split.sidebarItem.canCollapse == true)
        #expect(split.sidebarItem.canCollapseFromWindowResize == false)
    }

    /// The flag-off branch: a split that is not the AppKit chrome's, standing
    /// in for SwiftUI's, is still locked open.
    @Test func lockSidebarOpenStillLocksAPlainSidebarSplit() throws {
        let plain = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: Self.makePane(width: 320))
        // `canCollapse` first: on a sidebar it resets the other flag.
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = true
        plain.addSplitViewItem(sidebarItem)
        plain.addSplitViewItem(NSSplitViewItem(viewController: Self.makePane(width: 580)))
        let window = Self.mount(plain)
        defer { Self.unmount(window) }
        try #require(sidebarItem.canCollapse == true)
        try #require(sidebarItem.canCollapseFromWindowResize == true)

        AppDelegate.lockSidebarOpen(in: window)

        #expect(sidebarItem.canCollapse == false)
        #expect(sidebarItem.canCollapseFromWindowResize == false)
    }

    // MARK: - Fixtures

    private static func makeSplit() -> MainSplitViewController {
        MainSplitViewController(
            sidebar: makePane(width: 320),
            content: makePane(width: 580),
            autosaveName: nil)
    }

    /// A plain view controller over a sized, empty view.
    private static func makePane(width: CGFloat) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: windowSize.height))
        return controller
    }

    /// Puts `controller` in a titled window, the main window's kind, far off
    /// every display, ordered front but never made key, and lays it out.
    ///
    /// `isReleasedWhenClosed` is set to `false` once, here, and the window is
    /// never closed, so the flag is never flipped on the way out — see
    /// `OffscreenHostLifecycleTests`.
    private static func mount(_ controller: NSViewController) -> NSWindow {
        _ = NSApplication.shared
        // The window takes its first size from the view; start it at the
        // final one so no transient narrow layout happens on the way.
        controller.view.setFrameSize(windowSize)
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(windowSize)
        window.setFrameOrigin(OffscreenAppKitHost.offscreenOrigin)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private static func unmount(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
    }

    /// Turns the run loop until both panes sit in the window with a width.
    private static func settle(_ split: MainSplitViewController, in window: NSWindow) -> Bool {
        let sidebarView = split.sidebarItem.viewController.view
        let contentView = split.contentItem.viewController.view
        return RunLoopPump.until {
            sidebarView.window === window && contentView.window === window
                && sidebarView.frame.width > 0 && contentView.frame.width > 0
        }
    }
}

/// Collects what a callback was handed, in order.
@MainActor
private final class Recorder<Value> {
    var values: [Value] = []
}
