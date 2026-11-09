// Adapted from tkzmux c961533 Sources/TkzTerminalRender/GlyphRasterizer.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// GlyphRasterizer — shaped grapheme → CPU bitmap + placement metrics.
//
// Grayscale glyphs go into an 8-bit alpha bitmap, colour glyphs (Apple Color Emoji) into BGRA with
// *premultiplied* alpha, matching the two atlas formats. Subpixel positioning is on with
// quantization off, so a glyph drawn at a fractional pen position looks the same everywhere.
// Every glyph is filled, never stroked, as SwiftTerm draws it: bold is heavier only where the
// family has a bold face, so a family without one draws bold at its regular weight (see
// `FontSet`). A colour or wide glyph that does not fit the grapheme's 1- or 2-cell box is uniformly
// scaled down until it does — Apple Color Emoji at terminal sizes routinely overflows vertically.
// Narrow text may overhang its cell instead (`narrowTextOverhang`), and a wide glyph is centred in
// its two cells.
//
// `thicken` turns on CoreText "font smoothing" for grayscale glyphs. On an alpha-only context that
// is not LCD filtering but a stem-darkening pass (Ghostty's `font-thicken`): about 17 % more
// coverage at 12.5 pt. It dilates edges by up to a pixel, so the transparent padding grows by one to
// hold it. Colour glyphs are bitmaps and unaffected.
//
// It is off by default, as Ghostty's own `font-thicken` is. TBD's "Thin strokes" setting, on by
// default, is what decides it: thin strokes leave it off, and turning thin strokes off turns it on,
// just as SwiftTerm turns CoreGraphics font smoothing off and on for the same setting. With it on, a
// 2x screenshot shows every stroke about one device pixel heavier than SwiftTerm's thin strokes,
// with a grey fringe, and beside a SwiftTerm terminal that reads as soft, non-Retina text.
//
// Known gap with it on: CoreGraphics dilates a glyph by an amount that depends on the text colour,
// and this context draws every glyph with a white fill. Light text matches SwiftTerm's smoothed
// text; dark text comes out heavier than SwiftTerm's.

import CoreGraphics
import CoreText
import Foundation

/// A rasterized grapheme: pixels plus everything needed to place them.
///
/// `bearingX` / `bearingTop` are device pixels from the pen origin (baseline, left edge of the
/// cluster) to the bitmap's left and top edges, y positive up. To draw at cell origin `(cx, cy)`
/// with baseline `b`: `x = cx + bearingX`, `y = cy + b - bearingTop`. A wide glyph's `bearingX`
/// includes the offset that centres it in its two cells.
struct RasterizedGlyph: Sendable, Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytesPerPixel: Int
    let bearingX: Int
    let bearingTop: Int
    let isColor: Bool
    /// Uniform scale applied to fit the cell box (1.0 when the glyph fitted as drawn).
    let appliedScale: CGFloat
    let pixels: [UInt8]

    var isEmpty: Bool { width == 0 || height == 0 }
}

/// Draws shaped graphemes into CPU bitmaps.
///
/// Not `Sendable` (holds `CTFont`s and CG state); owned by the renderer on the render thread.
final class GlyphRasterizer {
    let fontSet: FontSet
    let metrics: CellMetrics
    /// Transparent border kept around every glyph so bilinear sampling never bleeds a neighbour
    /// (one pixel more when `thicken` is on, for the dilation).
    let padding: Int
    /// Font smoothing (stem darkening) on grayscale glyphs, off by default — see the file header.
    let thicken: Bool

    // sRGB, the colour space the Metal layer is tagged with, so a colour glyph's pixels are converted
    // once, by Core Animation, and not first into a device space as well. SwiftTerm's Metal glyph
    // rasterizer draws into sRGB too.
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    // Ignored for an alpha-only context, but Swift's CGContext initializer requires a non-nil space.
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    init(fontSet: FontSet, metrics: CellMetrics, padding: Int = 1, thicken: Bool = false) {
        self.fontSet = fontSet
        self.metrics = metrics
        self.thicken = thicken
        self.padding = max(0, padding) + (thicken ? 1 : 0)
    }

