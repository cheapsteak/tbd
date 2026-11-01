import AppKit
import SwiftUI

/// The main window's split and toolbar when it is built with the AppKit
/// chrome (`MainWindowChrome.appKit`). `ContentView` mounts it between the
/// banners and the status bar, where the SwiftUI chrome has its
/// `NavigationSplitView`.
///
/// - **The split.** A `MainSplitViewController` over two hosting controllers,
///   `SidebarView` and `MainDetailArea`.
/// - **The toolbar.** A `MainToolbarController` with the title cluster in a
///   hosting view, installed on the window by the split's `onViewDidAppear`.
///   The coordinator holds it, so it lives as long as the split; the toolbar
///   holds its delegate only weakly.
/// - **Hosting.** The hosting controllers and the title's hosting view have
///   `sceneBridgingOptions = []`, so none of them claims the window's toolbar
///   or title, which belong to the toolbar controller. A hosted tree starts
///   from a fresh environment, so each gets `AppState`, the appearance
///   settings and the transcript overlay coordinator again. The controllers'
///   `sizingOptions` are `[]`: the split items size the panes.
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
        let titleView = NSHostingView(rootView: withAppEnvironment(ToolbarTitleCluster(appState: appState)))
        titleView.sceneBridgingOptions = []
        let toolbarController = MainToolbarController(
            appState: appState, titleView: titleView, requestRemoteStop: requestRemoteStop)
        let split = MainSplitViewController(
            sidebar: hostingController(SidebarView()),
            content: hostingController(MainDetailArea()))
        // Weak both ways: the split holds this closure, and the coordinator
        // holds the toolbar controller.
        split.onViewDidAppear = { [weak toolbarController, weak split] window in
            guard let toolbarController, let split else { return }
            toolbarController.install(on: window, split: split)
        }
        context.coordinator.toolbarController = toolbarController
        return split
    }

    func updateNSViewController(_ split: MainSplitViewController, context: Context) {
        context.coordinator.toolbarController?.requestRemoteStop = requestRemoteStop
    }

    /// Takes the toolbar off the window, if the window still shows it, so
    /// nothing of the split outlives it. A toolbar something else put there
    /// stays.
    static func dismantleNSViewController(_ split: MainSplitViewController, coordinator: Coordinator) {
        split.onViewDidAppear = nil
        if let toolbarController = coordinator.toolbarController,
           let window = toolbarController.window ?? split.view.window,
           window.toolbar === toolbarController.toolbar {
            window.toolbar = nil
        }
        coordinator.toolbarController = nil
    }

    /// `root` with the environment every hosted tree needs.
    private func withAppEnvironment<Root: View>(_ root: Root) -> some View {
        root
            .environment(appState)
            .environmentObject(appearance)
            .environmentObject(overlayCoordinator)
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
