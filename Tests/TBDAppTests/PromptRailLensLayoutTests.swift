import CoreGraphics
import Testing
@testable import TBDApp

/// The open lens's layout (lens spec, "The lens" → "Layout"). A 601pt rail
/// has 577pt free, as in the approved mock. Tier 1: pure values.
@Suite("PromptRailLensLayout")
struct PromptRailLensLayoutTests {
    private static let railHeight: CGFloat = 601
    private static let top = PromptRailLayout.topInset

    private static func geometry(_ count: Int, restOffset: CGFloat = 0) -> PromptRailLensGeometry {
        PromptRailLensGeometry(
            layout: PromptRailLayout(count: count, railHeight: railHeight), restOffset: restOffset)
    }

    /// The anchor for a pointer at `share` of the way down the resting column.
    private static func anchor(_ geometry: PromptRailLensGeometry, at share: CGFloat = 0.5) -> PromptRailLensAnchor {
        geometry.anchor(pointerY: top + geometry.columnHeight * share)
    }

    /// Every centre from 0 through `count`, `perRow` steps to a row.
    private static func centres(_ count: Int, perRow: Int = 4) -> [CGFloat] {
        (0...(count * perRow)).map { CGFloat($0) / CGFloat(perRow) }
    }

    /// A notch's resting centre in rail coordinates.
    private static func restingCentre(of notch: Int, in geometry: PromptRailLensGeometry) -> CGFloat {
        top + (CGFloat(notch) + 0.5) * geometry.restPitch - geometry.restOffset
    }