    /// Rasterizes a shaped grapheme in the face it was shaped with. Returns `nil` for an empty
    /// cluster (space, control, no coverage).
    func rasterize(_ shaped: ShapedGrapheme) -> RasterizedGlyph? {
        guard !shaped.glyphs.isEmpty else { return nil }

        let font = shaped.font
        let glyphIDs = shaped.glyphs.map(\.glyph)
        let positions = shaped.glyphs.map { CGPoint(x: $0.xOffset, y: $0.yOffset) }

        var bounds = [CGRect](repeating: .zero, count: glyphIDs.count)
        _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphIDs, &bounds, glyphIDs.count)

        var union = CGRect.null
        for (i, rect) in bounds.enumerated() where !rect.isNull && !rect.isEmpty {
            union = union.union(rect.offsetBy(dx: positions[i].x, dy: positions[i].y))
        }
        guard !union.isNull, union.width > 0, union.height > 0 else { return nil }

        // Fit into the grapheme's cell box. Narrow text gets a box `narrowTextOverhang` times the
        // cell instead, so in practice it is drawn at its natural size.
        let span = max(1, shaped.cellSpan)
        let slotWidth = CGFloat(metrics.width * span)
        let isNarrowText = span == 1 && !shaped.isColor
        let overhang: CGFloat = isNarrowText ? GlyphRasterizer.narrowTextOverhang : 1
        let boxWidth = slotWidth * overhang
        let boxHeight = CGFloat(metrics.height) * overhang
        var appliedScale: CGFloat = 1
        if union.width > boxWidth || union.height > boxHeight {
            appliedScale = min(boxWidth / union.width, boxHeight / union.height)
        }
        func integerExtent(_ scale: CGFloat) -> (originX: Int, originY: Int, width: Int, height: Int) {
            let scaled = union.applying(CGAffineTransform(scaleX: scale, y: scale))
            let minX = Int(scaled.minX.rounded(.down))
            let minY = Int(scaled.minY.rounded(.down))
            return (minX - padding, minY - padding,
                    Int(scaled.maxX.rounded(.up)) - minX + padding * 2,
                    Int(scaled.maxY.rounded(.up)) - minY + padding * 2)
        }

        var extent = integerExtent(appliedScale)
        // Rounding the scaled bounds outward can push the bitmap 1 px past the box; tighten once so
        // the guarantee "a glyph never exceeds its box + padding" holds exactly. Not for narrow text
        // at its natural size, which may overhang its cell, and which this would shrink.
        let overWidth = CGFloat(extent.width - padding * 2) - boxWidth
        let overHeight = CGFloat(extent.height - padding * 2) - boxHeight
        let mayTighten = !isNarrowText || appliedScale < 1
        if mayTighten, overWidth > 0 || overHeight > 0 {
            let shrinkX = overWidth > 0 ? boxWidth / CGFloat(extent.width - padding * 2) : 1
            let shrinkY = overHeight > 0 ? boxHeight / CGFloat(extent.height - padding * 2) : 1
            appliedScale *= min(shrinkX, shrinkY)
            extent = integerExtent(appliedScale)
        }
        let (originX, originY, width, height) = extent
        guard width > 0, height > 0 else { return nil }

        let isColor = shaped.isColor
        let bytesPerPixel = isColor ? 4 : 1
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let context: CGContext?
            if isColor {
                context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            } else {
                context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: grayColorSpace,
                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            }
            guard let ctx = context else { return false }

            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            // Smoothing on an alpha-only context is the stem-darkening pass (see the header); a
            // colour glyph is a bitmap and gains nothing from it.
            let smooth = thicken && !isColor
            ctx.setAllowsFontSmoothing(smooth)
            ctx.setShouldSmoothFonts(smooth)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.setAllowsFontSubpixelQuantization(false)

            // Bitmap origin is bottom-left; move the pen origin there and apply the fit scale.
            ctx.translateBy(x: CGFloat(-originX), y: CGFloat(-originY))
            if appliedScale != 1 { ctx.scaleBy(x: appliedScale, y: appliedScale) }

            if isColor {
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            } else if let opaque = CGColor(colorSpace: grayColorSpace, components: [1, 1]) {
                ctx.setFillColor(opaque)
            }
            ctx.setTextDrawingMode(.fill)

