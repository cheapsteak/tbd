import AppKit

/// How the native sidebar's hierarchy guide lines draw.
///
/// **Shape.** A worktree row whose worktree children show owns one line. It
/// starts in the owner's own row, just under the owner's leading icon, and
/// fades in from clear to full strength over `fadeLength`; with the icon
/// centred in a 28 pt row the stub is short, so the fade carries on into the
/// top of the first child's row. The line runs down under the icon's centre
/// (`SidebarNativeMetrics.guideLineOffset`), and each child branches off it:
/// a quarter turn of `branchRadius` at the child's vertical centre, then a
/// tick that stops `tickInset` short of the child's own content. The line
/// ends in its last child's turn, so nothing of it draws below the last
/// child; deeper rows above the last child draw it passing straight by.
/// Where a child shows its gutter pin, which sits on its parent's line, the
/// line leaves out the turn and tick and breaks across the pin's glyph
/// (`pinGapHalfHeight`), carrying on above and, to a later child, below.
/// `Role` names a row's part in one line, and `pieces(role:x:tickEnd:...)`
/// turns that part into the rectangles, curve and fade the row draws.
///
/// **Strength.** At rest a line is a quiet hairline. The line the hovered
/// row and each selected row is joined to — the one it starts, or the one it
/// branches off — is *active* and draws at full strength, so the group you
/// are in stands out. On a row that draws a highlight, every line takes the
/// highlight's accent colour, blended toward white, instead of grey, so a
/// neutral line never muddies the tint. Each line draws as one shape at its
/// alpha, so where its turn leaves the vertical the colour does not double.
///
/// Which lines are active is the list's hierarchy's to say
/// (`GuideHierarchy.activeGuideAncestor(of:)`), and which part of which line
/// a row draws too (`GuideHierarchy.guideRuns(of:)`), by one set of rules for
/// the outline and the dock; how each one draws is here, beside
/// `SidebarRowHighlight`'s constants, so tuning the lines is one edit.
/// `SidebarGuideLineTests` pins every value.
enum SidebarGuideLine {
    // MARK: Strength

    /// The alpha a line draws at in each state. It multiplies the colour's
    /// own alpha: the secondary label colour is translucent already, the
    /// highlight tint opaque.
    struct Alphas: Equatable, Sendable {
        /// A line at rest, in the secondary label colour.
        var rest: CGFloat
        /// An active line, in the secondary label colour.
        var active: CGFloat
        /// A line at rest on a highlighted row, in the highlight tint.
        var restOnHighlight: CGFloat
        /// An active line on a highlighted row, in the highlight tint.
        var activeOnHighlight: CGFloat

        /// No lines: a row draws no line whose alpha is 0.
        static let none = Alphas(rest: 0, active: 0, restOnHighlight: 0, activeOnHighlight: 0)
    }

    /// The lines' strengths. Active is close to
    /// `Color.secondary.opacity(0.25)`, and rest about half of it. Set this
    /// to `.none` to see the sidebar without guide lines.
    static let alphas = Alphas(rest: 0.12, active: 0.24, restOnHighlight: 0.30, activeOnHighlight: 0.55)

    // MARK: Width

    /// A resting line's width in device pixels. 1 is a hairline: 0.5 pt on
    /// a Retina display.
    static let restPixelWidth: CGFloat = 1

    /// An active line's width in points.
    static let activeWidth: CGFloat = 1

    /// The backing scale a row assumes when neither its window nor a screen
    /// can tell it one.
    static let defaultBackingScale: CGFloat = 2

    // MARK: Shape

    /// Half the height of a row's leading icon, a 12 pt square centred on
    /// the row: how far below the row's centre the icon ends.
    static let iconHalfHeight: CGFloat = 6

    /// The space between a parent's leading icon and the start of its line.
    static let stubGap: CGFloat = 2

    /// How far down a line runs from clear, where it starts, to full
    /// strength.
    static let fadeLength: CGFloat = 12

