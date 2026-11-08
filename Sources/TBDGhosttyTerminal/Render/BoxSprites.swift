// Adapted from tkzmux c961533 Sources/TkzTerminalRender/BoxSprites.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// BoxSprites — procedural box-drawing and block-element glyphs.
//
// U+2500…U+257F (box drawing) and U+2580…U+259F (block elements) are the two ranges a terminal has
// to draw itself. A font lays its own versions out on the em box, not on the terminal cell, so
// adjacent cells never tile: `█` next to `█` leaves a seam (the Claude Code banner logo turns into
// stripes), the eighth-blocks do not line up into a ramp, and `┌──┐` corners miss each other by a
// pixel. Ghostty, kitty and Terminal.app all synthesize these; so do we.
//
// Every sprite is drawn at exactly `metrics.width × metrics.height` with `appliedScale = 1`, so it
// tiles with its neighbours by construction and never goes through the rasterizer's fit/shrink
// pass. Fills are integer rects with antialiasing off (crisp edges, no half-covered seam pixels);
// only arcs and diagonals are antialiased. The bitmap keeps the same transparent padding as a font
// glyph so atlas neighbours cannot bleed in — padding sits *outside* the cell and is transparent,
// so it cannot reintroduce a seam.

import CoreGraphics
import Foundation

/// Draws the box-drawing and block-element ranges as cell-exact bitmaps.
///
/// Not `Sendable` (CoreGraphics state); owned by `GlyphCache` on the render thread.
struct BoxSprites {
    let metrics: CellMetrics
    /// Transparent border, matching `GlyphRasterizer.padding`.
    let padding: Int

    private let gray = CGColorSpaceCreateDeviceGray()

    init(metrics: CellMetrics, padding: Int = 1) {
        self.metrics = metrics
        self.padding = max(0, padding)
    }

    /// True for the single-scalar clusters this type draws.
    static func covers(_ scalars: [Unicode.Scalar]) -> Bool {
        scalars.count == 1 && covers(scalars[0])
    }

    static func covers(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    // MARK: - Geometry

    private var w: Int { metrics.width }
    private var h: Int { metrics.height }

    /// Line thickness of a "light" stroke, in device pixels.
    private var light: Int { max(1, Int((CGFloat(w) / 8).rounded())) }
    /// "Heavy" is twice light, but always at least one pixel more.
    private var heavy: Int { max(light + 1, light * 2) }

    /// n/8 of the cell width, rounded to the nearest pixel. `eighthX(8) == w` exactly, which is what
    /// makes `▌` + `▐` and the eighth-block ramp tile without a seam or an overlap.
    private func eighthX(_ n: Int) -> Int { n >= 8 ? w : (w * n + 4) / 8 }
    private func eighthY(_ n: Int) -> Int { n >= 8 ? h : (h * n + 4) / 8 }

    /// A band of `thickness` px centred on `center`.
    private func band(_ center: Int, _ thickness: Int) -> (start: Int, end: Int) {
        let start = center - thickness / 2
        return (start, start + thickness)
    }

    /// The continuous-coordinate centre of `band`, for strokes that have to line up with fills.
    private func bandCentre(_ center: Int, _ thickness: Int) -> CGFloat {
        CGFloat(band(center, thickness).start) + CGFloat(thickness) / 2
    }

    // MARK: - Entry point

    /// Rasterizes one sprite, or `nil` when the scalar is outside the covered ranges (the caller
    /// then falls back to the font).
    func rasterize(_ scalar: Unicode.Scalar) -> RasterizedGlyph? {
        let value = scalar.value
        guard BoxSprites.covers(scalar) else { return nil }
        return makeBitmap { ctx in
            if value >= 0x2580 {
                self.drawBlock(value, ctx)
            } else {
                self.drawBox(value, ctx)
            }
        }
    }

    /// Builds the alpha-only bitmap and runs `draw` in cell coordinates: origin at the cell's
    /// top-left corner, y growing downward, (w, h) at the bottom-right.
    private func makeBitmap(_ draw: (CGContext) -> Void) -> RasterizedGlyph? {
        let width = w + padding * 2
        let height = h + padding * 2
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: gray,
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }

            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            ctx.setLineCap(.butt)
            // Bitmap origin is bottom-left; flip into top-left cell coordinates.
            ctx.translateBy(x: CGFloat(padding), y: CGFloat(padding + h))
            ctx.scaleBy(x: 1, y: -1)
            setAlpha(ctx, 1)
            draw(ctx)
            return true
        }
        guard drew else { return nil }