            CTFontDrawGlyphs(font, glyphIDs, positions, glyphIDs.count, ctx)
            return true
        }
        guard drew else { return nil }

        let centring = span > 1
            ? GlyphRasterizer.centringOffset(of: shaped, slotWidth: slotWidth, scale: appliedScale)
            : 0
        return RasterizedGlyph(
            width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
            bearingX: originX + centring, bearingTop: originY + height, isColor: isColor,
            appliedScale: appliedScale, pixels: pixels)
    }

    // MARK: - Placement

    /// How many times its cell a narrow, monochrome glyph may grow before it is scaled down.
    ///
    /// A wide glyph or a colour glyph is scaled to fit its cells whenever its ink overflows them.
    /// A narrow monochrome glyph, from the terminal's font or from a fallback font, is drawn at its
    /// natural size, as SwiftTerm draws it: SwiftTerm fits only multi-cell glyphs, and Ghostty too
    /// lets ordinary text overflow its rounded cell. With the cell width rounded to the nearest
    /// pixel, `%&@` in Monaco 12 pt and `#WX_w~` in Menlo 12 pt have ink up to 0.6 px wider than
    /// their 14 px cell at 2x, Menlo's italic `WX` reaches further, and fallback symbols such as `●`
    /// and `⧉` are wider still. Scaling them down would make them smaller and softer than SwiftTerm
    /// draws them. The overhang is not clipped: the background pass paints every cell before any
    /// glyph is drawn. Only ink more than twice its cell, which takes a stack of combining marks or
    /// an outsized icon, is scaled, to keep its bitmap bounded.
    ///
    /// The allowance holds vertically too, because SwiftTerm leaves every one-cell glyph as drawn: a
    /// narrow glyph taller than its row, such as stacked combining marks or a tall fallback symbol,
    /// draws over the rows above and below it rather than being shrunk into its own.
    ///
    /// Colour glyphs are the one place this departs from SwiftTerm, which also draws a one-cell
    /// emoji at its natural size: an emoji spilling over its neighbour reads as a rendering fault.
    static let narrowTextOverhang: CGFloat = 2

    /// How far right a wide cluster moves so that its advance, scaled by `scale`, is centred in its
    /// `slotWidth`-pixel slot.
    ///
    /// Pinned to the slot's left edge, a CJK ideograph whose advance is narrower than its two cells
    /// leaves all the slack on its right, a gap SwiftTerm calls the phantom gap. This splits it
    /// evenly, as the horizontal half of SwiftTerm's `GlyphSlotFit` does (adapted from SwiftTerm,
    /// MIT, Copyright (c) 2019-2026 Miguel de Icaza, Sources/SwiftTerm/Apple/AppleTerminalView.swift
    /// at cheapsteak/SwiftTerm b4db5b0). Rounded to a whole pixel, because the pen sits on one and
    /// the atlas is sampled without filtering. Narrow glyphs stay at their cell's left edge, as in
    /// SwiftTerm. `GlyphSlotFit` also centres a scaled-down wide glyph vertically, which this does
    /// not: a scaled wide glyph keeps its baseline.
    private static func centringOffset(of shaped: ShapedGrapheme, slotWidth: CGFloat, scale: CGFloat) -> Int {
        let glyphIDs = shaped.glyphs.map(\.glyph)
        var advances = [CGSize](repeating: .zero, count: glyphIDs.count)
        _ = CTFontGetAdvancesForGlyphs(shaped.font, .horizontal, glyphIDs, &advances, glyphIDs.count)
        var advance: CGFloat = 0
        for (glyph, size) in zip(shaped.glyphs, advances) {
            advance = max(advance, glyph.xOffset + size.width)
        }
        guard advance > 0 else { return 0 }
        return Int(((slotWidth - advance * scale) / 2).rounded())
    }

    // MARK: - Debug image

    /// A `CGImage` of a rasterized glyph, for tests and eyeball checks.
    static func makeCGImage(_ glyph: RasterizedGlyph) -> CGImage? {
        guard !glyph.isEmpty else { return nil }
        guard let provider = CGDataProvider(data: Data(glyph.pixels) as CFData) else { return nil }
        if glyph.isColor {
            return CGImage(
                width: glyph.width, height: glyph.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: glyph.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return CGImage(
            width: glyph.width, height: glyph.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: glyph.bytesPerRow, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