    /// How many evenly spaced stops sample the fade's smoothstep curve.
    static let fadeStopCount = 9

    /// The radius of the quarter turn where a child's branch leaves its
    /// parent's line.
    static let branchRadius: CGFloat = 4

    /// How far short of the child's own content the branch's tick stops.
    static let tickInset: CGFloat = 3

    /// How far above and below a row's centre the line the gutter pin sits
    /// on breaks: half the pin glyph's height — the 10 pt `pin` symbol draws
    /// 12 pt of ink, centred on the row — and 2 pt clear of it.
    static let pinGapHalfHeight: CGFloat = 8

    // MARK: Style

    /// How far a highlighted row's line is blended toward white, per
    /// appearance. On a highlighted row the line is the accent colour blended
    /// toward white, so it reads as a pale stripe of the highlight's own hue
    /// rather than a saturated accent line. 0 is the plain accent colour, 1
    /// is white.
    static let highlightWhiteMix: (light: CGFloat, dark: CGFloat) = (light: 0.53, dark: 0.53)

    /// `components` mixed `fraction` of the way toward white, per gamma-encoded
    /// component: `c * (1 - fraction) + fraction`.
    static func mixedTowardWhite(_ components: (r: CGFloat, g: CGFloat, b: CGFloat),
                                 fraction: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (r: components.r * (1 - fraction) + fraction,
         g: components.g * (1 - fraction) + fraction,
         b: components.b * (1 - fraction) + fraction)
    }

