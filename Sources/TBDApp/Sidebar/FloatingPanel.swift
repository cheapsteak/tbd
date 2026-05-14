import AppKit
import SwiftUI

/// A borderless, non-activating floating panel for instant show/hide
/// without stealing focus from the parent text field.
class FloatingPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?

    init<Content: View>(content: Content) {
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

    func dismiss() {
        // `parent` is always nil now (we no longer call `addChildWindow`), so this is
        // a defensive no-op left in place to stay safe if a future change ever
        // reintroduces parenting.
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
