import SwiftUI

/// The git-branch glyph: two hollow nodes on a trunk, with a third node
/// branching off it. This is the icon VS Code and GitHub put beside a branch
/// name in their own status bars, so it reads as "branch" without a label —
/// which SF Symbols' generic `arrow.triangle.branch` does not.
///
/// Traced from Octicons `git-branch-16` (MIT, © GitHub, Inc.) as a native
/// `Shape` rather than a vendored asset: TBDApp is a bare SPM executable with
/// no Xcode asset catalog, and SVG needs one to render. Drawing it also lets
/// the stroke weight track the surrounding text instead of being baked into a
/// bitmap at one size.
struct GitBranchIcon: Shape {
    /// Octicons' design grid. Geometry below is authored in this space and
    /// scaled to whatever frame the caller gives us.
    private static let grid: CGFloat = 16
    /// Node ring: outer edge 2.25, inner hole 0.75 — a 1.5-wide stroke on a
    /// 1.5 radius, which is also the trunk's width.
    private static let strokeWidth: CGFloat = 1.5
    private static let nodeRadius: CGFloat = 1.5

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.grid
        var path = Path()

        // Nodes, drawn as circles and stroked below into rings.
        for center in [CGPoint(x: 4.25, y: 3.25),
                       CGPoint(x: 11.75, y: 3.25),
                       CGPoint(x: 4.25, y: 12.75)] {
            path.addEllipse(in: CGRect(
                x: center.x - Self.nodeRadius,
                y: center.y - Self.nodeRadius,
                width: Self.nodeRadius * 2,
                height: Self.nodeRadius * 2
            ))
        }

        // Trunk, stopping at the rings' edges so their holes stay open.
        path.move(to: CGPoint(x: 4.25, y: 4.75))
        path.addLine(to: CGPoint(x: 4.25, y: 11.25))

        // The branch: down out of the right node, a rounded turn to the left,
        // then a rounded turn back down to merge into the trunk. Each control
        // point sits where the two tangents meet, which is what makes the
        // corners read as arcs.
        path.move(to: CGPoint(x: 11.75, y: 4.75))
        path.addLine(to: CGPoint(x: 11.75, y: 6))
        path.addQuadCurve(to: CGPoint(x: 10, y: 7.75), control: CGPoint(x: 11.75, y: 7.75))
        path.addLine(to: CGPoint(x: 6, y: 7.75))
        path.addQuadCurve(to: CGPoint(x: 4.25, y: 9.5), control: CGPoint(x: 4.25, y: 7.75))

        let stroked = path.strokedPath(StrokeStyle(
            lineWidth: Self.strokeWidth,
            lineCap: .round,
            lineJoin: .round
        ))
        return stroked
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(
                translationX: rect.minX + (rect.width - Self.grid * scale) / 2,
                y: rect.minY + (rect.height - Self.grid * scale) / 2
            ))
    }
}
