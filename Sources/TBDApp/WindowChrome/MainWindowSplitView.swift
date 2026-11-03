import AppKit
import SwiftUI

/// The main window's split and toolbar. `ContentView` mounts it below the
/// banners, and it reaches the window's bottom edge.
///
/// - **The split.** A `MainSplitViewController` over two hosting controllers,
///   `SidebarView` and `MainDetailArea`. The status bar is the content pane's,
///   at the foot of `MainDetailArea`.
/// - **The toolbar.** A `MainToolbarController` made for the split, which it
///   serves for its whole life, with the title cluster in a hosting view
///   (`makeTitleView(_:)`). It is installed on the window the main-actor
///   turn after the split's `onViewDidAppear`: AppKit can deliver that from
///   inside SwiftUI's insertion of the representable, and the toolbar never
///   changes inside a SwiftUI update. The coordinator holds the controller,
///   so it lives as long as the split; the toolbar holds its delegate only
///   weakly.
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
/// - **The probe.** `\.hostedPaneProbe`, which the app never sets, draws a
///   test's view behind each hosted root inside the environment the split
///   gives it, so a test reads what the real pane reads.
///
/// `updateNSViewController` refreshes only the Stop confirmation's closure.
/// The panes and the toolbar follow `AppState` themselves, so no AppKit
/// mutation runs inside SwiftUI's update pass.
///
/// Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window
/// structure".
struct MainWindowSplitView: NSViewControllerRepresentable {
    /// The SwiftUI trees the split hosts, each in a hosting controller or
    /// view of its own.
    enum HostedPane: CaseIterable, Sendable {
        case sidebar
        case detail
        case title
    }

    /// Raises the toolbar Stop's confirmation, which `ContentView` owns.
    let requestRemoteStop: (RemoteSessionSelection) -> Void
    /// The hosted trees' `@AppStorage` store: the one the window's root sets
    /// with `.defaultAppStorage`, or `nil` when it sets none and so reads
    /// `.standard`. Hosted trees do not inherit it, so it is passed here.
    let appStorage: UserDefaults?

    @Environment(AppState.self) var appState
    @EnvironmentObject var appearance: AppearanceSettings
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @Environment(\.hostedPaneProbe) var hostedPaneProbe

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
            sidebar: hostingController(SidebarView(), pane: .sidebar),
            content: hostingController(MainDetailArea(), pane: .detail),
            autosaveName: Self.splitAutosaveName(for: appState.userDefaults))
        let titleView = Self.makeTitleView(
            withAppEnvironment(ToolbarTitleCluster(appState: appState), pane: .title))
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

    /// The title item's view: `root` in a hosting view whose width never
    /// follows the text, so the cluster stays put when the title changes.
    ///
    /// - **Width.** The root's ideal width is a constant, and the hosting view
    ///   reports only an intrinsic size, so it installs no minimum or maximum
    ///   that tracks the content. `MainToolbarController` gives the view the
    ///   width constraints that make the item flexible.
    /// - **Placement.** The content hugs the leading edge of whatever width
    ///   the toolbar gives the item, so it starts just past the tracking
    ///   separator and does not move as the width changes.
    /// - **Overflow.** A title wider than the item is cut at the item's
    ///   trailing edge. Nothing past the leading, top or bottom edge is cut,
    ///   so the notes button's hover label, which reaches below the cluster
    ///   and left of its leading edge, still shows.
    /// - **Hosting.** `sceneBridgingOptions = []`, so the view never claims
    ///   the window's toolbar or title.
    static func makeTitleView<Root: View>(_ root: Root) -> NSView {
        let content = root
            .frame(minWidth: 0, idealWidth: MainToolbarMetrics.titleIdealWidth, maxWidth: .infinity,
                   alignment: .leading)
            .clipShape(TrailingEdgeClip())
        let view = NSHostingView(rootView: content)
        view.sceneBridgingOptions = []
        view.sizingOptions = [.intrinsicContentSize]
        return view
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
    /// keeps `.standard`, as the window's root does. A test's probe for
    /// `pane`, when one is set, sits behind `root` inside that environment.
    @ViewBuilder
    private func withAppEnvironment<Root: View>(_ root: Root, pane: HostedPane) -> some View {
        let probe = hostedPaneProbe?(pane)
        let hosted = root
            .background { probe }
            .environment(appState)
            .environmentObject(appearance)
            .environmentObject(overlayCoordinator)
        if let appStorage {
            hosted.defaultAppStorage(appStorage)
        } else {
            hosted
        }
    }

    private func hostingController<Root: View>(_ root: Root, pane: HostedPane) -> NSViewController {
        let controller = NSHostingController(rootView: withAppEnvironment(root, pane: pane))
        controller.sceneBridgingOptions = []
        controller.sizingOptions = []
        return controller
    }
}

/// A test seam: given a pane, the view `MainWindowSplitView` draws behind that
/// pane's hosted root, inside the environment the split gives the root. A
/// hosted tree does not inherit its host's environment, so this is how a test
/// observes what each real pane reads, such as its `@AppStorage` store. The
/// split reads it once, when it builds the panes. Nothing in the app sets it.
private struct HostedPaneProbeKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MainWindowSplitView.HostedPane) -> AnyView)? = nil
}

extension EnvironmentValues {
    var hostedPaneProbe: (@MainActor (MainWindowSplitView.HostedPane) -> AnyView)? {
        get { self[HostedPaneProbeKey.self] }
        set { self[HostedPaneProbeKey.self] = newValue }
    }
}

/// A clip at the trailing edge only: the shape stops exactly there and
/// reaches far past the leading, top and bottom edges, so nothing drawn
/// beyond those is cut. Its path is drawn for left-to-right layout and
/// mirrors under right-to-left, so it cuts the trailing edge in both.
private struct TrailingEdgeClip: Shape {
    var layoutDirectionBehavior: LayoutDirectionBehavior { .mirrors }

    func path(in rect: CGRect) -> Path {
        let reach: CGFloat = 1_000
        return Path(CGRect(
            x: rect.minX - reach, y: rect.minY - reach,
            width: rect.width + reach, height: rect.height + 2 * reach))
    }
}

/// The split's content pane: the detail area over the status bar.
///
/// - **The detail area.** The tab choice is resolved here, in a real `body`,
///   and handed to `DetailSectionHostPager` as a value. Reading the three
///   inputs inside `updateNSViewController` instead would register no
///   dependency — Observation tracks what a `body` evaluation reads — so a
///   selection change that touched nothing else this body reads would leave
///   the detail area on the previous tab.
/// - **The status bar.** `StatusBarView` sits at the pane's foot, so it runs
///   under the content pane only and the sidebar column reaches the window's
///   bottom edge beside it. It reads only `AppState`, which the split gives
///   this pane. With the sidebar collapsed the pane fills the window, and so
///   does the bar.
struct MainDetailArea: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            DetailSectionHostPager(
                targetTab: DetailSectionHostPager.targetTab(
                    isConnected: appState.isConnected,
                    selectedRemoteSession: appState.selectedRemoteSession,
                    selectedRemoteProvider: appState.selectedRemoteProvider
                )
            )
            StatusBarView()
        }
    }
}
