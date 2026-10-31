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

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NativeSidebarPlaceholderController()
        controller.view.identifier = Self.rootViewIdentifier
        return controller
    }

    /// Deliberately empty. The controller observes `AppState` itself, so no
    /// outline mutation ever runs inside SwiftUI's update pass: mutating a
    /// table during that pass blanked the transcript's table.
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

/// Holds the native sidebar's place until the outline controller replaces it.
final class NativeSidebarPlaceholderController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}
