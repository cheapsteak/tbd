import AppKit
import os

private let splitLogger = Logger(subsystem: "com.tbd.app", category: "window-chrome")

/// The main window's split when it is built with the AppKit chrome
/// (`MainWindowChrome.appKit`): a sidebar item over the sidebar and a content
/// item over the detail area, in place of SwiftUI's `NavigationSplitView`.
///
/// Collapse belongs to the sidebar item. `canCollapse` is on and
/// `canCollapseFromWindowResize` off, the guard against #119, and both are set
/// once, here: nothing on this path resets them, so
/// `AppDelegate.lockSidebarOpen(in:)` leaves this controller alone.
///
/// The toolbar hangs off two hooks: `onViewDidAppear` hands over the window
/// once the split is in one, and `onSidebarCollapsedChange` reports each
/// collapse and each expansion once. Two sources feed that report through one
/// dedup: KVO on the item's `isCollapsed`, which fires the moment the value
/// flips, and `splitViewDidResizeSubviews`. The resize alone could not be
/// relied on: AppKit documents no order between an animated toggle's flip and
/// its last resize, so a flip that lands after it would wait for the next
/// unrelated one.
///
/// Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window
/// structure".
@MainActor
final class MainSplitViewController: NSSplitViewController {
    /// Set on `view`, so the split can be recognized in a window's hierarchy.
    static let viewIdentifier = NSUserInterfaceItemIdentifier("tbd.mainSplit.root")

    let sidebarItem: NSSplitViewItem
    let contentItem: NSSplitViewItem

    /// Called with the sidebar's new collapsed state, once per change.
    var onSidebarCollapsedChange: ((Bool) -> Void)?

    /// Called with the window each time the split appears in one.
    var onViewDidAppear: ((NSWindow) -> Void)?

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// The state last passed to `onSidebarCollapsedChange`. A new sidebar item
    /// starts expanded, so a split that opens expanded reports nothing, and
    /// one whose saved state is collapsed reports it once it is restored.
    private var lastReportedCollapsed = false

    /// KVO on `sidebarItem.isCollapsed`, which `NSSplitViewItem` documents
    /// as KVO compliant. Released, and so unregistered, with the controller.
    private var collapseObservation: NSKeyValueObservation?

    /// - Parameter autosaveName: the defaults key the divider position is
    ///   saved under. `nil` saves nothing, which keeps a test's split out of
    ///   the developer's real defaults.
    init(
        sidebar: NSViewController,
        content: NSViewController,
        autosaveName: NSSplitView.AutosaveName? = "TBDMainWindowSplit"
    ) {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        contentItem = NSSplitViewItem(viewController: content)
        super.init(nibName: nil, bundle: nil)

        // Before the items are added, so a saved position applies as they arrive.
        splitView.autosaveName = autosaveName

        // `canCollapse` first: on a sidebar, setting it resets
        // `canCollapseFromWindowResize` to the same value.
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.minimumThickness = MainToolbarMetrics.sidebarMinimumThickness
        sidebarItem.maximumThickness = MainToolbarMetrics.sidebarMaximumThickness
        sidebarItem.titlebarSeparatorStyle = .none
        contentItem.titlebarSeparatorStyle = .none

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        // The handler is `@Sendable`, but KVO calls it synchronously on the
        // thread that set the value, and AppKit sets it on the main thread.
        // It reads nothing from its arguments; the report reads the item.
        collapseObservation = sidebarItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reportCollapsedStateIfChanged() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.identifier = Self.viewIdentifier
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        onViewDidAppear?(window)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        reportCollapsedStateIfChanged()
    }

    /// Calls `onSidebarCollapsedChange` when the sidebar's collapsed state
    /// differs from the last one reported, from either source.
    private func reportCollapsedStateIfChanged() {
        let collapsed = sidebarItem.isCollapsed
        guard collapsed != lastReportedCollapsed else { return }
        lastReportedCollapsed = collapsed
        splitLogger.debug("Main split sidebar collapsed: \(collapsed, privacy: .public)")
        onSidebarCollapsedChange?(collapsed)
    }
}
