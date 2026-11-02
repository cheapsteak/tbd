import AppKit

/// How the native sidebar's hierarchy guide lines draw. A line runs down a
/// worktree's subtree, one per worktree ancestor of each row in it. At rest
/// it is a quiet hairline. The lines of the group the pointer or the
/// selection is in — the *active* lines — draw at full strength, so the group
/// you are in stands out. On a row that draws a highlight, every line takes
/// the highlight's accent colour instead of grey, so a neutral line never
/// muddies the tint.
///
/// Which lines are active is the tree's to say
/// (`SidebarTree.activeGuideAncestor(of:)`); how each one draws is here,
/// beside `SidebarRowHighlight`'s constants, so tuning the lines is one edit.
/// `SidebarGuideLineTests` pins every value.
enum SidebarGuideLine {
    // MARK: Strength

    /// The alpha a line draws at in each state. It multiplies the colour's
    /// own alpha: the secondary label colour is translucent already, the
    /// accent colour opaque.
    struct Alphas: Equatable, Sendable {
        /// A line at rest, in the secondary label colour.
        var rest: CGFloat
        /// An active line, in the secondary label colour.
        var active: CGFloat
        /// A line at rest on a highlighted row, in the accent colour.
        var restOnHighlight: CGFloat
        /// An active line on a highlighted row, in the accent colour.
        var activeOnHighlight: CGFloat

        /// No lines: a row draws no line whose alpha is 0.
        static let none = Alphas(rest: 0, active: 0, restOnHighlight: 0, activeOnHighlight: 0)
    }

    /// The lines' strengths. Active is the SwiftUI row's
    /// `Color.secondary.opacity(0.25)`, and rest about half of it. Set this
    /// to `.none` to see the sidebar without guide lines.
    static let alphas = Alphas(rest: 0.12, active: 0.25, restOnHighlight: 0.30, activeOnHighlight: 0.55)

    // MARK: Width

    /// A resting line's width in device pixels. 1 is a hairline: 0.5 pt on
    /// a Retina display.
    static let restPixelWidth: CGFloat = 1

    /// An active line's width in points on a plain row.
    static let activeWidth: CGFloat = 1

    /// An active line's width in device pixels on a highlighted row: a
    /// hairline, 0.5 pt on a Retina display. A 1 pt accent line over the
    /// highlight reads too loud.
    static let activeOnHighlightPixelWidth: CGFloat = 1

    /// The backing scale a row assumes when neither its window nor a screen
    /// can tell it one.
    static let defaultBackingScale: CGFloat = 2

    // MARK: Style

    /// The colour a line draws in.
    enum ColorRole: Equatable, Sendable {
        case secondaryLabel
        case accent

        var nsColor: NSColor {
            switch self {
            case .secondaryLabel: .secondaryLabelColor
            case .accent: .controlAccentColor
            }
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
        let width: CGFloat
        switch (isActive, isOnHighlight) {
        case (false, _): width = restPixelWidth / scale
        case (true, false): width = activeWidth
        case (true, true): width = activeOnHighlightPixelWidth / scale
        }
        switch (isActive, isOnHighlight) {
        case (false, false): return Style(color: .secondaryLabel, alpha: alphas.rest, width: width)
        case (true, false): return Style(color: .secondaryLabel, alpha: alphas.active, width: width)
        case (false, true): return Style(color: .accent, alpha: alphas.restOnHighlight, width: width)
        case (true, true): return Style(color: .accent, alpha: alphas.activeOnHighlight, width: width)
        }
    }

    // MARK: Lines

    /// One line a row draws, in the row's coordinates.
    struct Segment: Equatable, Sendable {
        var rect: NSRect
        var style: Style
    }

    /// The lines a row draws, outermost first: one for each x, the full
    /// height of `bounds`, in its style.
    ///
    /// Each line starts at its x, rounded down to a device-pixel boundary —
    /// the xs are whole points, so nothing moves — and runs right from there,
    /// so a width of whole device pixels covers whole pixels and draws crisp.
    /// A hairline centred on a whole point would straddle two half-lit
    /// pixels instead.
    /// - Parameters:
    ///   - xs: each line's x, outermost first.
    ///   - active: the indices into `xs` of the active lines.
    ///   - gap: the index of a line the row leaves out, or nil.
    ///   - isOnHighlight: whether the row draws a highlight under its lines.
    static func segments(xs: [CGFloat], active: IndexSet, gap: Int?, isOnHighlight: Bool, in bounds: NSRect,
                         backingScale: CGFloat, alphas: Alphas = SidebarGuideLine.alphas) -> [Segment] {
        let scale = backingScale > 0 ? backingScale : defaultBackingScale
        var result: [Segment] = []
        for (index, x) in xs.enumerated() where index != gap {
            let lineStyle = Self.style(isActive: active.contains(index), isOnHighlight: isOnHighlight,
                                       backingScale: scale, alphas: alphas)
            guard lineStyle.alpha > 0, lineStyle.width > 0 else { continue }
            let left = (x * scale).rounded(.down) / scale
            result.append(Segment(
                rect: NSRect(x: left, y: bounds.minY, width: lineStyle.width, height: bounds.height),
                style: lineStyle))
        }
        return result
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
}
