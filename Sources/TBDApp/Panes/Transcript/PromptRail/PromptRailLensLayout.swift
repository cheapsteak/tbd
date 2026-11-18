import CoreGraphics
import Foundation

/// Where the lens opened: the fractional row the pointer was over and that
/// row's resting y. `PromptRailLensGeometry.rows(centre:anchor:)` maps a lens
/// centre to a height on the rail through it, so the notch the lens opened on
/// stays under the pointer and, on a windowed rail, every row stays reachable.
/// Rail coordinates, flipped.
struct PromptRailLensAnchor: Equatable, Sendable {
    /// The fractional row under the pointer when the lens opened, in
    /// `0...count`.
    let row: CGFloat
    /// That row's resting y, clamped to the column.
    let y: CGFloat
    /// The resting column's bottom end.
    let columnEnd: CGFloat
}

/// One height and top per prompt, in rail coordinates (flipped). The resting
/// rail and the open lens are each one of these, and the view draws a blend of
/// the two while the lens opens and closes.
struct PromptRailLensRows: Equatable, Sendable {
    let heights: [CGFloat]
    let tops: [CGFloat]
    /// The rows are taller than the column they fill: a windowed resting rail,
    /// or a lens past the sliver floor, whose column slides. Their ends can
    /// lie outside the rail, behind its fades.
    let overflows: Bool

    static let empty = PromptRailLensRows(heights: [], tops: [], overflows: false)

    /// The resting rail: every row one resting pitch tall, from the top inset,
    /// moved up by the rail's overflow offset.
    static func resting(_ geometry: PromptRailLensGeometry) -> PromptRailLensRows {
        let count = max(0, geometry.count)
        let pitch = geometry.restPitch
        let tops = (0..<count).map { index in
            PromptRailLayout.topInset + CGFloat(index) * pitch - geometry.restOffset
        }
        return PromptRailLensRows(
            heights: Array(repeating: pitch, count: count),
            tops: tops,
            overflows: CGFloat(count) * pitch > geometry.columnHeight + PromptRailLensGeometry.overflowSlack)
    }

    /// Each top and height moved `fraction` of the way from these rows to
    /// `lens`'s: 0 (or less) gives these rows and 1 (or more) gives `lens`.
    /// Rows of a different count do not blend, and give these rows.
    func blended(toward lens: PromptRailLensRows, fraction: CGFloat) -> PromptRailLensRows {
        guard fraction > 0, lens.tops.count == tops.count else { return self }
        guard fraction < 1 else { return lens }
        return PromptRailLensRows(
            heights: zip(heights, lens.heights).map { rest, target in rest + (target - rest) * fraction },
            tops: zip(tops, lens.tops).map { rest, target in rest + (target - rest) * fraction },
            overflows: overflows || lens.overflows)
    }

    /// The row whose band holds `y`, clamped to the first and last rows; nil
    /// only when there are no rows.
    func index(atY y: CGFloat) -> Int? {
        guard let first = tops.first else { return nil }
        return y < first ? 0 : lastRow(atOrAbove: y)
    }

    /// The fractional row under `y`: the row's index plus how far down its
    /// band `y` lies. 0 above the first row and `count` below the last.
    func fraction(atY y: CGFloat) -> CGFloat {
        guard let first = tops.first, let lastTop = tops.last, let lastHeight = heights.last else { return 0 }
        if y <= first { return 0 }
        if y >= lastTop + lastHeight { return CGFloat(tops.count) }
        let row = lastRow(atOrAbove: y)
        let height = heights[row]
        return CGFloat(row) + (height > 0 ? (y - tops[row]) / height : 0)
    }

    /// The y of fractional row `c`, the inverse of `fraction(atY:)`. 0 when
    /// there are no rows.
    func y(ofFraction c: CGFloat) -> CGFloat {
        guard !tops.isEmpty else { return 0 }
        let row = PromptRailLensMath.row(containing: c, count: tops.count)
        return tops[row] + (c - CGFloat(row)) * heights[row]
    }

