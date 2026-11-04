import Foundation

extension AppState {
    /// UserDefaults key for the Settings → General → Experimental toggle
    /// "Tabs in the toolbar". On, each pane's tab strip draws in the window's
    /// top row, the worktree title moves into the main pane's row after the
    /// notes button and the project name, and the Servers button moves from
    /// the toolbar to the status bar. Spec:
    /// `docs/specs/2026-11-02-tabs-in-toolbar-design.md`.
    ///
    /// Stored in `AppState.userDefaults`, the store `MainWindowSplitView`
    /// passes its hosted panes and the toolbar controller watches. Three
    /// states: an absent key means nobody has chosen and follows
    /// `tabsInToolbarDefault`; the toggle stores an explicit `true` or `false`
    /// only when flipped. Read through `tabsInToolbarEnabled(defaults:)` or an
    /// `@AppStorage` whose default is that constant — never `bool(forKey:)`,
    /// which collapses "unset" into `false`.
    nonisolated static let tabsInToolbarKey = "window.tabsInToolbar"

    /// The one shipped default for `tabsInToolbarKey`, for the reason spelled
    /// out on `enableTranscriptDefault`. Off: the setting moves the tabs, the
    /// title and the Servers button users already rely on, so nobody's window
    /// rearranges until they ask. Graduation is a one-line change here, which
    /// reaches everyone who never touched the toggle and preserves every
    /// explicit choice.
    nonisolated static let tabsInToolbarDefault = false

    /// Read of the setting for non-View callers (the toolbar controller and its
    /// snapshot). Views read it through `@AppStorage` with
    /// `tabsInToolbarDefault` as the default.
    nonisolated static func tabsInToolbarEnabled(defaults: UserDefaults) -> Bool {
        tabsInToolbarEnabled(stored: defaults.object(forKey: tabsInToolbarKey) as? Bool)
    }

    /// The three-state decision with the shipped default injected, so a test
    /// can prove `nil` follows the default while an explicit choice holds
    /// against a change to it.
    nonisolated static func tabsInToolbarEnabled(
        stored: Bool?,
        shippedDefault: Bool = tabsInToolbarDefault
    ) -> Bool {
        stored ?? shippedDefault
    }
}
