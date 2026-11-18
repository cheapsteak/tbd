import CoreGraphics
import Foundation

/// Where the lens is anchored: a fractional row and the height on the rail
/// it is pinned to. `PromptRailLensGeometry.rows(centre:anchor:)` maps a lens
/// centre to a height on the rail through it, so the anchored row stays where
/// it is and, on a windowed rail, every row stays reachable. A lens anchors as
/// it opens, on the row under the pointer at that row's resting y, and again
/// when it moves onto a new column, on its centre at the height it was drawn,
/// so the centre stays under the pointer. Rail coordinates, flipped.
struct PromptRailLensAnchor: Equatable, Sendable {
    /// The anchored fractional row, in `0...count`.
    let row: CGFloat
    /// The height the row is pinned to, inside the column.
    let y: CGFloat
    /// The resting column's bottom end.
    let columnEnd: CGFloat
}

/// One height and top per prompt, in rail coordinates (flipped). The resting
/// rail and the open lens are each one of these, and the view draws a blend of
/// the two while the lens opens and closes. On a windowed resting rail, or a
/// lens past the sliver floor, whose column slides, the rows are taller than
/// the column, and their ends lie outside the rail, behind its fades.
struct PromptRailLensRows: Equatable, Sendable {
    let heights: [CGFloat]
    let tops: [CGFloat]

    static let empty = PromptRailLensRows(heights: [], tops: [])

    /// The resting rail: every row one resting pitch tall, from the top inset,
    /// moved up by the rail's overflow offset.
    static func resting(_ geometry: PromptRailLensGeometry) -> PromptRailLensRows {
        let count = max(0, geometry.count)
        let pitch = geometry.restPitch
        let tops = (0..<count).map { index in
            PromptRailLayout.topInset + CGFloat(index) * pitch - geometry.restOffset
        }
        return PromptRailLensRows(heights: Array(repeating: pitch, count: count), tops: tops)
    }

    /// Each top and height moved `fraction` of the way from these rows to
    /// `lens`'s: 0 (or less) gives these rows and 1 (or more) gives `lens`.
    /// Rows of a different count do not blend, and give these rows.
    func blended(toward lens: PromptRailLensRows, fraction: CGFloat) -> PromptRailLensRows {
        guard fraction > 0, lens.tops.count == tops.count else { return self }
        guard fraction < 1 else { return lens }
        return PromptRailLensRows(
            heights: zip(heights, lens.heights).map { rest, target in rest + (target - rest) * fraction },
            tops: zip(tops, lens.tops).map { rest, target in rest + (target - rest) * fraction })
    }

    /// The row whose band holds `y`, clamped to the first and last rows; nil
    /// only when there are no rows.
    func index(atY y: CGFloat) -> Int? {
        guard let first = tops.first else { return nil }
        return y < first ? 0 : lastRow(atOrAbove: y)
    }

    /// The column the rows fill: the first row's top and the last row's
    /// bottom. nil with no rows.
    var columnSpan: (top: CGFloat, bottom: CGFloat)? {
        guard let top = tops.first, let lastTop = tops.last, let lastHeight = heights.last else { return nil }
        return (top, lastTop + lastHeight)
    }

    /// Row `index`'s text band, in rail coordinates, as a zero-width rect at
    /// x 0: the row itself, or, for a row taller than the lens's peak (a
    /// few-prompts rail), a band the peak's height centred on it (lens spec,
    /// "Drawing"). The row's text, its hover fill and its share of the box
    /// lie in it.
    func textBand(row index: Int) -> CGRect {
        let height = heights[index]
        let bandHeight = min(height, PromptRailLayout.lensPeak)
        return CGRect(x: 0, y: tops[index] + (height - bandHeight) / 2, width: 0, height: bandHeight)
    }

