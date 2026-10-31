import AppKit

/// The native sidebar's row view: draws the selection tint, the selected
/// provider's background and the hierarchy guide lines, under the cell.
///
/// Geometry, in the SwiftUI row's terms. A worktree row's content sits at the
/// row inset plus `depth * 16`, where its depth splits in two: the padding a
/// group header adds around its rows (`tintLevel`), and the row's worktree
/// ancestry (`guideCount`) — `WorktreeRowView`'s `indentLevel`. The SwiftUI row
/// draws its tint from where the group padding ends and one guide line per
/// worktree ancestor at `depth * 16 + 8` from there; this view draws the same.
final class SidebarRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.row")

    struct Configuration: Equatable {
        /// Where a depth-0 row's content starts in the row view.
        var contentOrigin: CGFloat = 0
        /// The levels of group padding before the row's own indentation: the
        /// tint starts there, and so do the guide lines.
        var tintLevel = 0
        /// One guide line per worktree ancestor.
        var guideCount = 0
        /// The gutter pin is showing, so the line it would sit on breaks.
        var showsPinGap = false
        /// The row is the selected provider's header: tinted at 0.13 across
        /// the full width, as its `listRowBackground` is.
        var highlightsSelectedProvider = false
        /// A drag would nest its rows under this one: the row draws the nest
        /// highlight over the selection tint's area. The outline draws no
        /// drop feedback of its own.
        var isNestTarget = false
    }

    var configuration = Configuration() {
        didSet { if configuration != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Cell text keeps its colour on the light tint rather than turning white
    /// as it would on the emphasized system selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// Where the tint and the guide lines start.
    var tintOrigin: CGFloat {
        configuration.contentOrigin + CGFloat(configuration.tintLevel) * SidebarNativeMetrics.indentation
    }

    /// The x of each guide line, nearest ancestor last.
    var guideLineXs: [CGFloat] {
        (0..<configuration.guideCount).map {
            tintOrigin + CGFloat($0) * SidebarNativeMetrics.indentation + SidebarNativeMetrics.guideLineOffset
        }
    }

    /// The tint's area: from `tintOrigin` to the trailing edge.
    var tintRect: NSRect {
        let x = tintOrigin
        return NSRect(x: x, y: 0, width: max(bounds.width - x, 0), height: bounds.height)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if configuration.highlightsSelectedProvider {
            NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
            bounds.fill()
        }
        if configuration.isNestTarget {
            drawNestHighlight()
        }
    }

    /// The SwiftUI row's tint: accent at 0.2 in a 4 pt rounded rectangle.
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: tintRect, xRadius: 4, yRadius: 4).fill()
    }

    /// The nest target: the tint's rounded rectangle, washed and outlined in
    /// the accent colour, so it reads as a destination rather than a
    /// selection.
    private func drawNestHighlight() {
        let rect = tintRect.insetBy(dx: 1, dy: 1)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// The guide lines go over the tint, as the SwiftUI row overlays them.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let xs = guideLineXs
        guard !xs.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // `Color.secondary.opacity(0.25)`: the secondary label colour with its
        // own alpha, then a quarter of that.
        context.setAlpha(0.25)
        NSColor.secondaryLabelColor.setFill()
        for (index, x) in xs.enumerated() {
            // The pin lands in the row's own gutter, on the nearest ancestor's
            // line: that one segment breaks rather than strike the glyph.
            if configuration.showsPinGap && index == xs.count - 1 { continue }
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
        context.restoreGState()
    }
}
