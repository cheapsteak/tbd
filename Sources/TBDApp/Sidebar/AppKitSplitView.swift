import AppKit
import SwiftUI

/// AppKit-backed two-pane split view that replaces SwiftUI's `NavigationSplitView`.
///
/// Why this exists: SwiftUI's `NavigationSplitView` (with `.prominentDetail` style and
/// `.toolbar(removing: .sidebarToggle)`) auto-collapses the sidebar when the window
/// gets narrow and gives the user no way to bring it back. After wake-from-sleep,
/// macOS reports a transient ~200x200 window size; SwiftUI reacts by auto-collapsing
/// the sidebar and never restoring it. Wrapping `NSSplitViewController` directly with
/// `canCollapse = false` on the sidebar item makes the layout deterministic.
///
/// `AppState` is passed explicitly and re-injected as an environment object on every
/// `NSHostingController` rootView (both at make and update time). `EnvironmentObject`
/// does not auto-cross the SwiftUI -> AppKit -> SwiftUI boundary; skipping the
/// re-injection would crash at runtime with "No ObservableObject of type AppState
/// found" the first time the hosted SwiftUI views read state.
///
/// Generics note: we erase sidebar/detail to `AnyView` inside `updateNSViewController`
/// when reassigning `rootView`. The alternative (preserving the concrete `Sidebar` /
/// `Detail` generic types in the `NSHostingController<...>` cast) compiles, but the
/// resulting `as? NSHostingController<ModifiedContent<Sidebar, ...>>` casts are very
/// fragile to any future change to the `.environmentObject(...)` chain. AnyView
/// erasure trades a negligible amount of view diffing efficiency for code that is
/// readable and won't silently break when the wrapping modifiers change.
struct AppKitSplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let appState: AppState
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitVC = NSSplitViewController()
        splitVC.splitView.autosaveName = "main.sidebar"

        let sidebarHost = NSHostingController(
            rootView: AnyView(sidebar().environmentObject(appState))
        )
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 400
        // Holding priority above the default makes the sidebar resist resize
        // pressure less than the detail pane — i.e. on window resize the
        // detail keeps its width preference and the sidebar absorbs the delta
        // (within its min/max). +1 over .defaultLow puts us just above the
        // detail item's implicit holding priority.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(
            rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue + 1
        )

        let detailHost = NSHostingController(
            rootView: AnyView(detail().environmentObject(appState))
        )
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.canCollapse = false

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)

        return splitVC
    }

    func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
        // Re-render hosted SwiftUI views so that observable state changes
        // (e.g. AppState mutations) propagate. We re-attach the environment
        // object on every update because the AnyView wrapping would otherwise
        // hide the previously-injected EnvironmentObject from the new rootView.
        let items = splitVC.splitViewItems
        guard items.count == 2 else { return }

        if let sidebarHost = items[0].viewController as? NSHostingController<AnyView> {
            sidebarHost.rootView = AnyView(sidebar().environmentObject(appState))
        }
        if let detailHost = items[1].viewController as? NSHostingController<AnyView> {
            detailHost.rootView = AnyView(detail().environmentObject(appState))
        }
    }
}
