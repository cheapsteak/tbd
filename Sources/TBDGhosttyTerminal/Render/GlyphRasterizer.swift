// Adapted from tkzmux c961533 Sources/TkzTerminalRender/GlyphRasterizer.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// GlyphRasterizer — shaped grapheme → CPU bitmap + placement metrics.
//
// Grayscale glyphs go into an 8-bit alpha bitmap, colour glyphs (Apple Color Emoji) into BGRA with
// *premultiplied* alpha, matching the two atlas formats. Subpixel positioning is on with
// quantization off, so a glyph drawn at a fractional pen position looks the same everywhere.
// A face without a real bold gets synthetic bold (fill + stroke). Anything that does not fit the
// grapheme's 1- or 2-cell box is uniformly scaled down until it does — Apple Color Emoji at terminal
// sizes routinely overflows vertically.
//
// `thicken` turns on CoreText "font smoothing" for grayscale glyphs. On an alpha-only context that
// is not LCD filtering but a stem-darkening pass (Ghostty's `font-thicken`): about 17 % more
// coverage at 12.5 pt. It dilates edges by up to a pixel, so the transparent padding grows by one to
// hold it. Colour glyphs are bitmaps and unaffected.
//
// It is off by default, as Ghostty's own `font-thicken` is, so libghostty text has the stroke weight
// of SwiftTerm, which draws without it. With it on, a 2x screenshot shows every stroke about one
// device pixel heavier than SwiftTerm's, with a grey fringe, and beside a SwiftTerm terminal that
// reads as soft, non-Retina text.

import CoreGraphics
import CoreText
import Foundation

/// A rasterized grapheme: pixels plus everything needed to place them.
///
/// `bearingX` / `bearingTop` are device pixels from the pen origin (baseline, left edge of the
/// cluster) to the bitmap's left and top edges, y positive up. To draw at cell origin `(cx, cy)`
/// with baseline `b`: `x = cx + bearingX`, `y = cy + b - bearingTop`.
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

    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    // Ignored for an alpha-only context, but Swift's CGContext initializer requires a non-nil space.
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    init(fontSet: FontSet, metrics: CellMetrics, padding: Int = 1, thicken: Bool = false) {
        self.fontSet = fontSet
        self.metrics = metrics
        self.thicken = thicken
        self.padding = max(0, padding) + (thicken ? 1 : 0)
    }

    /// Rasterizes a shaped grapheme. Returns `nil` for an empty cluster (space, control, no coverage).
    func rasterize(_ shaped: ShapedGrapheme, style: FontStyle = .regular) -> RasterizedGlyph? {
        guard !shaped.glyphs.isEmpty else { return nil }

        let font = shaped.font
        let glyphIDs = shaped.glyphs.map(\.glyph)
        let positions = shaped.glyphs.map { CGPoint(x: $0.xOffset, y: $0.yOffset) }

        // Synthetic bold only when the *family* has no bold face and bold was asked for.
        let synthesizeBold = style.isBold && fontSet.needsSyntheticBold
        let strokeWidth = synthesizeBold ? max(1, CTFontGetSize(font) * 0.03) : 0

        var bounds = [CGRect](repeating: .zero, count: glyphIDs.count)
        _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphIDs, &bounds, glyphIDs.count)

        var union = CGRect.null
        for (i, rect) in bounds.enumerated() where !rect.isNull && !rect.isEmpty {
            union = union.union(rect.offsetBy(dx: positions[i].x, dy: positions[i].y))
        }
        guard !union.isNull, union.width > 0, union.height > 0 else { return nil }
        if strokeWidth > 0 { union = union.insetBy(dx: -strokeWidth, dy: -strokeWidth) }

        // Fit into the grapheme's cell box.
        let boxWidth = CGFloat(metrics.width * max(1, shaped.cellSpan))
        let boxHeight = CGFloat(metrics.height)
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
        // the guarantee "a glyph never exceeds its cell box + padding" holds exactly.
        let overWidth = CGFloat(extent.width - padding * 2) - boxWidth
        let overHeight = CGFloat(extent.height - padding * 2) - boxHeight
        if overWidth > 0 || overHeight > 0 {
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
            } else {
                let opaque = CGColor(colorSpace: grayColorSpace, components: [1, 1])
                if let opaque {
                    ctx.setFillColor(opaque)
                    ctx.setStrokeColor(opaque)
                }
            }
            if strokeWidth > 0 {
                ctx.setLineWidth(strokeWidth)
                ctx.setTextDrawingMode(.fillStroke)
            } else {
                ctx.setTextDrawingMode(.fill)
            }

            CTFontDrawGlyphs(font, glyphIDs, positions, glyphIDs.count, ctx)
            return true
        }
        guard drew else { return nil }

        return RasterizedGlyph(
            width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
            bearingX: originX, bearingTop: originY + height, isColor: isColor,
            appliedScale: appliedScale, pixels: pixels)
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
