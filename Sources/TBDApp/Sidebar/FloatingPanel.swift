import AppKit
import SwiftUI

/// A borderless, non-activating floating panel for instant show/hide
/// without stealing focus from the parent text field.
final class FloatingPanel: NSPanel {
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
            window.addChildWindow(self, ordered: .above)
            orderFront(nil)
        }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