    /// The accent colour as `appearance` resolves it now, blended toward
    /// white by the appearance's mix in Display P3.
    static func resolvedHighlightTint(appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fraction = isDark ? highlightWhiteMix.dark : highlightWhiteMix.light
        var result = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            if let p3 = accent.usingColorSpace(.displayP3) {
                let mixed = mixedTowardWhite((r: p3.redComponent, g: p3.greenComponent, b: p3.blueComponent),
                                             fraction: fraction)
                result = NSColor(displayP3Red: mixed.r, green: mixed.g, blue: mixed.b, alpha: p3.alphaComponent)
            } else {
                result = accent.blended(withFraction: fraction, of: .white) ?? accent
            }
        }
        return result
    }

    /// The highlight tint per appearance name, resolved once, so a row
    /// redraw neither resolves the accent nor converts it to Display P3. A
    /// change to the system colours — the accent among them — empties it,
    /// and then it posts `didChangeNotification`, on which every row view
    /// drawing with it marks itself for display: a row nothing else redraws
    /// would otherwise keep the old tint. Every row view draws with `shared`;
    /// a test makes one of its own, on a notification centre of its own.
    @MainActor
    final class HighlightTintCache {
        /// The cache the row views draw with, listening on the default
        /// notification centre.
        static let shared = HighlightTintCache()

        /// Posted on `center`, on the main thread and with the cache as its
        /// object, once the cache has emptied: whatever drew with its tints
        /// draws again.
        nonisolated static let didChangeNotification = Notification.Name("tbd.sidebar.highlightTintDidChange")

        /// Where the cache hears that the system colours changed, and posts
        /// `didChangeNotification`.
        nonisolated let center: NotificationCenter
        /// The tints resolved so far, by appearance name.
        private(set) var colors: [NSAppearance.Name: NSColor] = [:]
        nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

        /// - Parameter center: where `NSColor.systemColorsDidChangeNotification`
        ///   arrives. It arrives on the main thread, and empties the cache at
        ///   once; one posted anywhere else empties it on the next main-loop
        ///   turn.
        init(center: NotificationCenter = .default) {
            self.center = center
            observer = center.addObserver(
                forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                HighlightTintCache.performOnMain { self?.invalidate() }
            }
        }

        deinit {
            if let observer { center.removeObserver(observer) }
        }

        /// The tint in `appearance`: the one resolved before, or
        /// `resolvedHighlightTint(appearance:)` now, kept for the next draw.
        func color(for appearance: NSAppearance) -> NSColor {
            if let cached = colors[appearance.name] { return cached }
            let color = SidebarGuideLine.resolvedHighlightTint(appearance: appearance)
            colors[appearance.name] = color
            return color
        }

        /// Empties the cache, so each tint resolves afresh on its next use,
        /// and tells whatever drew with it to draw again.
        func invalidate() {
            colors.removeAll()
            center.post(name: Self.didChangeNotification, object: self)
        }

        /// Runs `body` on the main actor: at once when already on the main
        /// thread, otherwise on the next main-loop turn.
        nonisolated private static func performOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { body() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
            }
        }
    }

    /// The colour a line draws in.
    enum ColorRole: Hashable, Sendable {
        case secondaryLabel
        /// The accent colour blended toward white (`highlightWhiteMix`), as
        /// `tints` keeps it.
        case highlightTint

        /// The colour in `appearance`.
        @MainActor
        func nsColor(appearance: NSAppearance, tints: HighlightTintCache) -> NSColor {
            switch self {
            case .secondaryLabel: .secondaryLabelColor
            case .highlightTint: tints.color(for: appearance)
            }
        }

        /// The colour resolved in `appearance`, alpha included.
        @MainActor
        func cgColor(appearance: NSAppearance, tints: HighlightTintCache) -> CGColor {
            var resolved: CGColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = nsColor(appearance: appearance, tints: tints).cgColor
            }
            return resolved ?? NSColor.secondaryLabelColor.cgColor
        }
    }

    /// How one line draws: its colour, the alpha over that colour, and its
    /// width in points.
    struct Style: Equatable, Sendable {
        var color: ColorRole
        var alpha: CGFloat
        var width: CGFloat
    }

    /// The style of a line that is active or at rest, on a row that draws a
    /// highlight or on a plain one, at `backingScale` device pixels per
    /// point. A scale of 0 or less reads as `defaultBackingScale`.
    static func style(isActive: Bool, isOnHighlight: Bool, backingScale: CGFloat,
                      alphas: Alphas = SidebarGuideLine.alphas) -> Style {
        let scale = backingScale > 0 ? backingScale : defaultBackingScale
        let width = isActive ? activeWidth : restPixelWidth / scale
        switch (isActive, isOnHighlight) {
        case (false, false): return Style(color: .secondaryLabel, alpha: alphas.rest, width: width)
        case (true, false): return Style(color: .secondaryLabel, alpha: alphas.active, width: width)
        case (false, true): return Style(color: .highlightTint, alpha: alphas.restOnHighlight, width: width)
        case (true, true): return Style(color: .highlightTint, alpha: alphas.activeOnHighlight, width: width)
        }
    }

    // MARK: A row's part in a line

    /// A row's part in one owner's line.
    enum Role: Equatable, Sendable {
        /// A row deeper in the subtree of a child that is not the owner's
        /// last: the line passes by, the row's full height.
        case passing
        /// A child of the owner, not the last: the line runs the row's full
        /// height, and the child's branch turns off it.
        case branch
        /// The owner's last child: the line runs down from the row's top and
        /// ends in the child's turn.
        case last
        /// The owner's own row: the line starts just under the owner's
        /// leading icon and runs to the row's bottom, fading in.
        case stub
    }

    /// One worktree row's line as a row below it draws it.
    struct Run: Equatable {
        /// The worktree row the line belongs to.
        var owner: SidebarNodeID
        /// The owner's indentation level: the line runs under its icon.
        var level: Int
        var role: Role
        /// The row is the owner's first child, directly under it, so the
        /// owner's fade-in carries on into the row's top.
        var continuesFade: Bool
    }

    /// One ancestor's line in a row's configuration.
    struct Guide: Equatable, Sendable {
        /// The owner's indentation level: the line runs under its icon.
        var level: Int
        var role: Role
        /// Where the owner's fade-in starts, down from this row's top edge:
        /// negative on the owner's first child, whose top carries the rest of
        /// the fade. Nil on every other row.
        var fadeStart: CGFloat?
    }

    /// A row's guide lines as a list keeps them, worked out once for its
    /// rows (`GuideHierarchy.rowGuides(of:)`), so a hover or a selection only
    /// looks them up.
    struct RowGuides: Equatable {
        /// The row's part in each line above it, outermost first.
        var guides: [Guide] = []
        /// Each guide's owner, in `guides`' order: what the active lines
        /// index.
        var owners: [SidebarNodeID] = []
        /// The row starts a line of its own.
        var startsGuide = false
    }

    /// The guides a row draws for `runs`, outermost first: each run's level
    /// and role, and on the owner's first child where the owner's fade-in
    /// started (`continuedFadeStart`).
    static func guides(for runs: [Run]) -> [Guide] {
        runs.map { run in
            Guide(level: run.level, role: run.role, fadeStart: run.continuesFade ? continuedFadeStart : nil)
        }
    }

    /// Where a parent's line starts in its own row, down from the row's top:
    /// `stubGap` under its leading icon.
    static func stubStart(rowHeight: CGFloat) -> CGFloat {
        rowHeight / 2 + iconHalfHeight + stubGap
    }

    /// The height of every row that owns a line. Only worktree rows own
    /// lines, and a worktree row is `SidebarNativeMetrics.rowHeight` tall in
    /// both its height classes: the subtitle variant stacks its two lines
    /// inside that height (`WorktreeRowCell.subtitleRowHeight`). How far an
    /// owner's fade carries into its first child is therefore one constant,
    /// not a lookup of the owner's row.
    static let ownerRowHeight: CGFloat = SidebarNativeMetrics.rowHeight

    /// Where a parent's fade-in starts, down from the top of its first
    /// child's row: above it, by the length of the stub the parent's own row
    /// holds.
    static let continuedFadeStart: CGFloat = stubStart(rowHeight: ownerRowHeight) - ownerRowHeight

    /// The indices of `ancestors` — a row's line owners, outermost first —
    /// whose lines are active.
    static func activeIndices<ID: Hashable>(of ancestors: [ID], active: Set<ID>) -> IndexSet {
        guard !active.isEmpty else { return [] }
        var indices = IndexSet()
        for (index, ancestor) in ancestors.enumerated() where active.contains(ancestor) {
            indices.insert(index)
        }
        return indices
    }

    // MARK: Geometry

    /// A child's branch: the line's centreline from `startY` down to the
    /// turn, a quarter turn of `radius`, and the tick out to `endX`, stroked
    /// at `width`. In the row's flipped coordinates, y growing down.
    struct Turn: Equatable, Sendable {
        /// The line's centreline: half a width right of its left edge.
        var lineX: CGFloat
        /// Where the stroke starts on the line: the row's top for the last
        /// child, the start of the turn otherwise.
        var startY: CGFloat
        /// The tick's centreline: half a width below its top edge.
        var tickY: CGFloat
        /// Where the tick ends.
        var endX: CGFloat
        var radius: CGFloat
        var width: CGFloat

        /// Where the turn leaves the line.
        var turnY: CGFloat { tickY - radius }
    }

    /// The span of a row over which its line fades in, and where the fade
    /// runs from: clear at `start`, full strength `length` below it.
    struct Fade: Equatable, Sendable {
        /// What the fade covers in this row.
        var rect: NSRect
        /// Where the line is clear. Above the row on the owner's first child.
        var start: CGFloat
        var length: CGFloat
    }

    /// What one line draws in one row, in the row's flipped coordinates: the
    /// filled verticals, a stroked turn, the fade masking them, and the style.
    struct Pieces: Equatable, Sendable {
        /// The line's straight runs, top to bottom: one, none on a last child
        /// whose line is all turn, or the two either side of the gutter pin.
        var verticals: [NSRect]
        var turn: Turn?
        var fade: Fade?
        var style: Style
    }

    /// The pieces a row draws for its `role` in one line, or nil when it
    /// draws none.
    ///
    /// The line starts at `x` rounded down to a device-pixel boundary and
    /// runs right from there, so a width of whole device pixels covers whole
    /// pixels and draws crisp; a hairline centred on a whole point would
    /// straddle two half-lit pixels instead. The tick's top edge sits on the
    /// row's centre rounded down the same way, so it too covers whole pixel
    /// rows, and the turn's stroke runs half a width inside both edges to
    /// join them.
    /// - Parameters:
    ///   - x: the line's x: under its owner's icon.
    ///   - tickEnd: where a branch's tick stops, `tickInset` short of the
    ///     row's own content.
    ///   - fadeStart: where the owner's fade-in started, down from the row's
    ///     top, on the owner's first child; a stub's fade starts where the
    ///     stub does, whatever this says.
    ///   - bounds: the row's bounds, flipped: `minY` is the top edge.
    ///   - pinGap: the gutter pin sits on this line, centred on the row, and
    ///     covers its turn and tick: the line leaves out both, and breaks
    ///     across the pin's glyph, `pinGapHalfHeight` above and below the
    ///     row's centre. What runs above the pin keeps the fade; what runs
    ///     below it draws only where the line goes on to a later child.
    static func pieces(role: Role, x: CGFloat, tickEnd: CGFloat, fadeStart: CGFloat?, style: Style,
                       in bounds: NSRect, backingScale: CGFloat,
                       fadeLength: CGFloat = SidebarGuideLine.fadeLength, pinGap: Bool = false) -> Pieces? {
        guard style.alpha > 0, style.width > 0, bounds.height > 0 else { return nil }
        let scale = backingScale > 0 ? backingScale : defaultBackingScale
        let width = style.width
        let left = (x * scale).rounded(.down) / scale
        let lineX = left + width / 2
        let bottom = bounds.maxY
        let fadeY: CGFloat?
        var top = bounds.minY
        if role == .stub {
            top = bounds.minY + stubStart(rowHeight: bounds.height)
            fadeY = top
        } else if let fadeStart {
            fadeY = bounds.minY + fadeStart
            top = max(top, bounds.minY + fadeStart)
        } else {
            fadeY = nil
        }
        guard top < bottom else { return nil }

        let tickTop = (bounds.midY * scale).rounded(.down) / scale
        let tickY = tickTop + width / 2
        let endX = max(tickEnd, lineX + branchRadius)
        func vertical(from start: CGFloat, to end: CGFloat) -> NSRect? {
            end > start ? NSRect(x: left, y: start, width: width, height: end - start) : nil
        }
        var verticals: [NSRect] = []
        var turn: Turn?
        switch role {
        case .passing, .stub:
            if let run = vertical(from: top, to: bottom) { verticals.append(run) }
        case .branch:
            if let run = vertical(from: top, to: bottom) { verticals.append(run) }
            turn = Turn(lineX: lineX, startY: tickY - branchRadius, tickY: tickY, endX: endX,
                        radius: branchRadius, width: width)
        case .last:
            turn = Turn(lineX: lineX, startY: min(top, tickY - branchRadius), tickY: tickY, endX: endX,
                        radius: branchRadius, width: width)
        }

        if pinGap {
            // The straight run the line makes down the row — on a last child,
            // down to where it would turn — less the pin's span.
            let spanTop = verticals.first?.minY ?? turn?.startY ?? top
            let spanBottom = verticals.first?.maxY ?? turn?.turnY ?? bottom
            let gapTop = ((bounds.midY - pinGapHalfHeight) * scale).rounded(.down) / scale
            let gapBottom = ((bounds.midY + pinGapHalfHeight) * scale).rounded(.up) / scale
            verticals.removeAll(keepingCapacity: true)
            if let above = vertical(from: spanTop, to: min(gapTop, spanBottom)) { verticals.append(above) }
            if let below = vertical(from: max(gapBottom, spanTop), to: spanBottom) { verticals.append(below) }
            turn = nil
            guard !verticals.isEmpty else { return nil }
        }

        var fade: Fade?
        if let fadeY, fadeLength > 0 {
            let lineTop = verticals.first?.minY ?? turn?.startY ?? top
            let spanTop = max(fadeY, lineTop)
            let spanBottom = min(fadeY + fadeLength, bottom)
            if spanBottom > spanTop {
                let right = max(left + width, turn?.endX ?? left)
                fade = Fade(rect: NSRect(x: left, y: spanTop, width: right - left, height: spanBottom - spanTop),
                            start: fadeY, length: fadeLength)
            }
        }
        return Pieces(verticals: verticals, turn: turn, fade: fade, style: style)
    }

    /// The turn's stroke: down the line from `startY`, the quarter turn,
    /// then the tick.
    static func turnPath(_ turn: Turn) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: turn.lineX, y: turn.startY))
        path.addArc(tangent1End: CGPoint(x: turn.lineX, y: turn.tickY),
                    tangent2End: CGPoint(x: turn.endX, y: turn.tickY), radius: turn.radius)
        path.addLine(to: CGPoint(x: turn.endX, y: turn.tickY))
        return path
    }

    // MARK: Fade

    /// The smoothstep curve, `t * t * (3 - 2t)`, with `t` clamped to 0...1:
    /// the line's opacity `t` of the way through its fade.
    static func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// One stop of the fade's gradient: its location through the fade, and
    /// the line's opacity there.
    struct FadeStop: Equatable, Sendable {
        var location: CGFloat
        var alpha: CGFloat
    }

    /// `count` evenly spaced stops from clear to opaque along the smoothstep
    /// curve.
    static func fadeStops(count: Int = SidebarGuideLine.fadeStopCount) -> [FadeStop] {
        guard count > 1 else { return [FadeStop(location: 0, alpha: 1)] }
        return (0..<count).map { index in
            let location = CGFloat(index) / CGFloat(count - 1)
            return FadeStop(location: location, alpha: smoothstep(location))
        }
    }

    /// The fade's mask: grey stops whose alpha follows `fadeStops()`. Made
    /// once, since it never changes; a `CGGradient` is immutable once made.
    nonisolated(unsafe) static let fadeGradient: CGGradient? = makeFadeGradient()

    /// Builds `fadeGradient`.
    static func makeFadeGradient() -> CGGradient? {
        let stops = fadeStops()
        let components: [CGFloat] = stops.flatMap { [0, $0.alpha] }
        let locations: [CGFloat] = stops.map(\.location)
        return CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: components,
                          locations: locations, count: stops.count)
    }

    // MARK: Drawing

    /// Draws `pieces` in `color` into `context`, whose coordinates are the
    /// row's flipped ones. The pieces draw opaque into one transparency
    /// layer, the fade masks the layer, and the layer composites at the
    /// style's alpha times the colour's own, so the line is one shape: where
    /// the turn leaves the vertical the colour does not double.
    static func draw(_ pieces: Pieces, color: CGColor, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(pieces.style.alpha * color.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let opaque = color.copy(alpha: 1) ?? color
        context.setFillColor(opaque)
        context.setStrokeColor(opaque)
        for vertical in pieces.verticals {
            context.fill(vertical)
        }
        if let turn = pieces.turn {
            context.setLineWidth(turn.width)
            context.setLineCap(.butt)
            context.addPath(turnPath(turn))
            context.strokePath()
        }
        if let fade = pieces.fade, let gradient = fadeGradient {
            context.saveGState()
            context.clip(to: fade.rect)
            context.setBlendMode(.destinationIn)
            context.drawLinearGradient(gradient, start: CGPoint(x: fade.rect.minX, y: fade.start),
                                       end: CGPoint(x: fade.rect.minX, y: fade.start + fade.length), options: [])
            context.restoreGState()
        }
        context.endTransparencyLayer()
    }
}
