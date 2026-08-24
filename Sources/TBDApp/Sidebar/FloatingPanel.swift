import AppKit
import SwiftUI

/// A borderless, non-activating floating panel for instant show/hide.
/// Non-key by default so hover overlays (e.g. the emoji picker) never steal
/// focus from the parent rename field; pass `canBecomeKey: true` when the
/// panel hosts its own text input (e.g. the branch filter field).
class FloatingPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private let keyCapable: Bool

    init<Content: View>(content: Content, canBecomeKey: Bool = false) {
        keyCapable = canBecomeKey
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .none

        // Deactivation backstop. `level = .popUpMenu` (101) is a windowserver-
        // global level, so this panel floats above every *other* application's
        // windows too — and lowering the level cannot fix that, because any
        // level above 0 floats over other apps. The only cure is ordering the
        // window out when TBD stops being the active app. NSPanel defaults
        // `hidesOnDeactivate` to true only for *titled* panels; a
        // `.borderless`/`.nonactivatingPanel` panel opts out of that default, so
        // it has to be set explicitly. This is a backstop: the presenting model
        // is expected to close on deactivation too (see `HoverMenuModel`), but
        // if it ever holds stale state the panel still cannot paint over
        // another app.
        hidesOnDeactivate = true
        // A menu-shaped panel should not be captured by Mission Control or
        // stranded on another Space when the user switches desktops.
        collectionBehavior = [.transient, .ignoresCycle]

        let hosting = NSHostingView(rootView: AnyView(content))
        contentView = hosting
        hostingView = hosting
    }

    func updateContent<Content: View>(_ content: Content) {
        hostingView?.rootView = AnyView(content)
    }

    /// Show the panel below the given view, aligned to its leading edge.
    ///
    /// The parent window is used only for screen-coordinate conversion; we deliberately
    /// do *not* call `addChildWindow` here. Establishing a child-window relationship
    /// couples this panel's constraint invalidations into the parent split-view
    /// window's per-cycle update-pass budget, which can blow past the AppKit threshold
    /// and trigger an `NSGenericException` ("more Update Constraints in Window passes
    /// than there are views in the window"). The panel's `.popUpMenu` level is enough
    /// to keep it above other content without parenting.
    func show(relativeTo view: NSView) {
        guard let window = view.window else { return }
        let viewFrame = view.convert(view.bounds, to: nil)
        let screenFrame = window.convertToScreen(viewFrame)

        hostingView?.invalidateIntrinsicContentSize()
        let size = hostingView?.fittingSize ?? CGSize(width: 240, height: 100)

        let origin = NSPoint(
            x: screenFrame.minX,
            y: screenFrame.minY - size.height - 4
        )
        setFrame(NSRect(origin: origin, size: size), display: true)

        if !isVisible {
            orderFront(nil)
        }
    }

    /// Show to the trailing (right) side of `view`, vertically centered on it —
    /// the menu's leading edge sits at the trigger, its mid-height aligned with
    /// the trigger's center — clamped to the screen's visible frame so a tall
    /// menu near an edge stays on-screen. Falls back to the leading side if the
    /// menu won't fit on the right.
    func showAsMenu(relativeTo view: NSView) {
        guard let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        hostingView?.invalidateIntrinsicContentSize()
        let size = hostingView?.fittingSize ?? CGSize(width: 300, height: 400)
        let gap: CGFloat = 4
        let screen = (NSScreen.screens.first { $0.frame.contains(anchor.origin) }
            ?? NSScreen.main)?.visibleFrame ?? anchor
        var x = anchor.maxX + gap
        if x + size.width > screen.maxX { x = anchor.minX - size.width - gap }
        x = max(screen.minX, min(x, screen.maxX - size.width))
        var y = anchor.midY - size.height / 2       // vertically center on the anchor
        y = max(screen.minY, min(y, screen.maxY - size.height))
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if !isVisible { orderFront(nil) }
    }

    func dismiss() {
        // `parent` is always nil now (we no longer call `addChildWindow`), so this is
        // a defensive no-op left in place to stay safe if a future change ever
        // reintroduces parenting.
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override var canBecomeKey: Bool { keyCapable }
    override var canBecomeMain: Bool { false }
}
