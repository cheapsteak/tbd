import AppKit

/// The native sidebar's row view: draws the row's highlight — hover,
/// selection, a selected header, a drag's nest target — and the hierarchy
/// guide lines over it, under the cell.
///
/// The highlight's horizontal extent is the same on every row, whatever its
/// depth or kind: `SidebarRowHighlight.highlightRect(in:)` of the row's
/// bounds, with the indentation inside it. Its colour and shape are
/// `SidebarRowHighlight`'s.
///
/// The guide lines follow depth, in the SwiftUI row's terms. A worktree row's
/// content sits at the row inset plus `depth * 16`, where its depth splits in
/// two: the padding a group header adds around its rows (`indentLevel`), and
/// the row's worktree ancestry (`guideCount`) — `WorktreeRowView`'s
/// `indentLevel`. One guide line runs per worktree ancestor, at
/// `depth * 16 + 8` from where the group padding ends, where the SwiftUI row
/// draws its lines.
///
/// How each line draws is `SidebarGuideLine`'s: a hairline at rest, full
/// strength for the lines the controller marks active (`activeGuides`), and
/// the accent colour over the row's hover or selection highlight.
final class SidebarRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.row")

    struct Configuration: Equatable {
        /// Where a depth-0 row's content starts in the row view.
        var contentOrigin: CGFloat = 0
        /// The levels of group padding before the row's own indentation: the
        /// guide lines start past them.
        var indentLevel = 0
        /// One guide line per worktree ancestor.
        var guideCount = 0
        /// The guide lines of the focused group, which draw at full
        /// strength: indices into `guideLineXs`, 0 for the outermost
        /// ancestor's line. The rest draw at rest.
        var activeGuides = IndexSet()
        /// The gutter pin is showing, so the line it would sit on breaks.
        var showsPinGap = false
        /// The row's model names it selected though the list does not select
        /// it: a repo, Scratch or provider header, which runs an action on a
        /// click instead of taking the list's selection. It draws as a
        /// selected row does.
        var isSelectedByModel = false
        /// The pointer is over the row.
        var isHovered = false
        /// A drag would nest its rows under this one: the row draws the nest
        /// highlight in the highlight's shape. The outline draws no drop
        /// feedback of its own.
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

    /// Cell text keeps its colour on the light highlight rather than turning
    /// white as it would on the emphasized system selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// A selected row's highlight joins its selected neighbours', and the
    /// table does not redraw a row view when they change.
    override var isPreviousRowSelected: Bool {
        didSet { if isPreviousRowSelected != oldValue { needsDisplay = true } }
    }

    override var isNextRowSelected: Bool {
        didSet { if isNextRowSelected != oldValue { needsDisplay = true } }
    }

    /// The light and dark appearances draw at different alphas.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A resting guide line is one device pixel wide, so a move to a screen
    /// of another scale redraws it.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// Where the row's own indentation starts, past its group padding: the
    /// guide lines are measured from here.
    var indentOrigin: CGFloat {
        configuration.contentOrigin + CGFloat(configuration.indentLevel) * SidebarNativeMetrics.indentation
    }

    /// The x of each guide line, nearest ancestor last. Whole points, since
    /// the content origin, the indentation and the offset all are.
    var guideLineXs: [CGFloat] {
        (0..<configuration.guideCount).map {
            indentOrigin + CGFloat($0) * SidebarNativeMetrics.indentation + SidebarNativeMetrics.guideLineOffset
        }
    }

    /// Device pixels per point where the row draws: its window's, else the
    /// main screen's, else `SidebarGuideLine.defaultBackingScale`.
    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? SidebarGuideLine.defaultBackingScale
    }

    /// The guide lines the row draws, outermost first, each in its style:
    /// active or at rest, and in the accent colour while the row draws a
    /// highlight — hovered or selected, not the nest target's wash. The pin
    /// lands in the row's own gutter, on the nearest ancestor's line, so that
    /// one segment breaks rather than strike the glyph.
    func guideSegments(backingScale: CGFloat,
                       alphas: SidebarGuideLine.Alphas = SidebarGuideLine.alphas) -> [SidebarGuideLine.Segment] {
        let xs = guideLineXs
        guard !xs.isEmpty else { return [] }
        return SidebarGuideLine.segments(
            xs: xs, active: configuration.activeGuides, gap: configuration.showsPinGap ? xs.count - 1 : nil,
            isOnHighlight: highlightAlpha != nil, in: bounds, backingScale: backingScale, alphas: alphas)
    }

    /// The highlight's area: the same on every row.
    var highlightRect: NSRect {
        SidebarRowHighlight.highlightRect(in: bounds)
    }

    /// The list selects the row and draws that selection: only then does
    /// `drawSelection(in:)` run.
    private var isListSelected: Bool {
        isSelected && selectionHighlightStyle != .none
    }

    /// Whether the row draws as selected: the list selects it, or its model
    /// does.
    var drawsSelected: Bool {
        isListSelected || configuration.isSelectedByModel
    }

    /// The accent's alpha for the row's state in its appearance, or nil when
    /// it draws no highlight.
    var highlightAlpha: CGFloat? {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return SidebarRowHighlight.alpha(isSelected: drawsSelected, isHovered: configuration.isHovered, isDark: isDark)
    }

    /// A row the list selects fills in `drawSelection(in:)`; every other
    /// state — hovered, selected by its model — fills here, so a row fills
    /// once whatever its state. The nest highlight draws under the list's
    /// selection.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if !isListSelected {
            fillHighlight()
        }
        if configuration.isNestTarget {
            drawNestHighlight()
        }
    }

    /// The list's selection, hovered or not, in the highlight's shape.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isListSelected else { return }
        fillHighlight()
    }

    private func fillHighlight() {
        guard let alpha = highlightAlpha else { return }
        let rect = highlightRect
        guard rect.width > 0, rect.height > 0 else { return }
        let ends = SidebarRowHighlight.roundedEnds(
            isSelected: drawsSelected, isPreviousRowSelected: isPreviousRowSelected,
            isNextRowSelected: isNextRowSelected)
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        SidebarRowHighlight.path(
            in: rect, radius: SidebarRowHighlight.cornerRadius, roundedEnds: ends, isFlipped: isFlipped
        ).fill()
    }

    /// The nest target: the highlight's shape, washed and outlined in the
    /// accent colour, so it reads as a destination rather than a selection.
    /// The outline runs just inside the shape, its corners concentric.
    private func drawNestHighlight() {
        let rect = highlightRect.insetBy(dx: 1, dy: 1)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = SidebarRowHighlight.path(
            in: rect, radius: max(SidebarRowHighlight.cornerRadius - 1, 0), roundedEnds: .both,
            isFlipped: isFlipped)
        NSColor.controlAccentColor.withAlphaComponent(SidebarRowHighlight.nestWashAlpha).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// The guide lines go over the highlight, as the SwiftUI row overlays
    /// them on its tint. Each style's alpha multiplies its colour's own, as
    /// `Color.secondary.opacity(_:)` does.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let segments = guideSegments(backingScale: backingScale)
        guard !segments.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        for segment in segments {
            context.saveGState()
            context.setAlpha(segment.style.alpha)
            segment.style.color.nsColor.setFill()
            segment.rect.fill()
            context.restoreGState()
        }
    }
}
