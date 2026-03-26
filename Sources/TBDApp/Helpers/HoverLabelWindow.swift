import AppKit

/// A borderless, transparent child window that shows the full text of a
/// truncated label — positioned exactly over the original text so it looks
/// like the label expanded in place. Escapes SwiftUI's NavigationSplitView
/// clipping because it's a separate window.
final class HoverLabelWindow: NSPanel {
    private static var shared: HoverLabelWindow?
    private let label = NSTextField(labelWithString: "")

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        ignoresMouseEvents = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 3
        // Use the system sidebar background
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        contentView = container

        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        container.addSubview(label)
    }

    static func show(text: String, font: NSFont, origin: CGRect) {
        guard let mainWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let panel = shared ?? HoverLabelWindow()
        shared = panel

        panel.label.font = font
        panel.label.stringValue = text
        panel.label.sizeToFit()

        let labelSize = panel.label.fittingSize
        let padding = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 4)
        let windowWidth = labelSize.width + padding.left + padding.right
        let windowHeight = labelSize.height + padding.top + padding.bottom

        // Only show if text is actually truncated
        if windowWidth <= origin.width + 4 {
            hide()
            return
        }

        // Convert from SwiftUI global coordinates to screen coordinates
        // SwiftUI's global coordinate space has origin at top-left of the window's content
        let contentRect = mainWindow.contentView?.frame ?? mainWindow.frame
        let screenOrigin = mainWindow.frame.origin
        let screenX = screenOrigin.x + origin.minX
        // SwiftUI y is top-down, screen y is bottom-up
        let screenY = screenOrigin.y + contentRect.height - origin.maxY

        let windowFrame = NSRect(
            x: screenX,
            y: screenY,
            width: windowWidth,
            height: windowHeight
        )

        panel.label.frame = NSRect(
            x: padding.left,
            y: padding.bottom,
            width: labelSize.width,
            height: labelSize.height
        )

        panel.setFrame(windowFrame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: windowFrame.size)

        if panel.parent == nil {
            mainWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    static func hide() {
        guard let panel = shared else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
