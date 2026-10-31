import Foundation

extension AppState {
    /// UserDefaults key for the Settings → Experimental toggle that draws the
    /// sidebar's list in an AppKit `NSOutlineView` instead of a SwiftUI
    /// `List`. App-side `UserDefaults` rather than a daemon `config` column
    /// because the behavior is pure sidebar presentation, the same placement
    /// as `sidebarWorkflowGroupsKey`. Spec:
    /// `docs/specs/2026-10-31-native-sidebar-design.md`, "Flag and rollout".
    ///
    /// Three states: an absent key means nobody has chosen and follows
    /// `appKitSidebarDefault`; the toggle stores an explicit `true` or `false`
    /// only when flipped. Read through `appKitSidebarEnabled(_:)` or an
    /// `@AppStorage` whose default is that constant — never `bool(forKey:)`,
    /// which collapses "unset" into `false`.
    ///
    /// `SidebarView` binds this key through `@AppStorage`, so flipping the
    /// toggle swaps the sidebar without a restart.
    static let appKitSidebarKey = "useAppKitSidebar"

    /// The one shipped default for `appKitSidebarKey`. Off: the native sidebar
    /// replaces a load-bearing path, so it soaks behind the flag first.
    /// Graduation is a one-line change here, which reaches everyone who never
    /// touched the toggle and preserves every explicit opt-out.
    static let appKitSidebarDefault = false

    /// Whether the native sidebar is on in `defaults`. An unset key takes the
    /// shipped default; an explicit choice holds against any value of it.
    static func appKitSidebarEnabled(_ defaults: UserDefaults) -> Bool {
        appKitSidebarEnabled(stored: defaults.object(forKey: appKitSidebarKey) as? Bool)
    }

    /// The three-state decision with the shipped default injected, so a test
    /// can prove `nil` follows the default while an explicit `false` holds
    /// against a default of `true`.
    static func appKitSidebarEnabled(
        stored: Bool?,
        shippedDefault: Bool = appKitSidebarDefault
    ) -> Bool {
        stored ?? shippedDefault
    }
}
