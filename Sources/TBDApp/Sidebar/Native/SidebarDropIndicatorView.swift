import AppKit

/// The native sidebar's insertion line: where a drag's rows would land
/// between two rows (spec "Drag and drop", "Feedback").
///
/// The outline draws no drop feedback of its own
/// (`draggingDestinationFeedbackStyle = .none`): no public API moves its
/// between-rows line, and it indents by raw outline level, a level off this
/// sidebar's visual depth. So the controller draws the line here, from the
/// drop policy's answer, at the destination's visual depth: it starts on the
/// destination parent's guide line, with a small ring, and runs to the
/// trailing edge. The nest highlight is the row view's own
/// (`SidebarRowView.Configuration.isNestTarget`).
///
/// The view is laid over the outline's scroll view, beside the tooltip
/// overlay, and never takes a click: `hitTest` returns nil, so a press under
/// it reaches the row.
final class SidebarDropIndicatorView: NSView {
    /// Where the line starts, in the view's own coordinates: the ring's
    /// centre.
    struct Line: Equatable {
        var x: CGFloat
        var y: CGFloat
    }

    static let ringDiameter: CGFloat = 6
    static let lineWidth: CGFloat = 2
    /// The line stops this far short of the trailing edge.
    static let trailingInset: CGFloat = 4

    /// The line shown, or nil when there is none.
    private(set) var line: Line?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ line: Line) {
        guard line != self.line else { return }
        self.line = line
        needsDisplay = true
    }

    func hide() {
        guard line != nil else { return }
        line = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line else { return }
        let diameter = Self.ringDiameter
        let ring = NSRect(x: line.x - diameter / 2, y: line.y - diameter / 2, width: diameter, height: diameter)
        NSColor.controlAccentColor.set()
        let ringPath = NSBezierPath(ovalIn: ring.insetBy(dx: 0.75, dy: 0.75))
        ringPath.lineWidth = 1.5
        ringPath.stroke()
        let start = ring.maxX
        let width = bounds.maxX - Self.trailingInset - start
        guard width > 0 else { return }
        NSRect(x: start, y: line.y - Self.lineWidth / 2, width: width, height: Self.lineWidth).fill()
    }
}
