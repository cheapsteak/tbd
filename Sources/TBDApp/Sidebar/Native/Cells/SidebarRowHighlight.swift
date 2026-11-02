import AppKit

/// How the native sidebar's rows draw hover and selection: one shape for every
/// row, whatever its depth or kind, and one hue — the system accent colour, so
/// it follows the user's setting — at an alpha per state over the sidebar's
/// background. No grey, no border: hover is a faint wash of the selection's own
/// colour, and hovering a selected row deepens it.
///
/// Everything that draws a row's highlight reads these values. They are tuned
/// by eye; `SidebarRowHighlightTests` pins the shape, the content gap and the
/// hover and selection alphas, so a change to one changes the test with it.
enum SidebarRowHighlight {
    // MARK: Shape

    /// How far the highlight sits in from the row's leading and trailing
    /// edges. 0 runs it edge to edge. 8, with `cornerRadius` 6, gives the
    /// inset rounded shape of a macOS source list; the content then moves in
    /// to clear it (`contentShift(inset:margin:)`).
    static let horizontalInset: CGFloat = 0

    /// The highlight's corner radius. A run of adjacent selected rows rounds
    /// only its outer corners, so it reads as one band.
    static let cornerRadius: CGFloat = 0

    /// The least room between an inset highlight's edge and the content
    /// inside it: a row's leading glyph or a header's title, and the trailing
    /// controls and marks.
    static let minimumContentGap: CGFloat = 6

    // MARK: Colour

    /// The accent colour's alpha for each highlighted state, in one
    /// appearance.
    struct Alphas: Equatable, Sendable {
        var hovered: CGFloat
        var selected: CGFloat
        var selectedHovered: CGFloat
    }

    /// Over the light sidebar. Selected is the SwiftUI row's 0.2.
    static let light = Alphas(hovered: 0.075, selected: 0.20, selectedHovered: 0.28)

    /// Over the dark sidebar, where a faint accent wash reads weaker, so the
    /// hover steps are a little stronger.
    static let dark = Alphas(hovered: 0.11, selected: 0.20, selectedHovered: 0.29)

    /// The nest target's wash, under its 2 pt accent outline.
    static let nestWashAlpha: CGFloat = 0.12

    /// The accent's alpha for a row's state, or nil when the row draws no
    /// highlight.
    static func alpha(isSelected: Bool, isHovered: Bool, isDark: Bool) -> CGFloat? {
        let alphas = isDark ? dark : light
        switch (isSelected, isHovered) {
        case (true, true): return alphas.selectedHovered
        case (true, false): return alphas.selected
        case (false, true): return alphas.hovered
        case (false, false): return nil
        }
    }

    // MARK: Geometry

    /// The highlight's area in a row with `bounds`: the full height, `inset`
    /// in from either side. It depends on nothing else, so every row's
    /// highlight shares its left and right edges, and the indentation sits
    /// inside it.
    static func highlightRect(in bounds: NSRect, inset: CGFloat = horizontalInset) -> NSRect {
        NSRect(x: bounds.minX + inset, y: bounds.minY,
               width: max(bounds.width - 2 * inset, 0), height: bounds.height)
    }

    /// The ends of a row's highlight whose corners round.
    struct RoundedEnds: OptionSet, Sendable {
        let rawValue: Int

        static let top = RoundedEnds(rawValue: 1 << 0)
        static let bottom = RoundedEnds(rawValue: 1 << 1)
        static let both: RoundedEnds = [.top, .bottom]
    }

    /// Which ends of a row's highlight round. A selected row merges with its
    /// selected neighbours, as a source list's selection does: it rounds only
    /// the ends no selected row adjoins, so a run of selected rows is one band
    /// rounded at its top and bottom. An unselected row — a hovered one, even
    /// beside the selection — is a shape of its own.
    static func roundedEnds(isSelected: Bool, isPreviousRowSelected: Bool, isNextRowSelected: Bool) -> RoundedEnds {
        guard isSelected else { return .both }
        var ends: RoundedEnds = []
        if !isPreviousRowSelected { ends.insert(.top) }
        if !isNextRowSelected { ends.insert(.bottom) }
        return ends
    }

    /// `rect` as a path whose corners at `ends` round by `radius`, clamped to
    /// what the rect can hold; a plain rectangle when nothing rounds.
    /// - Parameter isFlipped: whether the drawing view's y grows downward, as
    ///   `NSTableRowView`'s does, which puts the top at `minY`.
    static func path(in rect: NSRect, radius: CGFloat, roundedEnds ends: RoundedEnds,
                     isFlipped: Bool) -> NSBezierPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard radius > 0, !ends.isEmpty else { return NSBezierPath(rect: rect) }
        if ends == .both { return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) }
        let top = isFlipped ? rect.minY : rect.maxY
        let bottom = isFlipped ? rect.maxY : rect.minY
        let topRadius = ends.contains(.top) ? radius : 0
        let bottomRadius = ends.contains(.bottom) ? radius : 0
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: top))
        appendCorner(to: path, at: NSPoint(x: rect.maxX, y: top),
                     toward: NSPoint(x: rect.maxX, y: bottom), radius: topRadius)
        appendCorner(to: path, at: NSPoint(x: rect.maxX, y: bottom),
                     toward: NSPoint(x: rect.minX, y: bottom), radius: bottomRadius)
        appendCorner(to: path, at: NSPoint(x: rect.minX, y: bottom),
                     toward: NSPoint(x: rect.minX, y: top), radius: bottomRadius)
        appendCorner(to: path, at: NSPoint(x: rect.minX, y: top),
                     toward: NSPoint(x: rect.midX, y: top), radius: topRadius)
        path.close()
        return path
    }

    /// The edge into `corner`, then the turn toward `next`: an arc of
    /// `radius`, or a square corner at 0.
    private static func appendCorner(to path: NSBezierPath, at corner: NSPoint, toward next: NSPoint,
                                     radius: CGFloat) {
        if radius > 0 {
            path.appendArc(from: corner, to: next, radius: radius)
        } else {
            path.line(to: corner)
        }
    }

    // MARK: Content clearance

    /// How far one side's content moves in so it clears an inset highlight's
    /// edge on that side by `minimumContentGap`.
    ///
    /// An edge-to-edge highlight's edges are the row's own, and the sidebar's,
    /// so content keeps the margins it has there and nothing moves.
    /// - Parameter margin: how far that side's content sits from the row's
    ///   edge before moving.
    static func contentShift(inset: CGFloat, margin: CGFloat) -> CGFloat {
        guard inset > 0 else { return 0 }
        return max(0, inset + minimumContentGap - margin)
    }
}
