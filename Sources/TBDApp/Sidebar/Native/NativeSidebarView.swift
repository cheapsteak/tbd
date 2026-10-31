import AppKit
import SwiftUI

/// Mounts the native (AppKit) sidebar inside the SwiftUI window. `SidebarView`
/// shows it, with `SidebarFooter` beneath, while `AppState.appKitSidebarKey`
/// is on. Spec: `docs/specs/2026-10-31-native-sidebar-design.md`.
struct NativeSidebarView: NSViewControllerRepresentable {
    /// Identifies the native sidebar's root view, so a caller can tell which
    /// sidebar path `SidebarView` mounted without knowing the controller type
    /// behind it.
    static let rootViewIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.root")

    @Environment(AppState.self) private var appState

    /// The controller reads its settings from `appState.userDefaults`, the
    /// store the SwiftUI sidebar's `@AppStorage` keys live in.
    func makeNSViewController(context: Context) -> SidebarContainerController {
        let controller = SidebarContainerController(appState: appState, defaults: appState.userDefaults)
        controller.view.identifier = Self.rootViewIdentifier
        return controller
    }

    /// Deliberately empty. The controller observes `AppState` itself, so no
    /// outline mutation ever runs inside SwiftUI's update pass: mutating a
    /// table during that pass blanked the transcript's table.
    func updateNSViewController(_ nsViewController: SidebarContainerController, context: Context) {}
}
