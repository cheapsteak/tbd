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
/// The guide lines follow depth, in the SwiftUI row's terms: a row's content
/// sits at the row inset plus `level * 16`, and an owner's line runs under its
/// leading icon, `SidebarNativeMetrics.guideLineOffset` into its level. The
/// configuration names each line the row draws a part of (`guides`) by its
/// owner's level and the row's part in it, and whether the row starts a line
/// of its own (`drawsStub`); `SidebarGuideLine` turns those into pieces.
///
/// How each line draws is `SidebarGuideLine`'s: a hairline at rest, full
/// strength for the lines the controller marks active (`activeGuides`,
/// `isStubActive`), and the accent colour over the row's hover or selection
/// highlight.
final class SidebarRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.row")

    struct Configuration: Equatable {
        /// Where a depth-0 row's content starts in the row view.
        var contentOrigin: CGFloat = 0
        /// The row's own indentation level: its content starts `level`
        /// indentation steps past `contentOrigin`.
        var level = 0
        /// The lines of the worktree rows above the row that it draws a part
        /// of, outermost first: each owner's level and the row's role in its
        /// line.
        var guides: [SidebarGuideLine.Guide] = []
        /// The lines of the focused group, which draw at full strength:
        /// indices into `guides`. The rest draw at rest.
        var activeGuides = IndexSet()
        /// The row's worktree children show, so its own line starts here,
        /// under its leading icon.
        var drawsStub = false
        /// The row's own line is the focused group's.
        var isStubActive = false
        /// The gutter pin is showing, so the line it sits on — the one a
        /// level up, under the pin's centre — leaves out its turn and tick
        /// and breaks across the pin.
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

        /// How many ancestors' lines the row draws a part of.
        var guideCount: Int { guides.count }
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

    /// The x of the line owned by a row at `level`: under its leading icon.
    /// Whole points, since the content origin, the indentation and the
    /// offset all are.
    func lineX(level: Int) -> CGFloat {
        configuration.contentOrigin + CGFloat(level) * SidebarNativeMetrics.indentation
            + SidebarNativeMetrics.guideLineOffset
    }

    /// The x of each ancestor's line the row draws, outermost first.
    var guideLineXs: [CGFloat] {
        configuration.guides.map { lineX(level: $0.level) }
    }

    /// Where a branch's tick ends: `SidebarGuideLine.tickInset` short of the
    /// row's own content.
    var tickEndX: CGFloat {
        configuration.contentOrigin + CGFloat(configuration.level) * SidebarNativeMetrics.indentation
            - SidebarGuideLine.tickInset
    }

    /// Device pixels per point where the row draws: its window's, else the
    /// main screen's, else `SidebarGuideLine.defaultBackingScale`.
    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? SidebarGuideLine.defaultBackingScale
    }

    /// What the row draws of each line, outermost ancestor first and its own
    /// line last, each in its style: active or at rest, and in the accent
    /// colour while the row draws a highlight — hovered or selected, not the
    /// nest target's wash. The pin lands in the row's own gutter, centred on
    /// the line a level up — its parent's — and over that line's turn and
    /// tick, so that line leaves out only what the pin covers rather than
    /// strike the glyph: it breaks across the pin and keeps the rest.
    func guidePieces(backingScale: CGFloat,
                     alphas: SidebarGuideLine.Alphas = SidebarGuideLine.alphas) -> [SidebarGuideLine.Pieces] {
        let isOnHighlight = highlightAlpha != nil
        let pinnedLevel = configuration.showsPinGap ? configuration.level - 1 : nil
        let tickEnd = tickEndX
        var result: [SidebarGuideLine.Pieces] = []
        func appendPieces(role: SidebarGuideLine.Role, level: Int, fadeStart: CGFloat?, isActive: Bool) {
            let style = SidebarGuideLine.style(isActive: isActive, isOnHighlight: isOnHighlight,
                                               backingScale: backingScale, alphas: alphas)
            if let pieces = SidebarGuideLine.pieces(
                role: role, x: lineX(level: level), tickEnd: tickEnd, fadeStart: fadeStart,
                style: style, in: bounds, backingScale: backingScale, pinGap: level == pinnedLevel) {
                result.append(pieces)
            }
        }
        for (index, guide) in configuration.guides.enumerated() {
            appendPieces(role: guide.role, level: guide.level, fadeStart: guide.fadeStart,
                         isActive: configuration.activeGuides.contains(index))
        }
        if configuration.drawsStub {
            appendPieces(role: .stub, level: configuration.level, fadeStart: nil,
                         isActive: configuration.isStubActive)
        }
        return result
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
    /// them on its tint. The pieces are in flipped coordinates, so an
    /// unflipped row draws them through a flip. Each style's alpha
    /// multiplies its colour's own, as `Color.secondary.opacity(_:)` does.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pieces = guidePieces(backingScale: backingScale)
        guard !pieces.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if !isFlipped {
            context.translateBy(x: 0, y: bounds.minY + bounds.maxY)
            context.scaleBy(x: 1, y: -1)
        }
        var colors: [SidebarGuideLine.ColorRole: CGColor] = [:]
        for piece in pieces {
            let role = piece.style.color
            let color = colors[role] ?? role.cgColor(appearance: effectiveAppearance)
            colors[role] = color
            SidebarGuideLine.draw(piece, color: color, in: context)
        }
        context.restoreGState()
    }
}
