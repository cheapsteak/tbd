import AppKit
import SwiftUI

/// The main window's split and toolbar when it is built with the AppKit
/// chrome (`MainWindowChrome.appKit`). `ContentView` mounts it between the
/// banners and the status bar, where the SwiftUI chrome has its
/// `NavigationSplitView`.
///
/// - **The split.** A `MainSplitViewController` over two hosting controllers,
///   `SidebarView` and `MainDetailArea`.
/// - **The toolbar.** A `MainToolbarController` made for the split, which it
///   serves for its whole life, with the title cluster in a hosting view. It
///   is installed on the window the main-actor turn after the split's
///   `onViewDidAppear`: AppKit can deliver that from inside SwiftUI's
///   insertion of the representable, and the toolbar never changes inside a
///   SwiftUI update. The coordinator holds the controller, so it lives as
///   long as the split; the toolbar holds its delegate only weakly.
/// - **The divider.** It autosaves only when `AppState` uses
///   `UserDefaults.standard`, the store `NSSplitView` writes it to.
/// - **Hosting.** The hosting controllers and the title's hosting view have
///   `sceneBridgingOptions = []`, so none of them claims the window's toolbar
///   or title, which belong to the toolbar controller. A hosted tree starts
///   from a fresh environment, so each gets `AppState`, the appearance
///   settings and the transcript overlay coordinator again. Its `@AppStorage`
///   store is `appStorage` when one is given, and otherwise `.standard`. The
///   app passes `nil`: the window's root sets no `defaultAppStorage`, so it
///   reads `.standard`, and the hosted panes must read the same store.
///   `appState.userDefaults` is not that store under `TBD_MOCK`. The
///   controllers' `sizingOptions` are `[]`: the split items size the panes.
///
/// `updateNSViewController` refreshes only the Stop confirmation's closure.
/// The panes and the toolbar follow `AppState` themselves, so no AppKit
/// mutation runs inside SwiftUI's update pass.
///
/// Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window
/// structure".
struct MainWindowSplitView: NSViewControllerRepresentable {
    /// Raises the toolbar Stop's confirmation, which `ContentView` owns.
    let requestRemoteStop: (RemoteSessionSelection) -> Void
    /// The hosted trees' `@AppStorage` store: the one the window's root sets
    /// with `.defaultAppStorage`, or `nil` when it sets none and so reads
    /// `.standard`. Hosted trees do not inherit it, so it is passed here.
    let appStorage: UserDefaults?

    @Environment(AppState.self) var appState
    @EnvironmentObject var appearance: AppearanceSettings
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator

    /// Keeps the toolbar controller alive for as long as SwiftUI keeps the
    /// split.
    @MainActor
    final class Coordinator {
        var toolbarController: MainToolbarController?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> MainSplitViewController {
        let split = MainSplitViewController(
            sidebar: hostingController(SidebarView()),
            content: hostingController(MainDetailArea()),
            autosaveName: Self.splitAutosaveName(for: appState.userDefaults))
        let titleView = NSHostingView(rootView: withAppEnvironment(ToolbarTitleCluster(appState: appState)))
        titleView.sceneBridgingOptions = []
        let toolbarController = MainToolbarController(
            appState: appState, split: split, titleView: titleView, requestRemoteStop: requestRemoteStop)
        // Weak both ways: this closure holds the controller weakly, as the
        // controller holds the split. SwiftUI owns the split and the
        // coordinator the controller. Deferred one main-actor turn, so the
        // install never runs inside the SwiftUI update that inserted the split.
        split.onViewDidAppear = { [weak toolbarController] window in
            guard let toolbarController else { return }
            DispatchQueue.main.async { [weak toolbarController, weak window] in
                MainActor.assumeIsolated {
                    guard let toolbarController, let window else { return }
                    toolbarController.install(on: window)
                }
            }
        }
        context.coordinator.toolbarController = toolbarController
        return split
    }

    /// The divider's autosave name, only for `UserDefaults.standard`:
    /// `NSSplitView` always writes it there, and neither a test's suite nor
    /// `TBD_MOCK`'s may reach the real store.
    static func splitAutosaveName(for defaults: UserDefaults) -> NSSplitView.AutosaveName? {
        defaults === UserDefaults.standard ? "TBDMainWindowSplit" : nil
    }

    func updateNSViewController(_ split: MainSplitViewController, context: Context) {
        context.coordinator.toolbarController?.requestRemoteStop = requestRemoteStop
    }

    /// Takes the toolbar off the window, if the window still shows it, so
    /// nothing of the split outlives it. A toolbar something else put there
    /// stays. The controller stops watching the window first, so the removal
    /// is not put back as a replacement.
    static func dismantleNSViewController(_ split: MainSplitViewController, coordinator: Coordinator) {
        split.onViewDidAppear = nil
        coordinator.toolbarController?.uninstall(fallbackWindow: split.viewIfLoaded?.window)
        coordinator.toolbarController = nil
    }

    /// `root` with the environment every hosted tree needs. The `@AppStorage`
    /// store is set only when `appStorage` names one; otherwise the tree
    /// keeps `.standard`, as the window's root does.
    @ViewBuilder
    private func withAppEnvironment<Root: View>(_ root: Root) -> some View {
        let hosted = root
            .environment(appState)
            .environmentObject(appearance)
            .environmentObject(overlayCoordinator)
        if let appStorage {
            hosted.defaultAppStorage(appStorage)
        } else {
            hosted
        }
    }

    private func hostingController<Root: View>(_ root: Root) -> NSViewController {
        let controller = NSHostingController(rootView: withAppEnvironment(root))
        controller.sceneBridgingOptions = []
        controller.sizingOptions = []
        return controller
    }
}

/// The detail area in the AppKit split's content pane. The tab choice is
/// resolved here, in a real `body`, so Observation tracks the three inputs
/// and a selection change brings the right tab forward; see the matching
/// call site in `ContentView.body` for why `DetailSectionHostPager` cannot
/// read them itself.
struct MainDetailArea: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        DetailSectionHostPager(
            targetTab: DetailSectionHostPager.targetTab(
                isConnected: appState.isConnected,
                selectedRemoteSession: appState.selectedRemoteSession,
                selectedRemoteProvider: appState.selectedRemoteProvider
            )
        )
    }
}
