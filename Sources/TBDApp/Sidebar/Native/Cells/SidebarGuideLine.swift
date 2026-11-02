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
/// `Role` names a row's part in one line, and `pieces(role:x:tickEnd:...)`
/// turns that part into the rectangle, curve and fade the row draws.
///
/// **Strength.** At rest a line is a quiet hairline. The lines of the group
/// the pointer or the selection is in — the *active* lines — draw at full
/// strength, so the group you are in stands out. On a row that draws a
/// highlight, every line takes the highlight's accent colour, blended toward
/// white, instead of grey, so a neutral line never muddies the tint. Each
/// line draws as one shape at its alpha, so where its turn leaves the
/// vertical the colour does not double.
///
/// Which lines are active is the tree's to say
/// (`SidebarTree.activeGuideAncestor(of:)`), and which part of which line a
/// row draws too (`SidebarTree.guideRuns(of:)`); how each one draws is here,
/// beside `SidebarRowHighlight`'s constants, so tuning the lines is one edit.
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

    /// The accent colour as `appearance` resolves it, blended toward white by
    /// the appearance's mix in Display P3.
    static func highlightTintColor(appearance: NSAppearance) -> NSColor {
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

    /// The colour a line draws in.
    enum ColorRole: Hashable, Sendable {
        case secondaryLabel
        /// The accent colour blended toward white (`highlightWhiteMix`).
        case highlightTint

        /// The colour in `appearance`.
        func nsColor(appearance: NSAppearance) -> NSColor {
            switch self {
            case .secondaryLabel: .secondaryLabelColor
            case .highlightTint: SidebarGuideLine.highlightTintColor(appearance: appearance)
            }
        }

        /// The colour resolved in `appearance`, alpha included.
        func cgColor(appearance: NSAppearance) -> CGColor {
            var resolved: CGColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = nsColor(appearance: appearance).cgColor
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

    /// The guides a row draws for `runs`, outermost first: each run's level
    /// and role, and on the owner's first child where the owner's fade-in
    /// started, from the owner's row height.
    static func guides(for runs: [Run], ownerHeight: (SidebarNodeID) -> CGFloat?) -> [Guide] {
        runs.map { run in
            let fadeStart = run.continuesFade ? ownerHeight(run.owner).map(continuedFadeStart(ownerHeight:)) : nil
            return Guide(level: run.level, role: run.role, fadeStart: fadeStart)
        }
    }

    /// Where a parent's line starts in its own row, down from the row's top:
    /// `stubGap` under its leading icon.
    static func stubStart(rowHeight: CGFloat) -> CGFloat {
        rowHeight / 2 + iconHalfHeight + stubGap
    }

    /// Where a parent's fade-in starts, down from the top of its first
    /// child's row: above it, by the length of the stub the parent's own row
    /// holds.
    static func continuedFadeStart(ownerHeight: CGFloat) -> CGFloat {
        stubStart(rowHeight: ownerHeight) - ownerHeight
    }

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

        /// How far through the fade the row's span starts, 0 to 1.
        var startFraction: CGFloat { (rect.minY - start) / length }
        /// How far through the fade the row's span ends, 0 to 1.
        var endFraction: CGFloat { (rect.maxY - start) / length }
    }

    /// What one line draws in one row, in the row's flipped coordinates: a
    /// filled vertical, a stroked turn, the fade masking them, and the style.
    struct Pieces: Equatable, Sendable {
        var vertical: NSRect?
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
    static func pieces(role: Role, x: CGFloat, tickEnd: CGFloat, fadeStart: CGFloat?, style: Style,
                       in bounds: NSRect, backingScale: CGFloat,
                       fadeLength: CGFloat = SidebarGuideLine.fadeLength) -> Pieces? {
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
        let vertical: NSRect?
        let turn: Turn?
        switch role {
        case .passing, .stub:
            vertical = NSRect(x: left, y: top, width: width, height: bottom - top)
            turn = nil
        case .branch:
            vertical = NSRect(x: left, y: top, width: width, height: bottom - top)
            turn = Turn(lineX: lineX, startY: tickY - branchRadius, tickY: tickY, endX: endX,
                        radius: branchRadius, width: width)
        case .last:
            vertical = nil
            turn = Turn(lineX: lineX, startY: min(top, tickY - branchRadius), tickY: tickY, endX: endX,
                        radius: branchRadius, width: width)
        }

        var fade: Fade?
        if let fadeY, fadeLength > 0 {
            let lineTop = vertical?.minY ?? turn?.startY ?? top
            let spanTop = max(fadeY, lineTop)
            let spanBottom = min(fadeY + fadeLength, bottom)
            if spanBottom > spanTop {
                let right = max(left + width, turn?.endX ?? left)
                fade = Fade(rect: NSRect(x: left, y: spanTop, width: right - left, height: spanBottom - spanTop),
                            start: fadeY, length: fadeLength)
            }
        }
        return Pieces(vertical: vertical, turn: turn, fade: fade, style: style)
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

    /// The fade's mask: grey stops whose alpha follows `fadeStops()`.
    static func fadeGradient() -> CGGradient? {
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
        if let vertical = pieces.vertical {
            context.fill(vertical)
        }
        if let turn = pieces.turn {
            context.setLineWidth(turn.width)
            context.setLineCap(.butt)
            context.addPath(turnPath(turn))
            context.strokePath()
        }
        if let fade = pieces.fade, let gradient = fadeGradient() {
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