    /// The last row whose top is at or above `y`, or row 0 when none is.
    /// Requires at least one row.
    private func lastRow(atOrAbove y: CGFloat) -> Int {
        var low = 0
        var high = tops.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if tops[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// The open lens's layout on one rail (lens spec, "The lens" → "Layout"): the
/// column it fills, and each row's height and top for a lens centred on a
/// fractional row. The open lens fills exactly the resting column, so neither
/// end moves; far rows squeeze to pay for the rows that grow.
///
/// A port of the approved HTML mock's `computeLens` and its helpers, with two
/// rules from the spec that the mock does not follow:
/// - **The column slides only past the floor.** A windowed rail squeezes every
///   prompt into the column while 1pt slivers fit (spec step 5), and slides
///   only when they do not (step 6). Sliding whenever the resting rail
///   overflows, as the mock does, moves a 300-prompt column's bottom end by
///   up to 127pt and stretches its end rows past 100pt.
/// - **No row is taller than the peak.** Past the floor, the side of the
///   centre that fits fills the room the slide leaves it with rows no taller
///   than the peak, rather than stretching its last rows to fill all of it.
struct PromptRailLensGeometry: Equatable, Sendable {
    /// No row of the open lens is thinner than this.
    static let sliverFloor: CGFloat = 1
    /// A sliding column moves at least this far per row of lens centre, so
    /// the lens cannot race through rows with no pointer movement.
    static let slideMinPerRow: CGFloat = 0.25
    /// Rows taller than their column by more than this overflow it.
    fileprivate static let overflowSlack: CGFloat = 0.5

    let count: Int
    let railHeight: CGFloat
    let restPitch: CGFloat
    /// The rail's overflow offset when the lens opened.
    let restOffset: CGFloat

    init(layout: PromptRailLayout, restOffset: CGFloat) {
        count = layout.count
        railHeight = layout.railHeight
        restPitch = layout.pitch
        self.restOffset = restOffset
    }

    /// The rail's height less its top and bottom insets.
    var freeHeight: CGFloat {
        max(0, railHeight - PromptRailLayout.topInset - PromptRailLayout.bottomInset)
    }

    /// The column the open lens fills: the resting column, or the free height
    /// on a windowed rail.
    var columnHeight: CGFloat {
        min(freeHeight, CGFloat(max(0, count)) * restPitch)
    }

    /// The resting rail is windowed: its notches do not all fit.
    var restOverflows: Bool {
        CGFloat(count) * restPitch > freeHeight + 0.01
    }

    /// Few prompts (spec step 0): the column gives every row the peak height
    /// or more, so the open lens keeps the resting rows.
    var keepsRestingRows: Bool {
        count > 0 && columnHeight / CGFloat(count) >= PromptRailLayout.lensPeak
    }

    /// The anchor for a lens opened with the pointer at `pointerY`, in rail
    /// coordinates.
    func anchor(pointerY: CGFloat) -> PromptRailLensAnchor {
        let top = PromptRailLayout.topInset
        let end = top + columnHeight
        guard count > 0, restPitch > 0, !pointerY.isNaN else {
            return PromptRailLensAnchor(row: 0, y: top, columnEnd: end)
        }
        let row = PromptRailLensMath.clamp((pointerY - top + restOffset) / restPitch, 0, CGFloat(count))
        let y = PromptRailLensMath.clamp(top + row * restPitch - restOffset, top, end)
        return PromptRailLensAnchor(row: row, y: y, columnEnd: end)
    }

    /// The open lens centred on fractional row `centre`: a cosine bump of
    /// `lensRadius` rows each side, peaking at `lensPeak`, over far rows
    /// squeezed so the column keeps its height (spec steps 1 to 6).
    func rows(centre: CGFloat, anchor: PromptRailLensAnchor) -> PromptRailLensRows {
        guard count > 0 else { return .empty }
        if keepsRestingRows { return .resting(self) }
        let rowCount = CGFloat(count)
        let c = centre.isNaN ? 0 : min(max(centre, 0), rowCount)
        let column = columnHeight
        let sliver = Self.sliverFloor
        let top = PromptRailLayout.topInset

        // Step 1: the bump, and the peak, lowered when it would leave the
        // other rows less than 15% of the column.
        var weights = [CGFloat](repeating: 0, count: count)
        var bump: CGFloat = 0
        for index in bumpRows(around: c) {
            let weight = Self.bumpWeight(row: index, centre: c)
            weights[index] = weight
            bump += weight
        }
        let peak = max(Self.peak(column: column, bump: bump), sliver)

        // Step 2: row i is `base + (peak − base) × f`, with `upper` as the base
        // for rows whose centre lies above c and `lower` for the rest. The
        // height above c is `ka × upper + kab × lower + peak × fa`, and the
        // whole column `ta × upper + tb × lower + peak × bump`.
        let centreRow = PromptRailLensMath.row(containing: c, count: count)
        let within = PromptRailLensMath.clamp(c - CGFloat(centreRow), 0, 1)
        var ka: CGFloat = 0, kab: CGFloat = 0, fa: CGFloat = 0, ta: CGFloat = 0, tb: CGFloat = 0
        for index in 0..<count {
            let rest = 1 - weights[index]
            let above = CGFloat(index) + 0.5 < c
            if above { ta += rest } else { tb += rest }
            if index < centreRow {
                ka += rest
                fa += weights[index]
            } else if index == centreRow {
                if above { ka += rest * within } else { kab += rest * within }
                fa += weights[index] * within
            }
        }
        let fb = bump - fa
        let restAbove = ka + kab
        let restBelow = ta + tb - restAbove
        let minAbove = sliver * restAbove + peak * fa
        let minBelow = sliver * restBelow + peak * fb

        // Where the centre sits (steps 3 to 6).
        let centreY: CGFloat
        let slides: Bool
        if minAbove + minBelow > column + 1e-6 {
            // Past the floor: even slivers overfill the column, so it slides
            // (step 6). A windowed rail maps the centre through `slideY`.
            centreY = restOverflows ? slideY(c, anchor) : anchorY(c, anchor)
            slides = true
        } else {
            // Near an end, hold the centre inward so the rows on the cramped
            // side keep at least half the squeeze they get mid-rail.
            let middleBump = bumpSum(around: rowCount / 2)
            let middlePeak = Self.peak(column: column, bump: middleBump)
            let soft = rowCount - middleBump > 1e-6
                ? max(sliver, 0.5 * (column - middlePeak * middleBump) / (rowCount - middleBump))
                : sliver
            var low = top + soft * restAbove + peak * fa
            var high = top + column - (soft * restBelow + peak * fb)
            if low > high {
                low = top + minAbove
                high = top + column - minBelow
            }
            centreY = PromptRailLensMath.clamp(anchorY(c, anchor), low, high)
            slides = false
        }

        // The two-sided squeeze (step 3): the rows above the centre fill the
        // room above it, and the whole column fills `column`.
        let roomAbove = centreY - top
        let roomBelow = top + column - centreY
        let fitsAbove = roomAbove >= minAbove - 1e-9
        let fitsBelow = roomBelow >= minBelow - 1e-9
        var upper = sliver
        var lower = sliver
        if fitsAbove && fitsBelow {
            let restRoomAbove = roomAbove - peak * fa
            let restRoom = column - peak * bump
            let determinant = ka * tb - kab * ta
            if ka > 1e-6 && tb - kab > 1e-6 && determinant > 1e-9 {
                upper = (restRoomAbove * tb - kab * restRoom) / determinant
                lower = (ka * restRoom - ta * restRoomAbove) / determinant
            } else {
                let even = ta + tb > 1e-6 ? restRoom / (ta + tb) : sliver
                upper = even
                lower = even
            }
            if upper < sliver {
                upper = sliver
                lower = tb > 1e-6 ? (restRoom - ta * sliver) / tb : sliver
            }
            if lower < sliver {
                lower = sliver
                upper = ta > 1e-6 ? (restRoom - tb * sliver) / ta : sliver
            }
        } else if fitsBelow {
            let restBelowCentre = tb - kab
            lower = restBelowCentre > 1e-6
                ? min(peak, max(sliver, (roomBelow - peak * fb - (ta - ka) * sliver) / restBelowCentre))
                : sliver
        } else if fitsAbove {
            upper = ka > 1e-6
                ? min(peak, max(sliver, (roomAbove - peak * fa - kab * sliver) / ka))
                : sliver
        }

        var heights = [CGFloat](repeating: 0, count: count)
        var offsets = [CGFloat](repeating: 0, count: count)
        var total: CGFloat = 0
        for index in 0..<count {
            let base = CGFloat(index) + 0.5 < c ? upper : lower
            heights[index] = base + (peak - base) * weights[index]
            offsets[index] = total
            total += heights[index]
        }
        var firstTop = top
        if slides {
            let aboveCentre = offsets[centreRow] + (c - CGFloat(centreRow)) * heights[centreRow]
            firstTop = PromptRailLensMath.clamp(centreY - aboveCentre, top + column - total, top)
        }
        return PromptRailLensRows(
            heights: heights,
            tops: offsets.map { firstTop + $0 },
            overflows: total > column + Self.overflowSlack)
    }

    /// The centre a lens opens on: the one whose own layout puts the pointer's
    /// height on its centre, found by a 30-step bisection over `0...count`.
    func openingCentre(pointerY: CGFloat, anchor: PromptRailLensAnchor) -> CGFloat {
        var low: CGFloat = 0
        var high = CGFloat(max(0, count))
        for _ in 0..<30 {
            let middle = (low + high) / 2
            if rows(centre: middle, anchor: anchor).y(ofFraction: middle) < pointerY {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }

    // MARK: The bump

    /// Row `row`'s weight in a bump centred on `centre`:
    /// `½ × (1 + cos(π × d / R))` for `|d| < R`, where `d = row + ½ − centre`.
    private static func bumpWeight(row: Int, centre: CGFloat) -> CGFloat {
        let radius = PromptRailLayout.lensRadius
        let distance = CGFloat(row) + 0.5 - centre
        guard abs(distance) < radius else { return 0 }
        return 0.5 * (1 + cos(.pi * distance / radius))
    }

    /// The rows a bump centred on `c` can weigh; `c` lies in `0...count`.
    private func bumpRows(around c: CGFloat) -> StrideThrough<Int> {
        let radius = PromptRailLayout.lensRadius
        let first = PromptRailLensMath.row(containing: (c - radius).rounded(.down), count: count)
        let last = PromptRailLensMath.row(containing: (c + radius).rounded(.up), count: count)
        return stride(from: first, through: last, by: 1)
    }

    private func bumpSum(around c: CGFloat) -> CGFloat {
        bumpRows(around: c).reduce(0) { $0 + Self.bumpWeight(row: $1, centre: c) }
    }

    /// The peak for a bump of total weight `bump`: `lensPeak`, lowered to
    /// `0.85 × column / bump` when it would leave the other rows less than
    /// 15% of the column.
    private static func peak(column: CGFloat, bump: CGFloat) -> CGFloat {
        let full = PromptRailLayout.lensPeak
        if bump > 1e-6 && column - full * bump < 0.15 * column { return 0.85 * column / bump }
        return full
    }

    // MARK: Where the centre sits

    /// The resting rail's own mapping from a fractional row to a height, bent
    /// at the anchor so the opened-on notch stays under the pointer and every
    /// row of a windowed rail maps inside the column.
    private func anchorY(_ c: CGFloat, _ anchor: PromptRailLensAnchor) -> CGFloat {
        let top = PromptRailLayout.topInset
        if c <= anchor.row {
            return anchor.row > 1e-6 ? top + (anchor.y - top) * c / anchor.row : anchor.y
        }
        let rowCount = CGFloat(count)
        return rowCount - anchor.row > 1e-6
            ? anchor.y + (anchor.columnEnd - anchor.y) * (c - anchor.row) / (rowCount - anchor.row)
            : anchor.y
    }

    /// For a sliding column, the highest (`top`) or lowest place the centre
    /// may sit with half its bump and up to `lensRadius` slivers beside it
    /// still inside the rail.
    private func slideBound(_ c: CGFloat, top: Bool) -> CGFloat {
        let radius = PromptRailLayout.lensRadius
        let centreRow = PromptRailLensMath.row(containing: c, count: count)
        let within = PromptRailLensMath.clamp(c - CGFloat(centreRow), 0, 1)
        var bump: CGFloat = 0
        var fa: CGFloat = 0
        for index in bumpRows(around: c) {
            let weight = Self.bumpWeight(row: index, centre: c)
            bump += weight
            if index < centreRow { fa += weight } else if index == centreRow { fa += weight * within }
        }
        let column = columnHeight
        let peak = Self.peak(column: column, bump: bump)
        let inset = PromptRailLayout.topInset
        if top { return inset + peak * fa + Self.sliverFloor * min(c, radius) }
        return inset + column - peak * (bump - fa) - Self.sliverFloor * min(CGFloat(count) - c, radius)
    }

    /// Where the centre of a sliding column sits (spec step 6): two straight
    /// runs, from the rail's top to the notch the lens opened on and from
    /// there to the bottom, held inside `slideBound` so the end rows come
    /// fully into view, and never flatter than `slideMinPerRow`.
    private func slideY(_ c: CGFloat, _ anchor: PromptRailLensAnchor) -> CGFloat {
        let rowCount = CGFloat(count)
        let radius = PromptRailLayout.lensRadius
        let slope = Self.slideMinPerRow
        let opened = PromptRailLensMath.clamp(anchor.row, 0, rowCount)
        let headRows = min(radius, opened)
        let tailRows = min(radius, rowCount - opened)
        let headY = slideBound(headRows, top: true)
        let tailY = slideBound(rowCount - tailRows, top: false)
        let low = max(slideBound(opened, top: true), headY + slope * (opened - headRows))
        let high = min(slideBound(opened, top: false), tailY - slope * (rowCount - tailRows - opened))
        let openedY = low <= high ? PromptRailLensMath.clamp(anchor.y, low, high) : (low + high) / 2
        if c <= opened {
            let run: CGFloat
            if opened - headRows > 1e-9 {
                run = headY + (openedY - headY) * (c - headRows) / (opened - headRows)
            } else if opened > 1e-9 {
                run = PromptRailLayout.topInset + (openedY - PromptRailLayout.topInset) * c / opened
            } else {
                run = openedY
            }
            return max(slideBound(c, top: true), run)
        }
        let run: CGFloat
        if rowCount - tailRows - opened > 1e-9 {
            run = openedY + (tailY - openedY) * (c - opened) / (rowCount - tailRows - opened)
        } else if rowCount - opened > 1e-9 {
            run = openedY + (anchor.columnEnd - openedY) * (c - opened) / (rowCount - opened)
        } else {
            run = openedY
        }
        return min(slideBound(c, top: false), run)
    }
}

/// Small helpers the lens layout and its rows share.
enum PromptRailLensMath {
    /// `value` held to `low...high`, the mock's `clamp`: below `low` gives
    /// `low`, otherwise above `high` gives `high`. When `low > high` it
    /// returns one of the two bounds, never `value`.
    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        value < low ? low : (value > high ? high : value)
    }

    /// The row fractional position `c` falls in, held to `0..<count`; 0 for
    /// NaN. Requires `count > 0`.
    static func row(containing c: CGFloat, count: Int) -> Int {
        guard c > 0 else { return 0 }
        guard c < CGFloat(count - 1) else { return count - 1 }
        return Int(c.rounded(.down))
    }
}
