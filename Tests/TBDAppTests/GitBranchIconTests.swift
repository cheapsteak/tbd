import Testing
import SwiftUI
@testable import TBDApp

// Tier 1: the branch glyph is authored on a 16x16 grid and scaled to its
// frame. These pin the scaling, since a regression there draws a glyph that
// silently overflows or shrinks to a smudge rather than failing loudly.

@Test func gitBranchIcon_staysInsideItsFrame() {
    for side in [11.0, 16.0, 64.0] {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let bounds = GitBranchIcon().path(in: rect).boundingRect
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(bounds),
                "glyph \(bounds) escaped its \(side)pt frame")
    }
}

@Test func gitBranchIcon_scalesToFillMostOfTheFrame() {
    // The 16-unit grid carries ~1.75 units of padding on the tight axis, so
    // the drawn glyph should cover most of the frame — a scale factor applied
    // twice, or not at all, breaks this.
    let bounds = GitBranchIcon().path(in: CGRect(x: 0, y: 0, width: 64, height: 64)).boundingRect
    #expect(bounds.width > 40 && bounds.height > 50)
}

@Test func gitBranchIcon_centersInANonSquareFrame() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 20)
    let bounds = GitBranchIcon().path(in: rect).boundingRect
    let leftGap = bounds.minX - rect.minX
    let rightGap = rect.maxX - bounds.maxX
    #expect(abs(leftGap - rightGap) < 0.01)
}
