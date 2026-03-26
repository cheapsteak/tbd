import AppKit
import SwiftUI

/// An NSTextField that instantly reveals its full text on hover when truncated.
/// Uses an NSPanel child window to escape SwiftUI's NavigationSplitView clipping.
final class ExpandingLabel: NSTextField {
    private var trackingArea: NSTrackingArea?
    private static var expansionPanel: NSPanel?

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

        let panel = Self.expansionPanel ?? {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = true
            p.ignoresMouseEvents = true
            Self.expansionPanel = p
            return p
        }()

        // Create a label matching this field's appearance
        let label = NSTextField(labelWithString: stringValue)
        label.font = font
        label.textColor = textColor
        label.lineBreakMode = .byClipping
        label.sizeToFit()

        let padding = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 4)
        let panelWidth = label.fittingSize.width + padding.left + padding.right
        let panelHeight = bounds.height

        label.frame = NSRect(
            x: padding.left,
            y: (panelHeight - label.fittingSize.height) / 2,
            width: label.fittingSize.width,
            height: label.fittingSize.height
        )

        // Convert this field's origin to screen coordinates
        let originInWindow = convert(bounds.origin, to: nil)
        let screenOrigin = window.convertPoint(toScreen: originInWindow)

        let panelFrame = NSRect(
            x: screenOrigin.x,
            y: screenOrigin.y,
            width: panelWidth,
            height: panelHeight
        )

        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 3
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.addSubview(label)

        panel.contentView = container
        panel.setFrame(panelFrame, display: true)

        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    override func mouseExited(with event: NSEvent) {
        Self.hideExpansion()
    }

    override func removeFromSuperview() {
        Self.hideExpansion()
        super.removeFromSuperview()
    }

    static func hideExpansion() {
        guard let panel = expansionPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

// MARK: - SwiftUI wrapper

struct ExpandingTextField: NSViewRepresentable {
    var text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var textColor: NSColor = .labelColor

    func makeNSView(context: Context) -> ExpandingLabel {
        let field = ExpandingLabel(frame: .zero)
        field.stringValue = text
        field.font = font
        field.textColor = textColor
        return field
    }

    func updateNSView(_ nsView: ExpandingLabel, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        nsView.textColor = textColor
    }
}
