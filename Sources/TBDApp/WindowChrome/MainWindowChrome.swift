import AppKit

/// The main window's own chrome: a transparent title bar over full-size
/// content, with no separator under it, and a unified toolbar, so the
/// sidebar's material paints up under the title bar, and clicks in the
/// toolbar row reach the panes' rows wherever no toolbar item sits. The app
/// applies it to its main window (`AppDelegate.applyMainWindowChrome()`), and
/// the window chrome tests apply it to theirs, so both windows are the same.
@MainActor
enum MainWindowChrome {
    /// Applies the chrome to `window`. Idempotent: safe to call repeatedly.
    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
    }
}