        return RasterizedGlyph(
            width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: 1,
            bearingX: -padding, bearingTop: metrics.baseline + padding, isColor: false,
            appliedScale: 1, pixels: pixels)
    }

    private func setAlpha(_ ctx: CGContext, _ alpha: CGFloat) {
        if let color = CGColor(colorSpace: gray, components: [1, alpha]) {
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
        }
    }

    private func fill(_ ctx: CGContext, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        guard width > 0, height > 0 else { return }
        ctx.fill(CGRect(x: x, y: y, width: width, height: height))
    }

    // MARK: - Block elements (U+2580…U+259F)

    /// Which quadrants each of U+2596…U+259F fills: 1 = upper left, 2 = upper right,
    /// 4 = lower left, 8 = lower right.
    private static let quadrantMask: [UInt8] = [
        0b0100,  // 2596 ▖ lower left
        0b1000,  // 2597 ▗ lower right
        0b0001,  // 2598 ▘ upper left
        0b1101,  // 2599 ▙ upper left, lower left, lower right
        0b1001,  // 259A ▚ upper left, lower right
        0b0111,  // 259B ▛ upper left, upper right, lower left
        0b1011,  // 259C ▜ upper left, upper right, lower right
        0b0010,  // 259D ▝ upper right
        0b0110,  // 259E ▞ upper right, lower left
        0b1110,  // 259F ▟ upper right, lower left, lower right
    ]

    private func drawBlock(_ value: UInt32, _ ctx: CGContext) {
        switch value {
        case 0x2580:  // ▀ upper half
            fill(ctx, 0, 0, w, eighthY(4))
        case 0x2581...0x2588:  // ▁…█ lower one eighth … full block
            // Measured from the *top* edge down, so `▄` is the exact complement of `▀` rather than
            // overlapping it by the rounding of two independent halves.
            let top = eighthY(8 - Int(value - 0x2580))
            fill(ctx, 0, top, w, h - top)
        case 0x2589...0x258F:  // ▉…▏ left seven eighths … left one eighth
            fill(ctx, 0, 0, eighthX(8 - Int(value - 0x2588)), h)
        case 0x2590:  // ▐ right half
            let x = eighthX(4)
            fill(ctx, x, 0, w - x, h)
        case 0x2591, 0x2592, 0x2593:  // ░▒▓ light / medium / dark shade
            // Flat coverage rather than a dot pattern: it tiles seamlessly and reads as an even
            // tint at 12.5 pt, which is what shades are used for (gradients, dimmed fills).
            setAlpha(ctx, [0.25, 0.5, 0.75][Int(value - 0x2591)])
            fill(ctx, 0, 0, w, h)
            setAlpha(ctx, 1)
        case 0x2594:  // ▔ upper one eighth
            fill(ctx, 0, 0, w, eighthY(1))
        case 0x2595:  // ▕ right one eighth
            let x = eighthX(7)
            fill(ctx, x, 0, w - x, h)
        case 0x2596...0x259F:
            let mask = BoxSprites.quadrantMask[Int(value - 0x2596)]
            let hx = eighthX(4)
            let hy = eighthY(4)
            if mask & 0b0001 != 0 { fill(ctx, 0, 0, hx, hy) }
            if mask & 0b0010 != 0 { fill(ctx, hx, 0, w - hx, hy) }
            if mask & 0b0100 != 0 { fill(ctx, 0, hy, hx, h - hy) }
            if mask & 0b1000 != 0 { fill(ctx, hx, hy, w - hx, h - hy) }
        default:
            break
        }
    }

    // MARK: - Box drawing (U+2500…U+257F)

    enum ArmStyle: UInt8 {
        case none, light, heavy, double

        init(_ char: Character) {
            switch char {
            case "l": self = .light
            case "h": self = .heavy
            case "d": self = .double
            default: self = .none
            }
        }

        var isSet: Bool { self != .none }
    }

    /// One "URDL" code (up, right, down, left) per codepoint from U+2500:
    /// `.` none, `l` light, `h` heavy, `d` double. Dashes (2504–250B, 254C–254F), arcs (256D–2570)
    /// and diagonals (2571–2573) are drawn by hand and their entries here are never read.
    static let boxArms: [String] = [
        ".l.l", ".h.h", "l.l.", "h.h.", "....", "....", "....", "....",  // 2500 ─━│┃┄┅┆┇
        "....", "....", "....", "....", ".ll.", ".hl.", ".lh.", ".hh.",  // 2508 ┈┉┊┋┌┍┎┏
        "..ll", "..lh", "..hl", "..hh", "ll..", "lh..", "hl..", "hh..",  // 2510 ┐┑┒┓└┕┖┗
        "l..l", "l..h", "h..l", "h..h", "lll.", "lhl.", "hll.", "llh.",  // 2518 ┘┙┚┛├┝┞┟
        "hlh.", "hhl.", "lhh.", "hhh.", "l.ll", "l.lh", "h.ll", "l.hl",  // 2520 ┠┡┢┣┤┥┦┧
        "h.hl", "h.lh", "l.hh", "h.hh", ".lll", ".llh", ".hll", ".hlh",  // 2528 ┨┩┪┫┬┭┮┯
        ".lhl", ".lhh", ".hhl", ".hhh", "ll.l", "ll.h", "lh.l", "lh.h",  // 2530 ┰┱┲┳┴┵┶┷
        "hl.l", "hl.h", "hh.l", "hh.h", "llll", "lllh", "lhll", "lhlh",  // 2538 ┸┹┺┻┼┽┾┿
        "hlll", "llhl", "hlhl", "hllh", "hhll", "llhh", "lhhl", "hhlh",  // 2540 ╀╁╂╃╄╅╆╇
        "lhhh", "hlhh", "hhhl", "hhhh", "....", "....", "....", "....",  // 2548 ╈╉╊╋╌╍╎╏
        ".d.d", "d.d.", ".dl.", ".ld.", ".dd.", "..ld", "..dl", "..dd",  // 2550 ═║╒╓╔╕╖╗
        "ld..", "dl..", "dd..", "l..d", "d..l", "d..d", "ldl.", "dld.",  // 2558 ╘╙╚╛╜╝╞╟
        "ddd.", "l.ld", "d.dl", "d.dd", ".dld", ".ldl", ".ddd", "ld.d",  // 2560 ╠╡╢╣╤╥╦╧
        "dl.l", "dd.d", "ldld", "dldl", "dddd", "....", "....", "....",  // 2568 ╨╩╪╫╬╭╮╯
        "....", "....", "....", "....", "...l", "l...", ".l..", "..l.",  // 2570 ╰╱╲╳╴╵╶╷
        "...h", "h...", ".h..", "..h.", ".h.l", "l.h.", ".l.h", "h.l.",  // 2578 ╸╹╺╻╼╽╾╿
    ]

    private func drawBox(_ value: UInt32, _ ctx: CGContext) {
        switch value {
        case 0x2504...0x2507: return drawDashes(count: 3, value: value, base: 0x2504, ctx)
        case 0x2508...0x250B: return drawDashes(count: 4, value: value, base: 0x2508, ctx)
        case 0x254C...0x254F: return drawDashes(count: 2, value: value, base: 0x254C, ctx)
        case 0x256D...0x2570: return drawArc(value, ctx)
        case 0x2571...0x2573: return drawDiagonal(value, ctx)
        default: break
        }

        let code = Array(BoxSprites.boxArms[Int(value - 0x2500)])
        let arms = code.map(ArmStyle.init)  // up, right, down, left
        drawSolidArms(arms, ctx)
        drawDoubleRails(arms, ctx)
    }

    /// Light and heavy arms: one rect per direction, every rect extended into a shared central
    /// junction so a corner or a tee joins without a notch.
    private func drawSolidArms(_ arms: [ArmStyle], _ ctx: CGContext) {
        func thickness(_ style: ArmStyle) -> Int? {
            switch style {
            case .light: return light
            case .heavy: return heavy
            case .none, .double: return nil
            }
        }
        let solid = arms.map(thickness)
        guard solid.contains(where: { $0 != nil }) else { return }

        let cx = w / 2
        let cy = h / 2
        // Each arm stops exactly on the far edge of the perpendicular arm's band, so a corner or a
        // tee joins flush — one pixel more and every junction grows a visible nub. With no
        // perpendicular arm (a half line like `╴`) the arm's own band is the stop instead.
        let vThickness = max(solid[0] ?? 0, solid[2] ?? 0)
        let hThickness = max(solid[1] ?? 0, solid[3] ?? 0)
        let hasVBand = vThickness > 0
        let hasHBand = hThickness > 0
        let vBand = band(cx, vThickness)
        let hBand = band(cy, hThickness)

        // A single line that runs straight through (arms on both sides) always crosses the rails —
        // that is what `╪` and `╫` look like. One that *ends* at a double line stops at the near
        // rail if the double runs through (`╧`), or reaches the far rail to close a corner (`╘`).
        let vSolidThrough = solid[0] != nil && solid[2] != nil
        let hSolidThrough = solid[1] != nil && solid[3] != nil
        let vDouble = (arms[0] == .double || arms[2] == .double) && !hSolidThrough
        let hDouble = (arms[1] == .double || arms[3] == .double) && !vSolidThrough
        let hThrough = arms[1] == .double && arms[3] == .double
        let vThrough = arms[0] == .double && arms[2] == .double
        let offset = railOffset

        if let t = solid[0] {  // up
            let x = band(cx, t)
            let stop = hasHBand ? hBand.end : band(cy, t).end
            let bottom = hDouble ? (hThrough ? cy - offset : cy + offset) : stop
            fill(ctx, x.start, 0, t, max(0, bottom))
        }
        if let t = solid[2] {  // down
            let x = band(cx, t)
            let stop = hasHBand ? hBand.start : band(cy, t).start
            let top = hDouble ? (hThrough ? cy + offset : cy - offset) : stop
            fill(ctx, x.start, top, t, max(0, h - top))
        }
        if let t = solid[3] {  // left
            let y = band(cy, t)
            let stop = hasVBand ? vBand.end : band(cx, t).end
            let right = vDouble ? (vThrough ? cx - offset : cx + offset) : stop
            fill(ctx, 0, y.start, max(0, right), t)
        }
        if let t = solid[1] {  // right
            let y = band(cy, t)
            let stop = hasVBand ? vBand.start : band(cx, t).start
            let left = vDouble ? (vThrough ? cx + offset : cx - offset) : stop
            fill(ctx, left, y.start, max(0, w - left), t)
        }
    }

    /// Centre-to-centre distance from the cell axis to each rail of a double line: the pair spans
    /// `3 * light` px, two rails of `light` with a `light` gap between them.
    private var railOffset: Int { light }

    /// Double arms: two parallel rails per axis, each rail clipped where it meets the other axis so
    /// `╔` closes at the corner and `╬` leaves the four inner gaps open.
    private func drawDoubleRails(_ arms: [ArmStyle], _ ctx: CGContext) {
        // up, right, down, left → (near, far) per axis, in the transposed helper's terms.
        if arms[1] == .double || arms[3] == .double {
            drawRails(ctx, transposed: false,
                      lowSide: arms[3] == .double, highSide: arms[1] == .double,
                      crossLow: arms[0], crossHigh: arms[2])
        }
        if arms[0] == .double || arms[2] == .double {
            drawRails(ctx, transposed: true,
                      lowSide: arms[0] == .double, highSide: arms[2] == .double,
                      crossLow: arms[3], crossHigh: arms[1])
        }
    }

    /// Draws the two rails of one axis.
    ///
    /// Coordinates are "along" (the axis the rails run on) and "across". `transposed` swaps them, so
    /// the same code draws `═` and `║`. `lowSide` / `highSide` say whether the arm exists towards
    /// along = 0 and along = max; `crossLow` / `crossHigh` are the two arms of the other axis.
    private func drawRails(_ ctx: CGContext,
                           transposed: Bool,
                           lowSide: Bool,
                           highSide: Bool,
                           crossLow: ArmStyle,
                           crossHigh: ArmStyle) {
        let alongMax = transposed ? h : w
        let acrossMax = transposed ? w : h
        let centre = acrossMax / 2
        let crossCentre = alongMax / 2
        let offset = railOffset
        let crossDouble = crossLow == .double || crossHigh == .double

        func put(_ alongStart: Int, _ alongEnd: Int, _ acrossCentre: Int) {
            guard alongEnd > alongStart else { return }
            let a = band(acrossCentre, light)
            if transposed {
                fill(ctx, a.start, alongStart, light, alongEnd - alongStart)
            } else {
                fill(ctx, alongStart, a.start, alongEnd - alongStart, light)
            }
        }

        for side in [-1, 1] {  // -1 = the rail nearer across = 0, +1 = the far one
            let acrossCentre = centre + side * offset

            guard crossDouble else {
                // Nothing double crosses: the rail runs from edge to edge, or stops at the axis when
                // there is no arm on that side.
                let start = lowSide ? 0 : crossCentre
                let end = highSide ? alongMax : crossCentre
                put(start, end, acrossCentre)
                continue
            }

            if crossLow == .double && crossHigh == .double {
                // A through line crosses: the rail is interrupted between the two crossing rails.
                if lowSide { put(0, crossCentre - offset, acrossCentre) }
                if highSide { put(crossCentre + offset, alongMax, acrossCentre) }
                continue
            }

            // A tee or a corner: the rail on the far side from the crossing arm is the outer one and
            // runs past the axis to close the corner; the near rail stops short of it.
            let crossSide = crossLow == .double ? -1 : 1
            let outer = side != crossSide
            let start = lowSide ? 0 : crossCentre + (outer ? -offset : offset)
            let end = highSide ? alongMax : crossCentre + (outer ? offset : -offset)
            if outer {
                put(start, end, acrossCentre)
            } else {
                // The inner rail is cut by the crossing line, so it can be two separate stubs.
                if lowSide { put(0, crossCentre - offset, acrossCentre) }
                if highSide { put(crossCentre + offset, alongMax, acrossCentre) }
            }
        }
    }

    /// U+2504…U+250B and U+254C…U+254F: `count` dashes evenly spread along the cell.
    private func drawDashes(count: Int, value: UInt32, base: UInt32, _ ctx: CGContext) {
        let index = Int(value - base)
        let vertical = index >= 2
        let t = (index % 2 == 0) ? light : heavy
        let length = vertical ? h : w
        let across = band((vertical ? w : h) / 2, t)
        let segment = CGFloat(length) / CGFloat(count)
        let dash = max(1, Int((segment * 0.6).rounded()))
        for i in 0..<count {
            let start = Int((CGFloat(i) * segment).rounded()) + max(0, (Int(segment) - dash) / 2)
            let end = min(length, start + dash)
            guard end > start else { continue }
            if vertical {
                fill(ctx, across.start, start, t, end - start)
            } else {
                fill(ctx, start, across.start, end - start, t)
            }
        }
    }

    /// U+256D…U+2570: light arcs. Antialiased, unlike the straight sprites — a stair-stepped
    /// quarter circle looks worse than a soft one, and the ends still land on the cell edge so they
    /// meet a neighbouring `─` or `│` exactly.
    private func drawArc(_ value: UInt32, _ ctx: CGContext) {
        let cx = bandCentre(w / 2, light)
        let cy = bandCentre(h / 2, light)
        let radius = min(CGFloat(w), CGFloat(h)) / 3
        // up, right, down, left
        let (vertical, horizontal): (CGFloat, CGFloat)
        switch value {
        case 0x256D: (vertical, horizontal) = (CGFloat(h), CGFloat(w))  // ╭ down and right
        case 0x256E: (vertical, horizontal) = (CGFloat(h), 0)           // ╮ down and left
        case 0x256F: (vertical, horizontal) = (0, 0)                    // ╯ up and left
        default: (vertical, horizontal) = (0, CGFloat(w))               // ╰ up and right
        }
        let vSign: CGFloat = vertical > cy ? 1 : -1
        let hSign: CGFloat = horizontal > cx ? 1 : -1

        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: vertical))
        path.addLine(to: CGPoint(x: cx, y: cy + vSign * radius))
        path.addQuadCurve(to: CGPoint(x: cx + hSign * radius, y: cy),
                          control: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: horizontal, y: cy))

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setLineWidth(CGFloat(light))
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
    }

    /// U+2571…U+2573: the two diagonals and their cross.
    private func drawDiagonal(_ value: UInt32, _ ctx: CGContext) {
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setLineWidth(CGFloat(light))
        if value != 0x2571 {  // ╲ and ╳
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: w, y: h))
        }
        if value != 0x2572 {  // ╱ and ╳
            ctx.move(to: CGPoint(x: 0, y: h))
            ctx.addLine(to: CGPoint(x: w, y: 0))
        }
        ctx.strokePath()
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
    }
}