    /// The row `y` points at: the row whose band holds it, except that a row
    /// taller than the lens's peak is pointed at only within its text band.
    /// Outside the column, and between a few-prompts rail's bands, `y`
    /// points at no row.
    func pointedRow(atY y: CGFloat) -> Int? {
        guard let column = columnSpan, y >= column.top, y < column.bottom else { return nil }
        let row = lastRow(atOrAbove: y)
        guard heights[row] > PromptRailLayout.lensPeak else { return row }
        let band = textBand(row: row)
        return y >= band.minY && y < band.maxY ? row : nil
    }

    /// The fractional row under `y`: the row's index plus how far down its
    /// band `y` lies. 0 above the first row and `count` below the last.
    func fraction(atY y: CGFloat) -> CGFloat {
        guard let column = columnSpan else { return 0 }
        if y <= column.top { return 0 }
        if y >= column.bottom { return CGFloat(tops.count) }
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
/// A port of the approved HTML mock's `computeLens` and its helpers, with
/// rules from the spec that the mock does not follow:
/// - **The column slides only past the floor, decided once per rail.** A
///   windowed rail squeezes every prompt into the column while 1pt slivers
///   fit (spec step 5), and slides only when they do not (step 6). Sliding
///   whenever the resting rail overflows, as the mock does, moves a
///   300-prompt column's bottom end by up to 127pt and stretches its end rows
///   past 100pt. Deciding it for each centre instead makes the column jump by
///   up to about 70pt on a 601pt rail of 430 to 490 prompts, where a whole
///   bump overfills the column and the half bump at an end does not.
/// - **No row is taller than the peak.** A sliding column solves each side of
///   the centre for the room the slide leaves it, with rows no taller than
///   the peak, rather than stretching its last rows to fill all of it. Within
///   `lensRadius` rows of either end it sits where the end rows meet the
///   rail's end, so no gap opens there. A rail short of the floor mid-rail
///   lowers the peak near an end until slivers fit, so its ends still hold.
struct PromptRailLensGeometry: Equatable, Sendable {
    /// No row of the open lens is thinner than this.
    static let sliverFloor: CGFloat = 1
    /// A sliding column moves at least this far per row of lens centre, so
    /// the lens cannot race through rows with no pointer movement.
    static let slideMinPerRow: CGFloat = 0.25

    let count: Int
    let railHeight: CGFloat
    let restPitch: CGFloat
    /// The anchor offset: the rail's overflow offset the lens was last
    /// anchored at, as it opened or as it last moved onto a new column. The
    /// rail's own offset moves on under an open lens with the active prompt,
    /// and that alone does not re-anchor it.
    let restOffset: CGFloat

    // Derived from the four above once, in `init`, since every
    // `rows(centre:anchor:)` reads them. Equality stays sound: equal inputs
    // derive equal values.

    /// The column the open lens fills: the resting column, or the free height
    /// on a windowed rail.
    let columnHeight: CGFloat
    /// The resting rail is windowed: its notches do not all fit, past
    /// `PromptRailLayout.overflowTolerance`, as `PromptRailLayout.overflows`
    /// decides.
    let restOverflows: Bool
    /// Few prompts (spec step 0): the resting pitch is already at least the
    /// peak a bump in mid-column would draw, so the open lens keeps the
    /// resting rows. A short rail lowers that peak, so it covers more rails.
    /// A windowed rail never keeps them, however short: its lens squeezes
    /// every prompt into the column (step 5), so the pointer can reach each.
    let keepsRestingRows: Bool
    /// Past the floor (spec step 6): even 1pt slivers around a whole bump in
    /// mid-column overfill the column, so the open column slides. Decided
    /// once for the rail, never per lens position, so the column cannot
    /// switch between squeezing and sliding as the lens nears an end.
    let slidesPastFloor: Bool
    /// The total weight of a bump in mid-column.
    private let middleBump: CGFloat
    /// The peak a bump in mid-column draws (spec step 1), at least a sliver.
    private let middlePeak: CGFloat

    init(layout: PromptRailLayout, restOffset: CGFloat) {
        // Locals throughout: `&&` takes its right side as a closure, which
        // may not capture `self` before every stored property is set.
        let count = layout.count
        let pitch = layout.pitch
        let rows = CGFloat(max(0, count))
        let sliver = Self.sliverFloor
        let column = min(layout.freeHeight, rows * pitch)
        let overflows = layout.overflows
        let bump = Self.bumpSum(around: rows / 2, count: count)
        let peak = max(Self.peak(column: column, bump: bump), sliver)

        self.count = count
        railHeight = layout.railHeight
        restPitch = pitch
        self.restOffset = restOffset
        columnHeight = column
        restOverflows = overflows
        middleBump = bump
        middlePeak = peak
        keepsRestingRows = count > 0 && !overflows && pitch >= peak
        slidesPastFloor = count > 0 && CGFloat(count) * sliver + (peak - sliver) * bump > column + 1e-6
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

    /// The anchor that pins fractional row `row` at height `y`, both held to
    /// the column: a lens moving onto a new column anchors on its centre at
    /// the height it was drawn, so the centre does not jump.
    func anchor(row: CGFloat, atY y: CGFloat) -> PromptRailLensAnchor {
        let top = PromptRailLayout.topInset
        let end = top + columnHeight
        let heldRow = row.isNaN ? 0 : PromptRailLensMath.clamp(row, 0, CGFloat(max(0, count)))
        let heldY = y.isNaN ? top : PromptRailLensMath.clamp(y, top, end)
        return PromptRailLensAnchor(row: heldRow, y: heldY, columnEnd: end)
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
        let slides = slidesPastFloor

        // Step 1: the bump, and the peak, lowered when it would leave the
        // other rows less than 15% of the column.
        var weights = [CGFloat](repeating: 0, count: count)
        var bump: CGFloat = 0
        for index in bumpRows(around: c) {
            let weight = Self.bumpWeight(row: index, centre: c)
            weights[index] = weight
            bump += weight
        }
        var peak = max(Self.peak(column: column, bump: bump), sliver)
        // A rail short of the floor mid-rail can still overfill near an end,
        // where half a bump draws a higher peak. Lower that peak until
        // slivers fit, so the column's ends hold.
        if !slides && bump > 1e-6 && sliver * (rowCount - bump) + peak * bump > column {
            peak = max(sliver, (column - sliver * (rowCount - bump)) / bump)
        }

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
        if slides {
            // Past the floor, the column slides (step 6). A windowed rail maps
            // the centre through `slideY`.
            centreY = restOverflows ? slideY(c, anchor) : anchorY(c, anchor)
        } else {
            // Near an end, hold the centre inward so the rows on the cramped
            // side keep at least half the squeeze they get mid-rail.
            let middleBump = self.middleBump
            let middleFill = Self.peak(column: column, bump: middleBump) * middleBump
            let soft = rowCount - middleBump > 1e-6
                ? max(sliver, 0.5 * (column - middleFill) / (rowCount - middleBump))
                : sliver
            var low = top + soft * restAbove + peak * fa
            var high = top + column - (soft * restBelow + peak * fb)
            if low > high {
                low = top + minAbove
                high = top + column - minBelow
            }
            centreY = PromptRailLensMath.clamp(anchorY(c, anchor), low, high)
        }

        let roomAbove = centreY - top
        let roomBelow = top + column - centreY
        let fitsAbove = roomAbove >= minAbove - 1e-9
        let fitsBelow = roomBelow >= minBelow - 1e-9
        // One side's base, from a sliver to the peak, that fills the room on
        // its side of the centre given the other side's base, by step 2's
        // sums: below the centre lie `(ta − ka) × upper + (tb − kab) × lower`.
        let restBelowCentre = tb - kab
        func solveUpper(lower: CGFloat) -> CGFloat {
            ka > 1e-6 ? min(peak, max(sliver, (roomAbove - peak * fa - kab * lower) / ka)) : sliver
        }
        func solveLower(upper: CGFloat) -> CGFloat {
            restBelowCentre > 1e-6
                ? min(peak, max(sliver, (roomBelow - peak * fb - (ta - ka) * upper) / restBelowCentre))
                : sliver
        }
        var upper = sliver
        var lower = sliver
        if slides {
            // A sliding column: each side of the centre fills the room the
            // slide leaves it. Only one of `kab` and `ta − ka` is nonzero, so
            // solving the side that does not depend on the other first is
            // exact.
            if CGFloat(centreRow) + 0.5 < c {
                upper = solveUpper(lower: sliver)
                lower = solveLower(upper: upper)
            } else {
                lower = solveLower(upper: sliver)
                upper = solveUpper(lower: lower)
            }
        } else if fitsAbove && fitsBelow {
            // The two-sided squeeze (step 3): the rows above the centre fill
            // the room above it, and the whole column fills `column`.
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
            lower = solveLower(upper: sliver)
        } else if fitsAbove {
            upper = solveUpper(lower: sliver)
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
            // Keep the centre where the slide put it, moved only as far as
            // keeps the column covering the rail, or inside it when shorter.
            let aboveCentre = offsets[centreRow] + (c - CGFloat(centreRow)) * heights[centreRow]
            let spill = top + column - total
            firstTop = PromptRailLensMath.clamp(centreY - aboveCentre, min(spill, top), max(spill, top))
        }
        return PromptRailLensRows(heights: heights, tops: offsets.map { firstTop + $0 })
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
        Self.bumpRows(around: c, count: count)
    }

    /// The rows a bump centred on `c` can weigh, of `count`; none when
    /// `count` is 0.
    private static func bumpRows(around c: CGFloat, count: Int) -> StrideThrough<Int> {
        guard count > 0 else { return stride(from: 0, through: -1, by: 1) }
        let radius = PromptRailLayout.lensRadius
        let first = PromptRailLensMath.row(containing: (c - radius).rounded(.down), count: count)
        let last = PromptRailLensMath.row(containing: (c + radius).rounded(.up), count: count)
        return stride(from: first, through: last, by: 1)
    }

    /// The total weight of a bump centred on `c`, over `count` rows.
    private static func bumpSum(around c: CGFloat, count: Int) -> CGFloat {
        bumpRows(around: c, count: count).reduce(0) { $0 + bumpWeight(row: $1, centre: c) }
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
    /// may sit with half its bump and the rows up to `lensRadius` beside it,
    /// at their least, still inside the rail. A row of bump weight `f` is at
    /// least `sliver + (peak − sliver) × f` tall, so the rows within
    /// `lensRadius` above the centre take at least `peak × fa + sliver ×
    /// (min(c, R) − fa)`, and those below it the same with `fb` and
    /// `min(count − c, R)`. Exact, so the end rows meet the rail's end.
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
        let sliver = Self.sliverFloor
        if top { return inset + peak * fa + sliver * (min(c, radius) - fa) }
        let fb = bump - fa
        return inset + column - peak * fb - sliver * (min(CGFloat(count) - c, radius) - fb)
    }

    /// Where the centre of a sliding column sits (spec step 6): two straight
    /// runs, from the rail's top to the notch the lens opened on and from
    /// there to the bottom, held inside `slideBound` so the end rows come
    /// fully into view, and never flatter than `slideMinPerRow`. Within the
    /// last `lensRadius` rows of a run, the centre follows `slideBound`, so
    /// the end rows meet the rail's end rather than leave a gap before it.
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
            if opened - headRows > 1e-9 && c < headRows { return slideBound(c, top: true) }
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
        if rowCount - tailRows - opened > 1e-9 && c > rowCount - tailRows {
            return slideBound(c, top: false)
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
