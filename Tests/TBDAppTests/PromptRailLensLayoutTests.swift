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

    /// In a tall rail, seven or fewer prompts rest at the peak or taller, so
    /// the lens keeps the resting rows; eight do not.
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

    /// A short rail lowers the peak a mid-column bump draws, so few prompts
    /// there keep their resting rows too (spec step 0).
    @Test(arguments: [(1, 40), (2, 74), (3, 60), (4, 100), (5, 150)] as [(Int, CGFloat)])
    func fewPromptsInShortRailKeepRest(count: Int, railHeight: CGFloat) {
        let geometry = PromptRailLensGeometry(
            layout: PromptRailLayout(count: count, railHeight: railHeight), restOffset: 0)
        #expect(geometry.keepsRestingRows, "\(count) prompts in \(railHeight)pt rest at \(geometry.restPitch)pt")
        let resting = PromptRailLensRows.resting(geometry)
        for share in [0, 0.5, 1] as [CGFloat] {
            let anchor = Self.anchor(geometry, at: share)
            for centre in Self.centres(count) {
                let rows = geometry.rows(centre: centre, anchor: anchor)
                #expect(rows == resting, "\(count) prompts in \(railHeight)pt, opened at \(share), centre \(centre)")
            }
        }
    }

    /// 2 prompts in a 74pt rail rest at 25pt, above the 21.6pt peak a
    /// mid-column bump would draw there, so the pointed row is never the
    /// shorter one.
    @Test func twoPromptsInShortRailKeep25pt() {
        let geometry = PromptRailLensGeometry(layout: PromptRailLayout(count: 2, railHeight: 74), restOffset: 0)
        let anchor = geometry.anchor(pointerY: Self.top + 12.5)
        let heights = geometry.rows(centre: 0.5, anchor: anchor).heights
        #expect(Self.isClose(heights, [25, 25]), "\(heights)")
    }

    /// On short rails that do not keep their resting rows, no row is taller
    /// than the one the lens is centred on.
    @Test func pointedRowIsTallestOnShortRails() {
        var misses: [String] = []
        for railHeight in [60, 74, 100, 150, 200] as [CGFloat] {
            for count in 1...12 {
                let geometry = PromptRailLensGeometry(
                    layout: PromptRailLayout(count: count, railHeight: railHeight), restOffset: 0)
                for share in [0, 0.5, 1] as [CGFloat] {
                    let anchor = Self.anchor(geometry, at: share)
                    for centre in Self.centres(count) {
                        let heights = geometry.rows(centre: centre, anchor: anchor).heights
                        let pointed = PromptRailLensMath.row(containing: centre, count: count)
                        guard heights.count == count else {
                            misses.append("\(count) in \(railHeight)pt: \(heights.count) heights")
                            continue
                        }
                        let tallest = heights.max() ?? .nan
                        if !(tallest <= heights[pointed] + 0.5) {
                            misses.append(
                                "\(count) in \(railHeight)pt, opened at \(share), centre \(centre): "
                                    + "row \(pointed) is \(heights[pointed])pt, the tallest \(tallest)pt")
                        }
                    }
                }
            }
        }
        #expect(misses.isEmpty, "\(misses.prefix(5))")
    }

    /// A windowed rail never keeps its resting rows (spec step 0), however
    /// short: 20 prompts in a 52pt rail rest 4pt apart in a 28pt column,
    /// where a bump in mid-column would draw a peak under 4pt. Its lens
    /// slides past the floor (step 6), so wherever it is centred and
    /// wherever it opened, the centre's row lies on the column and the rows
    /// cover the column.
    @Test func windowedShortRailSlides() {
        let geometry = PromptRailLensGeometry(layout: PromptRailLayout(count: 20, railHeight: 52), restOffset: 0)
        #expect(geometry.restOverflows, "precondition: 20 prompts window a 52pt rail")
        #expect(!geometry.keepsRestingRows, "a windowed rail kept its resting rows")
        #expect(geometry.slidesPastFloor, "20 prompts at the floor overfill a 28pt column but do not slide")
        let end = Self.top + geometry.columnHeight
        var misses: [String] = []
        for share in [0, 0.5, 1] as [CGFloat] {
            let anchor = Self.anchor(geometry, at: share)
            for centre in Self.centres(20) {
                let rows = geometry.rows(centre: centre, anchor: anchor)
                guard rows.tops.count == 20, rows.heights.count == 20 else {
                    misses.append("centre \(centre): \(rows.tops.count) tops, \(rows.heights.count) heights")
                    continue
                }
                let row = PromptRailLensMath.row(containing: centre, count: 20)
                let bandTop = rows.tops[row]
                let bandBottom = bandTop + rows.heights[row]
                if !(bandBottom >= Self.top && bandTop <= end) {
                    misses.append("opened at \(share), centre \(centre): row \(row) at \(bandTop)…\(bandBottom)")
                }
                let first = rows.tops[0]
                let bottom = rows.tops[19] + rows.heights[19]
                if !(first <= Self.top + 1 && bottom >= end - 1) {
                    misses.append("opened at \(share), centre \(centre): the rows span \(first)…\(bottom)")
                }
            }
        }
        #expect(misses.isEmpty, "rows off the \(Self.top)…\(end) column: \(misses.prefix(5))")
    }

    /// A short rail that squeezes rather than slides holds both ends, even
    /// where half a bump near an end would draw a peak the slivers cannot pay
    /// for at full height.
    @Test(arguments: [(11, 60), (12, 74), (17, 100)] as [(Int, CGFloat)])
    func shortRailEndsHold(count: Int, railHeight: CGFloat) {
        let geometry = PromptRailLensGeometry(
            layout: PromptRailLayout(count: count, railHeight: railHeight), restOffset: 0)
        #expect(!geometry.slidesPastFloor && !geometry.keepsRestingRows)
        let end = Self.top + geometry.columnHeight
        var misses: [String] = []
        for share in [0, 0.5, 1] as [CGFloat] {
            let anchor = Self.anchor(geometry, at: share)
            for centre in Self.centres(count) {
                let rows = geometry.rows(centre: centre, anchor: anchor)
                let first = rows.tops.first ?? .nan
                let bottom = (rows.tops.last ?? .nan) + (rows.heights.last ?? .nan)
                if !(abs(first - Self.top) <= 0.5 && abs(bottom - end) <= 0.5) {
                    misses.append("opened at \(share), centre \(centre): \(first)…\(bottom)")
                }
            }
        }
        #expect(misses.isEmpty, "\(count) prompts in \(railHeight)pt: the column is \(Self.top)…\(end), but \(misses.prefix(5))")
    }

    /// Past the floor, 600 prompts in 577pt, the column slides: the centre
    /// row stays on the rail, it moves down the rail as the centre does, and
    /// no row grows past the peak.
    @Test func pastFloorSlides() {
        let geometry = Self.geometry(600)
        #expect(geometry.restOverflows && geometry.slidesPastFloor)
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
            let total = rows.heights.reduce(0, +)
            if !(total > geometry.columnHeight + 0.5) {
                misses.append("centre \(centre): the rows fill \(total)pt of a \(geometry.columnHeight)pt column")
            }
            let tallest = rows.heights.max() ?? .nan
            if !(tallest <= 26.5) { misses.append("centre \(centre): a row is \(tallest)pt") }
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

    /// Whether a rail slides is decided once for the rail (spec step 6). 450
    /// prompts overfill 577pt with a whole bump but not with the half bump at
    /// an end, so deciding per centre would make the column jump up to about
    /// 40pt there. From one sampled centre to the next, neither the column's
    /// top nor the centre's height moves more than 3pt, the centre never
    /// moves up, no row passes the peak, and the column covers the rail to
    /// within 0.1pt. The centres are 0.05 rows apart within 12 rows of
    /// either end, where the bump is cut off, and 0.25 rows apart between.
    @Test(arguments: [true, false])
    func slideIsContinuous(openedAtTop: Bool) {
        let geometry = Self.geometry(450)
        #expect(geometry.slidesPastFloor && !Self.geometry(300).slidesPastFloor)
        let end = Self.top + geometry.columnHeight
        let anchor = geometry.anchor(pointerY: openedAtTop ? Self.restingCentre(of: 0, in: geometry) : end)
        let nearTop = (0...240).map { CGFloat($0) / 20 }
        let between = (49...1751).map { CGFloat($0) / 4 }
        let nearEnd = (8760...9000).map { CGFloat($0) / 20 }
        let centres = nearTop + between + nearEnd
        var previousTop = CGFloat.nan
        var previousY = CGFloat.nan
        var misses: [String] = []
        for (step, centre) in centres.enumerated() {
            let rows = geometry.rows(centre: centre, anchor: anchor)
            let first = rows.tops.first ?? .nan
            let bottom = (rows.tops.last ?? .nan) + (rows.heights.last ?? .nan)
            let y = rows.y(ofFraction: centre)
            if step > 0 {
                if !(abs(first - previousTop) <= 3) {
                    misses.append("centre \(centre): the top moved \(first - previousTop)pt")
                }
                if !(y - previousY >= -1e-9 && y - previousY <= 3) {
                    misses.append("centre \(centre): the centre moved \(y - previousY)pt")
                }
            }
            let tallest = rows.heights.max() ?? .nan
            if !(tallest <= 26.5) { misses.append("centre \(centre): a row is \(tallest)pt") }
            if !(first <= Self.top + 0.1 && bottom >= end - 0.1) {
                misses.append("centre \(centre): the column \(first)…\(bottom) leaves the rail uncovered")
            }
            previousTop = first
            previousY = y
        }
        #expect(misses.isEmpty, "opened at the \(openedAtTop ? "top" : "end"): \(misses.prefix(5))")
    }

    @Test func blendRoundTrips() throws {
        let geometry = Self.geometry(40)
        let resting = PromptRailLensRows.resting(geometry)
        let lens = geometry.rows(centre: 17.3, anchor: Self.anchor(geometry))
        try #require(resting.tops.count == 40 && lens.tops.count == 40)

        let closed = resting.blended(toward: lens, fraction: 0)
        #expect(Self.isClose(closed.tops, resting.tops) && Self.isClose(closed.heights, resting.heights))

        let open = resting.blended(toward: lens, fraction: 1)
        #expect(Self.isClose(open.tops, lens.tops) && Self.isClose(open.heights, lens.heights))

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
        #expect(windowed.restOverflows)
        #expect(!Self.geometry(40).restOverflows)
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