    private static func isClose(_ a: [CGFloat], _ b: [CGFloat], within tolerance: CGFloat = 1e-9) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where !(abs(x - y) <= tolerance) { return false }
        return true
    }

    /// Neither end of the column moves, wherever the lens is centred.
    @Test(arguments: [8, 12, 40, 120, 300])
    func endsHold(count: Int) {
        let geometry = Self.geometry(count)
        let anchor = Self.anchor(geometry)
        let end = Self.top + geometry.columnHeight
        var misses: [String] = []
        for centre in Self.centres(count) {
            let rows = geometry.rows(centre: centre, anchor: anchor)
            let first = rows.tops.first ?? .nan
            let bottom = (rows.tops.last ?? .nan) + (rows.heights.last ?? .nan)
            if !(abs(first - Self.top) <= 0.5 && abs(bottom - end) <= 0.5) {
                misses.append("centre \(centre): \(first)…\(bottom)")
            }
        }
        #expect(misses.isEmpty, "\(count) prompts: the column is \(Self.top)…\(end), but \(misses.prefix(5))")
    }

    @Test(arguments: [8, 12, 40, 120, 300])
    func noGapsOrOverlaps(count: Int) {
        let geometry = Self.geometry(count)
        let anchor = Self.anchor(geometry)
        var misses: [String] = []
        for centre in Self.centres(count) {
            let rows = geometry.rows(centre: centre, anchor: anchor)
            guard rows.tops.count == count, rows.heights.count == count else {
                misses.append("centre \(centre): \(rows.tops.count) tops, \(rows.heights.count) heights")
                continue
            }
            for index in 0..<(count - 1) {
                let gap = rows.tops[index + 1] - (rows.tops[index] + rows.heights[index])
                if !(abs(gap) <= 1e-6) { misses.append("centre \(centre), after row \(index): \(gap)") }
            }
        }
        #expect(misses.isEmpty, "\(count) prompts: \(misses.prefix(5))")
    }

    @Test func peakIs26WithRoom() {
        let geometry = Self.geometry(40)
        let tallest = geometry.rows(centre: 20.5, anchor: Self.anchor(geometry)).heights.max() ?? 0
        #expect(abs(tallest - 26) <= 0.01, "the tallest row is \(tallest)pt")
    }

    /// Outside the few-prompts case, no row is taller than the peak, wherever
    /// the lens opened and wherever it is centred.
    @Test func neverTallerThanPeak() {
        var misses: [String] = []
        for count in 8...40 {
            let geometry = Self.geometry(count)
            for share in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
                let anchor = Self.anchor(geometry, at: share)
                for centre in Self.centres(count) {
                    let tallest = geometry.rows(centre: centre, anchor: anchor).heights.max() ?? .nan
                    if !(tallest <= 26.5) {
                        misses.append("\(count) prompts, opened at \(share), centre \(centre): \(tallest)pt")
                    }
                }
            }
        }
        #expect(misses.isEmpty, "\(misses.prefix(5))")
    }

    @Test(arguments: [120, 300])
    func floorHolds(count: Int) {
        let geometry = Self.geometry(count)
        let anchor = Self.anchor(geometry)
        var misses: [String] = []
        for centre in Self.centres(count) {
            let thinnest = geometry.rows(centre: centre, anchor: anchor).heights.min() ?? .nan
            if !(thinnest >= PromptRailLensGeometry.sliverFloor - 1e-9) {
                misses.append("centre \(centre): \(thinnest)pt")
            }
        }
        #expect(misses.isEmpty, "\(count) prompts: \(misses.prefix(5))")
    }

    /// Seven or fewer prompts rest at the peak or taller, so the lens keeps
    /// the resting rows; eight do not.
    @Test(arguments: [1, 3, 7])
    func fewPromptsKeepRest(count: Int) {
        let geometry = Self.geometry(count)
        #expect(geometry.keepsRestingRows)
        let resting = PromptRailLensRows.resting(geometry)
        for share in [0, 0.5, 1] as [CGFloat] {
            let anchor = Self.anchor(geometry, at: share)
            for centre in Self.centres(count) {
                let rows = geometry.rows(centre: centre, anchor: anchor)
                #expect(rows == resting, "\(count) prompts, opened at \(share), centre \(centre)")
            }
        }
        #expect(!Self.geometry(8).keepsRestingRows)
    }

    /// Past the floor, 600 prompts in 577pt, the column slides: the centre
    /// row stays on the rail, and it moves down the rail as the centre does.
    @Test func pastFloorSlides() {
        let geometry = Self.geometry(600)
        #expect(geometry.restOverflows)
        let anchor = Self.anchor(geometry)
        let railEnd = Self.railHeight - PromptRailLayout.bottomInset
        var previousY = -CGFloat.infinity
        var misses: [String] = []
        for centre in Self.centres(600, perRow: 2) {
            let rows = geometry.rows(centre: centre, anchor: anchor)
            guard rows.tops.count == 600, rows.heights.count == 600 else {
                misses.append("centre \(centre): \(rows.tops.count) tops, \(rows.heights.count) heights")
                continue
            }
            if !rows.overflows { misses.append("centre \(centre) does not overflow") }
            let row = min(Int(centre), 599)
            let bandTop = rows.tops[row]
            let bandBottom = bandTop + rows.heights[row]
            if !(bandBottom >= Self.top && bandTop <= railEnd) {
                misses.append("centre \(centre): row \(row) at \(bandTop)…\(bandBottom) is off the rail")
            }
            let y = rows.y(ofFraction: centre)
            if !(y >= previousY - 1e-9) { misses.append("centre \(centre) sits at \(y), above \(previousY)") }
            previousY = y
        }
        #expect(misses.isEmpty, "\(misses.prefix(5))")
    }

    @Test func blendRoundTrips() throws {
        let geometry = Self.geometry(40)
        let resting = PromptRailLensRows.resting(geometry)
        let lens = geometry.rows(centre: 17.3, anchor: Self.anchor(geometry))
        try #require(resting.tops.count == 40 && lens.tops.count == 40)

        let closed = resting.blended(toward: lens, fraction: 0)
        #expect(Self.isClose(closed.tops, resting.tops) && Self.isClose(closed.heights, resting.heights))
        #expect(closed.overflows == resting.overflows)

        let open = resting.blended(toward: lens, fraction: 1)
        #expect(Self.isClose(open.tops, lens.tops) && Self.isClose(open.heights, lens.heights))
        #expect(open.overflows == lens.overflows)

        let half = resting.blended(toward: lens, fraction: 0.5)
        let midTops = zip(resting.tops, lens.tops).map { ($0 + $1) / 2 }
        let midHeights = zip(resting.heights, lens.heights).map { ($0 + $1) / 2 }
        #expect(Self.isClose(half.tops, midTops) && Self.isClose(half.heights, midHeights))
        // Both ends hold through the blend.
        #expect(abs((half.tops.first ?? .nan) - Self.top) <= 0.5)
        let halfBottom = (half.tops.last ?? .nan) + (half.heights.last ?? .nan)
        #expect(abs(halfBottom - (Self.top + geometry.columnHeight)) <= 0.5)
    }

    @Test func restingFollowsPitchAndOffset() throws {
        let windowed = Self.geometry(300, restOffset: 100)
        let rows = PromptRailLensRows.resting(windowed)
        try #require(rows.tops.count == 300 && rows.heights.count == 300)
        #expect(rows.tops.first == Self.top - 100)
        #expect(abs(rows.tops[1] - rows.tops[0] - 4) <= 1e-9)
        #expect(rows.heights.first == 4)
        #expect(rows.overflows)
        #expect(!PromptRailLensRows.resting(Self.geometry(40)).overflows)
    }

    /// `y(ofFraction:)` inverts `fraction(atY:)` inside the column, and
    /// `index(atY:)` clamps to the ends.
    @Test func fractionAndYAreInverse() {
        let geometry = Self.geometry(40)
        let rows = geometry.rows(centre: 20.5, anchor: Self.anchor(geometry))
        for y in stride(from: Self.top + 1, to: Self.top + geometry.columnHeight - 1, by: 7) {
            let back = rows.y(ofFraction: rows.fraction(atY: y))
            #expect(abs(back - y) <= 1e-9, "\(y) came back as \(back)")
        }
        #expect(rows.fraction(atY: 0) == 0)
        #expect(rows.fraction(atY: Self.railHeight) == 40)
        #expect(rows.index(atY: 0) == 0)
        #expect(rows.index(atY: Self.railHeight) == 39)
    }

    /// In the middle of the rail the lens opens on the notch under the
    /// pointer.
    @Test func openingKeepsPointedRowInMiddle() {
        let geometry = Self.geometry(40)
        for notch in 12...24 {
            let pointerY = Self.restingCentre(of: notch, in: geometry)
            let anchor = geometry.anchor(pointerY: pointerY)
            let centre = geometry.openingCentre(pointerY: pointerY, anchor: anchor)
            let opened = geometry.rows(centre: centre, anchor: anchor).index(atY: pointerY)
            #expect(opened == notch, "notch \(notch) opened on row \(String(describing: opened)), centre \(centre)")
        }
    }

    /// Near an end the centre is held inward, so the lens opens on a row
    /// nearer that end than the pointed notch (spec step 4: edge drift).
    @Test func openingNearEndDriftsToEnd() {
        let geometry = Self.geometry(40)
        func openedRow(_ notch: Int) -> Int? {
            let pointerY = Self.restingCentre(of: notch, in: geometry)
            let anchor = geometry.anchor(pointerY: pointerY)
            let centre = geometry.openingCentre(pointerY: pointerY, anchor: anchor)
            return geometry.rows(centre: centre, anchor: anchor).index(atY: pointerY)
        }
        let nearTop = openedRow(8) ?? -1
        let nearBottom = openedRow(36) ?? -1
        #expect((0...8).contains(nearTop), "notch 8 opened on row \(nearTop)")
        #expect((36...39).contains(nearBottom), "notch 36 opened on row \(nearBottom)")
    }

    @Test func emptyIsEmpty() {
        let geometry = Self.geometry(0)
        let anchor = geometry.anchor(pointerY: 100)
        let rows = geometry.rows(centre: 0, anchor: anchor)
        #expect(rows.heights.isEmpty && rows.tops.isEmpty)
        #expect(rows.index(atY: 50) == nil)
        #expect(rows.fraction(atY: 50) == 0)
        #expect(PromptRailLensRows.resting(geometry) == rows)
        #expect(geometry.openingCentre(pointerY: 100, anchor: anchor) == 0)
    }
}
