import AppKit
import Observation

/// What the panes read from the main window's chrome to draw their tab strips
/// in the toolbar row: the Tabs in the toolbar setting, the row's height and
/// where the toolbar's leading item ends. `AppState.windowChrome` holds the
/// one instance. Spec: `docs/specs/2026-11-02-tabs-in-toolbar-design.md`.
///
/// - **The setting.** `tabsInToolbar` follows `AppState.tabsInToolbarKey` in
///   the store it was made with, `AppState.userDefaults`, through that
///   store's change notification, so a write from anywhere in the process
///   reaches every reader. The panes read it here rather than through
///   `@AppStorage`: the detail area's nested hosting controllers
///   (`DetailSectionHostPager`, `WorktreePager`) do not carry the split's
///   `@AppStorage` store, and the key's dot reads as a key path separator to
///   the key-value observation `@AppStorage` relies on. The Settings toggle
///   writes through `setTabsInToolbar(_:)`.
/// - **The geometry.** `MainToolbarController` measures both values in
///   AppKit, on the turn after a layout, and writes them here only when they
///   change (`update(topSafeAreaInset:leadingItemTrailingEdge:)`).
@MainActor
@Observable
final class WindowChromeState: NSObject {
    /// The Tabs in the toolbar setting as the store holds it
    /// (`AppState.tabsInToolbarEnabled(defaults:)`).
    private(set) var tabsInToolbar: Bool

    /// The content pane's top safe-area inset, which is the toolbar's height
    /// over it: the height the panes' top rows take
    /// (`MainTabRowMetrics.height(topSafeAreaInset:)`). Zero until the toolbar
    /// controller has measured it.
    private(set) var topSafeAreaInset: CGFloat = 0

    /// The toolbar's leading item's trailing edge, in points from the content
    /// pane's leading edge: positive while the item sits over the pane, as it
    /// does with the sidebar collapsed, and negative while the sidebar holds
    /// it. Nil until the toolbar controller has measured it, or while the
    /// toolbar shows no leading item.
    private(set) var leadingItemTrailingEdge: CGFloat?

    /// The store the setting is read from and written to.
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        tabsInToolbar = AppState.tabsInToolbarEnabled(defaults: defaults)
        super.init()
        // Selector-based, so the center drops the registration when this
        // object goes and no deinit has to reach a token.
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification, object: defaults)
    }

    /// Writes the setting to the store and follows it at once; the store's
    /// change notification would follow it too.
    func setTabsInToolbar(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppState.tabsInToolbarKey)
        followDefaults()
    }

    /// Re-reads the setting, writing `tabsInToolbar` only when it changed, so
    /// a write to any other key of the store invalidates nothing. Internal so
    /// a test can drive it without waiting for the notification.
    func followDefaults() {
        let stored = AppState.tabsInToolbarEnabled(defaults: defaults)
        if stored != tabsInToolbar {
            tabsInToolbar = stored
        }
    }

    /// Takes what the toolbar controller measured, writing each value only
    /// when it changed, so an unchanged measurement invalidates no pane.
    func update(topSafeAreaInset: CGFloat, leadingItemTrailingEdge: CGFloat?) {
        if topSafeAreaInset != self.topSafeAreaInset {
            self.topSafeAreaInset = topSafeAreaInset
        }
        if leadingItemTrailingEdge != self.leadingItemTrailingEdge {
            self.leadingItemTrailingEdge = leadingItemTrailingEdge
        }
    }

    /// The store's change notification, posted on whichever thread wrote it.
    @objc nonisolated private func defaultsDidChange(_ notification: Notification) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.followDefaults() }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.followDefaults() }
            }
        }
    }
}
