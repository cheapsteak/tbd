import Foundation

/// Which structure the main window is built with. Chosen once, when the
/// window is created, from the `useAppKitSidebar` flag; flipping the toggle
/// swaps the sidebar's contents at once and the window chrome at the next
/// launch. Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md,
/// "Switching".
enum MainWindowChrome: Equatable {
    /// The SwiftUI `NavigationSplitView` window with SwiftUI `.toolbar` items.
    case swiftUI
    /// The AppKit split view controller with an `NSToolbar`.
    case appKit

    /// `.appKit` exactly when the native sidebar flag is on in `defaults`.
    @MainActor
    static func resolve(_ defaults: UserDefaults) -> MainWindowChrome {
        AppState.appKitSidebarEnabled(defaults) ? .appKit : .swiftUI
    }
}
