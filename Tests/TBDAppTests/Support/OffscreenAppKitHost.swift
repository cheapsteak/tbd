import AppKit

/// An `NSViewController` mounted in a real, offscreen `NSWindow` — the AppKit
/// twin of `OffscreenHost`, for controllers that own their view hierarchy
/// outright (the native sidebar's outline) and so need no hosting view.
///
/// What mounting buys: the controller's view is in a window, so tables lay out
/// rows, row views and cells exist for the visible rows, a clip view scrolls,
/// and a responder chain exists for key events. The window is borderless,
/// ordered front at a point far off every display, and never made key.
///
/// It drives nothing on its own. Call `layout()` to lay the window out, and use
/// `RunLoopPump` for run-loop work; neither drains `DispatchQueue.main` nor a
/// suspended `@MainActor` task (`Tests/CLAUDE.md`, "`@MainActor` tests: suspend
/// to drain, never pump").
///
/// Release follows `OffscreenHost.tearDown()`'s rules exactly:
/// `isReleasedWhenClosed` is set to `false` at creation and never flipped. A
/// window that has been ordered front keeps references AppKit owns and stays in
/// `NSApp.windows`; flipping the flag to make it leave sends a `release` ARC
/// never balanced, and the use-after-free lands in a later, unrelated test.
@MainActor
final class OffscreenAppKitHost {
    /// Far off every plausible display arrangement, as `OffscreenHost` uses.
    static let offscreenOrigin = NSPoint(x: -20_000, y: -20_000)

    var window: NSWindow { live(mountedWindow, "window") }
    var controller: NSViewController { live(mountedController, "controller") }

    /// Optional only so `tearDown()` can drop them; see `OffscreenHost`.
    private var mountedWindow: NSWindow?
    private var mountedController: NSViewController?

    private func live<T>(_ value: T?, _ name: String) -> T {
        guard let value else {
            preconditionFailure("OffscreenAppKitHost.\(name) was used after tearDown()")
        }
        return value
    }

    /// Mount `controller`'s view filling a window of `size`.
    ///
    /// - Parameter appearance: applied before the view is built, so colours a
    ///   view resolves once resolve against it. Aqua by default, so nothing
    ///   depends on the developer's system setting.
    init(controller: NSViewController, size: NSSize, appearance: NSAppearance? = NSAppearance(named: .aqua)) {
        // Enough of an application for AppKit to have an app object at all.
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(origin: Self.offscreenOrigin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let appearance { window.appearance = appearance }

        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        let view = controller.view
        view.frame = ground.bounds
        view.autoresizingMask = [.width, .height]
        ground.addSubview(view)
        window.contentView = ground

        mountedController = controller
        mountedWindow = window
        window.orderFront(nil)
        layout()
    }

    /// Lays the window's content out now.
    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Take the window down and let the controller go. Idempotent, and safe to
    /// call from a `defer`; the host is unusable afterwards.
    func tearDown() {
        guard let window = mountedWindow else { return }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        mountedController = nil
        mountedWindow = nil
    }
}
