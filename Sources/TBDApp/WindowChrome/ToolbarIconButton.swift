import AppKit

/// A toolbar icon button whose hover highlight and hit area are its whole
/// frame: a light grey rounded square behind the glyph while the pointer is
/// over it, a darker one while it is pressed, and nothing at rest, as the
/// Claude desktop app's toolbar draws its icon buttons.
///
/// It draws the square itself because an accessory-bar button's hover
/// highlight, its bezel shown only while the pointer is inside, is smaller
/// than the button's frame. It is borderless, so its hit area is its frame,
/// as for any borderless `NSButton`, and the frames of the buttons in a host
/// tile it, leaving no gap between them. Being borderless inside a plain
/// host, it gets no Liquid Glass either way: the toolbar item's view is the
/// host, which forwards nothing to it (see `LeadingToolbarButtonsHost`).
///
/// The square's colour is `highlightFill(isHovered:isPressed:isEnabled:)`.
/// Both colours are semantic, so they follow the light and dark appearance.
/// The hover state comes from a tracking area over the visible rect, and is
/// cleared when the button moves to another window or is disabled.
final class ToolbarIconButton: NSButton {
    /// The square while the pointer is over the button.
    static let hoverFill = NSColor.quaternaryLabelColor
    /// The square while the button is pressed: darker than the hover square.
    static let pressedFill = NSColor.labelColor.withAlphaComponent(0.16)

    /// Whether the pointer is over the button, as its tracking area last
    /// reported.
    private var isHovered = false {
        didSet {
            if isHovered != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The tracking area that reports the pointer entering and leaving. It
    /// follows the visible rect itself, so it is added once.
    private var hoverArea: NSTrackingArea?

    /// A borderless, image-only button that does not scale its image.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
    }

    /// Decodes a copy, as AppKit makes when it copies a toolbar item by
    /// archiving its view. The archive carries the button's own settings.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// No alignment insets. A borderless button still reports some, so
    /// without this Auto Layout places the square layout on the alignment
    /// rect and the button's frame, bounds and hit area come out taller than
    /// the square (measured on CI: 28 x 33 and 28 x 29 for a 28 x 28 layout).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// The square's colour for a state: none while disabled, the pressed
    /// colour while pressed, the hover colour while the pointer is over the
    /// button, and none otherwise.
    static func highlightFill(isHovered: Bool, isPressed: Bool, isEnabled: Bool) -> NSColor? {
        guard isEnabled else { return nil }
        if isPressed { return pressedFill }
        if isHovered { return hoverFill }
        return nil
    }

    /// The square the highlight fills: the side of the button's shorter
    /// side, centred in `bounds`. `draw(_:)` pixel-aligns it, so no blurred
    /// edge row makes it read taller than it is wide.
    static func highlightRect(in bounds: NSRect) -> NSRect {
        let side = min(bounds.width, bounds.height)
        return NSRect(
            x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isHovered = false
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    /// Reads whether the pointer is over the button now. For after a menu
    /// the button popped up closes: the menu's tracking loop takes the
    /// pointer's movements, so the tracking area may not report a pointer
    /// that left while the menu was open.
    func refreshHover() {
        guard let window else {
            isHovered = false
            return
        }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = bounds.contains(pointer)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let fill = Self.highlightFill(isHovered: isHovered, isPressed: isHighlighted, isEnabled: isEnabled) {
            let radius = MainToolbarMetrics.iconButtonCornerRadius
            fill.setFill()
            let square = backingAlignedRect(Self.highlightRect(in: bounds), options: .alignAllEdgesNearest)
            NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius).fill()
        }
        super.draw(dirtyRect)
    }
}
