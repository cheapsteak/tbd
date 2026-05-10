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
/// Why each `NSHostingController` gets `sizingOptions = []`: by default an
/// `NSHostingController` installs `.minSize`, `.intrinsicContentSize`, and `.maxSize`
/// constraints sourced from the SwiftUI content. The intrinsic-size constraint
/// leaks back up through the split view controller's view and into the
/// `NSViewControllerRepresentable`'s SwiftUI host, which then sizes the entire
/// split to that small value (~46 pt) and centers it vertically with empty space
/// above and below. Clearing `sizingOptions` suppresses those constraints so the
/// split fills whatever frame SwiftUI hands the representable. Background:
/// https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/
///
/// `AppState` is passed explicitly and re-injected as an environment object on every
/// `NSHostingController` rootView. `EnvironmentObject` does not auto-cross the
/// SwiftUI -> AppKit -> SwiftUI boundary; skipping the re-injection would crash at
/// runtime with "No ObservableObject of type AppState found".
///
/// Identity-preserving update path: rootView is reassigned with the same static type
/// (`EnvironmentInjector<Sidebar>` / `EnvironmentInjector<Detail>`) on every update,
/// so SwiftUI matches views by type identity and runs its normal structural reconcile.
/// The earlier draft of this file used `AnyView` erasure inside `updateNSViewController`,
/// which forced SwiftUI into a heuristic reconcile and surfaced as a "performed a
/// reentrant operation in its NSTableView delegate" warning on the sidebar `List`.
struct AppKitSplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let appState: AppState
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitVC = NSSplitViewController()
        splitVC.splitView.autosaveName = "main.sidebar"

        let sidebarHost = NSHostingController(
            rootView: EnvironmentInjector(appState: appState, content: sidebar())
        )
        sidebarHost.sizingOptions = []
        context.coordinator.sidebarHost = sidebarHost
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
            rootView: EnvironmentInjector(appState: appState, content: detail())
        )
        detailHost.sizingOptions = []
        context.coordinator.detailHost = detailHost
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.canCollapse = false

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)

        return splitVC
    }

    func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
        // Reassign rootView with the same static wrapper type so SwiftUI can
        // match the view tree by identity and run a normal structural reconcile.
        // Required for state read by the closures (e.g. ContentView's @AppStorage
        // showFilePanel / filePanelWidth) to propagate into the hosted tree.
        context.coordinator.sidebarHost?.rootView =
            EnvironmentInjector(appState: appState, content: sidebar())
        context.coordinator.detailHost?.rootView =
            EnvironmentInjector(appState: appState, content: detail())
    }

    final class Coordinator {
        fileprivate var sidebarHost: NSHostingController<EnvironmentInjector<Sidebar>>?
        fileprivate var detailHost: NSHostingController<EnvironmentInjector<Detail>>?
    }
}

/// Spellable wrapper around `.environmentObject(...)` so the hosted rootView has
/// a concrete, generic-friendly type that the Coordinator can hold without
/// resorting to `AnyView` erasure.
private struct EnvironmentInjector<Content: View>: View {
    let appState: AppState
    let content: Content
    var body: some View {
        content.environmentObject(appState)
    }
}
