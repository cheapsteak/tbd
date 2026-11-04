import AppKit
import Observation

/// What the panes read from the main window's chrome to draw their tab strips
/// in the toolbar row: the row's height and where the toolbar's leading item
/// ends. `AppState.windowChrome` holds the one instance. Spec:
/// `docs/specs/2026-11-02-tabs-in-toolbar-design.md`.
///
/// `MainToolbarController` measures both values in AppKit, on the turn after
/// a layout, and writes them here only when they change
/// (`update(topSafeAreaInset:leadingItemTrailingEdge:)`). The panes read them
/// from `AppState` rather than from their environment: the detail area's
/// nested hosting controllers (`DetailSectionHostPager`, `WorktreePager`)
/// start from a fresh environment of their own.
@MainActor
@Observable
final class WindowChromeState {
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
    private(set) var leadingItemTrailingEdge: CGFloat? = nil

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
}
