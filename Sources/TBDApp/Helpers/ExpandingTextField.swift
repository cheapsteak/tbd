import AppKit
import SwiftUI

/// An NSTextField that instantly reveals its full text on hover when truncated.
/// Only the overflow portion past the sidebar gets a background — the part
/// overlapping the original text is transparent so the row's selection
/// highlight shows through underneath.
final class ExpandingLabel: NSTextField {
    private var trackingArea: NSTrackingArea?
    private static var panel: NSPanel?
    var onTruncationChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = false
        isEditable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func layout() {
        super.layout()
        onTruncationChanged?(isTruncated)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var isTruncated: Bool {
        intrinsicContentSize.width > bounds.width + 1
    }

    override func mouseEntered(with event: NSEvent) {
        guard isTruncated, let window = self.window else { return }

        let panel = Self.panel ?? {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = false
            p.ignoresMouseEvents = true
            Self.panel = p
            return p
        }()

        // Create a label matching this field's appearance
        let label = NSTextField(labelWithString: stringValue)
        label.font = font
        label.textColor = textColor
        label.lineBreakMode = .byClipping
        label.sizeToFit()

        let fullWidth = label.fittingSize.width
        let overflowWidth = fullWidth - bounds.width

        guard overflowWidth > 0 else { return }

        // Convert to screen coordinates
        let originInWindow = convert(bounds.origin, to: nil)
        let screenOrigin = window.convertPoint(toScreen: originInWindow)

        // Panel starts at the right edge of the text field (where truncation begins)
        // and extends for the overflow width + padding
        let padding: CGFloat = 4
        let panelFrame = NSRect(
            x: screenOrigin.x + bounds.width,
            y: screenOrigin.y,
            width: overflowWidth + padding,
            height: bounds.height
        )

        // Sidebar-material background for just the overflow
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelFrame.size))
        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .active

        // Position the label so that the overflow portion aligns correctly.
        // The label is full-width but offset left so only the overflowing
        // text is visible in the panel.
        label.frame = NSRect(
            x: -bounds.width,
            y: (panelFrame.height - label.fittingSize.height) / 2,
            width: fullWidth,
            height: label.fittingSize.height
        )

        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.addSubview(bg)
        container.addSubview(label)

        panel.contentView = container
        panel.setFrame(panelFrame, display: true)

        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    override func mouseExited(with event: NSEvent) {
        Self.hidePanel()
    }

    override func removeFromSuperview() {
        Self.hidePanel()
        super.removeFromSuperview()
    }

    static func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

// MARK: - SwiftUI wrapper

struct ExpandingTextField: NSViewRepresentable {
    var text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var textColor: NSColor = .labelColor
    @Binding var isTruncated: Bool

    func makeNSView(context: Context) -> ExpandingLabel {
        let field = ExpandingLabel(frame: .zero)
        field.stringValue = text
        field.font = font
        field.textColor = textColor
        field.onTruncationChanged = { truncated in
            DispatchQueue.main.async { self.isTruncated = truncated }
        }
        return field
    }

    func updateNSView(_ nsView: ExpandingLabel, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        nsView.textColor = textColor
        nsView.onTruncationChanged = { truncated in
            DispatchQueue.main.async { self.isTruncated = truncated }
        }
    }
}
