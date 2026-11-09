import AppKit
import CoreText
import Foundation
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

private let monacoAndMenlo = NSFont(name: "Monaco", size: 12) != nil && NSFont(name: "Menlo", size: 12) != nil
private let monacoOrMenloMissing: Comment = "Monaco or Menlo is not installed"

/// The libghostty grid is SwiftTerm's: the same cell width, height and baseline in device pixels,
/// so a libghostty terminal lays out the same columns and rows as a SwiftTerm terminal in the same
/// pane. And glyphs sit in those cells as SwiftTerm puts them: narrow text at its natural size even
/// where its ink is wider than the cell, wide glyphs scaled to fit their two cells and centred in
/// them. Colour glyphs are fitted to their cells as well.
///
/// Main actor, because a `FontSet` is built there.
@Suite(.fastPassBounded)
@MainActor
struct CellGeometryTests {
    // MARK: - Cell size and baseline

    /// SwiftTerm's formulas, fed the raw CoreText metrics of each font as `FontSet` builds it, at
    /// `pointSize × scale` pixels. Pinned as numbers, so they hold on a runner without the fonts.
    /// Each case gives `[width, height, baseline]` in device pixels.
    @Test(arguments: [
        // Monaco 12 pt at 2x: W advances 14.402 px, and the 32.004 px line rounds up to 17 pt.
        SwiftTermCase(advance: 14.402_343_75, ascent: 24, descent: 6, leading: 2.003_906_25, scale: 2,
                      swiftTerm: [14, 34, 24]),
        // Menlo 12 pt at 2x: W advances 14.449 px, the line is 27.938 px.
        SwiftTermCase(advance: 14.449_218_75, ascent: 22.277_343_75, descent: 5.660_156_25, leading: 0, scale: 2,
                      swiftTerm: [14, 28, 22]),
        // Monaco 13 pt at 2x, where the advance rounds up.
        SwiftTermCase(advance: 15.602_539_062_5, ascent: 26, descent: 6.5, leading: 2.170_898_437_5, scale: 2,
                      swiftTerm: [16, 36, 26]),
        // Monaco 12 pt at 1x.
        SwiftTermCase(advance: 7.201_171_875, ascent: 12, descent: 3, leading: 1.001_953_125, scale: 1,
                      swiftTerm: [7, 17, 12]),
    ])
    func swiftTermFormulasGiveSwiftTermsCells(_ given: SwiftTermCase) {
        let grid = CellMetrics.swiftTermGrid(advance: given.advance, ascent: given.ascent,
                                             descent: given.descent, leading: given.leading,
                                             scale: given.scale)
        let cell: [Int] = [grid.width, grid.height, grid.baseline]
        let swiftTerm: [Int] = given.swiftTerm
        #expect(cell == swiftTerm, "width, height and baseline came out \(cell), not SwiftTerm's \(swiftTerm)")
    }

    /// The fonts themselves, measured as a terminal measures them: Monaco 12 pt, TBD's default, and
    /// Menlo 12 pt, at 2x. A SwiftTerm terminal in Monaco 12 pt reports 14 × 34 px cells (CSI 16 t).
    @Test(.enabled(if: monacoAndMenlo, monacoOrMenloMissing))
    func monacoAndMenloAt12PointGetSwiftTermsCells() throws {
        let cases: [(name: String, swiftTerm: [Int])] = [("Monaco", [14, 34, 24]), ("Menlo", [14, 28, 22])]
        for (name, swiftTerm) in cases {
            let font = try #require(NSFont(name: name, size: 12))
            let metrics = CellMetrics(fontSet: FontSet(font: font, scale: 2))
            let cell: [Int] = [metrics.width, metrics.height, metrics.baseline]
            #expect(cell == swiftTerm, "\(name) 12 pt at 2x got width, height and baseline \(cell), not \(swiftTerm)")
        }
    }

    /// `CellMetrics` measures a font built in device pixels and works back to points. SwiftTerm
    /// measures the point-size `NSFont`, taking `W`'s advance by glyph name. Both routes must land on
    /// the same pixels, for each font and scale a terminal is likely to see.
    @Test(arguments: [1, 2] as [CGFloat])
    func cellMetricsMatchSwiftTermsOwnArithmetic(scale: CGFloat) {
        var fonts: [NSFont] = [11, 12, 13].map { NSFont.monospacedSystemFont(ofSize: $0, weight: .regular) }
        for name in ["Monaco", "Menlo"] {
            for size: CGFloat in [12, 13] {
                if let font = NSFont(name: name, size: size) { fonts.append(font) }
            }
        }
        for font in fonts {
            let metrics = CellMetrics(fontSet: FontSet(font: font, scale: scale))
            let cell: [Int] = [metrics.width, metrics.height, metrics.baseline]
            let swiftTerm: [Int] = swiftTermCell(font, scale: scale)
            #expect(cell == swiftTerm,
                    "\(font.fontName) \(font.pointSize) pt at \(scale)x: \(cell), but SwiftTerm's arithmetic gives \(swiftTerm)")
        }
    }

    // MARK: - Fitting glyphs to their cells

    /// The font's own text is drawn at its natural size even where its bitmap is wider than the
    /// cell: the ink of `%&@` in Monaco and `#WX_w~` in Menlo reaches past their 14 px cells by under
    /// a pixel, Monaco's `W` fits but spans 15 whole pixels, and Menlo's italic and bold reach
    /// further. Scaled to fit, they would be smaller and softer than their neighbours.
    @Test(.enabled(if: monacoAndMenlo, monacoOrMenloMissing))
    func theFontsOwnTextIsNotScaledWhereItsInkOverhangsItsCell() throws {
        let cases: [(name: String, characters: String, style: FontStyle)] = [
            ("Monaco", "%&@W", .regular),
            ("Menlo", "#WX_w~", .regular),
            ("Menlo", "WX", .italic),
            ("Menlo", "#W", .bold),
        ]
        for (name, characters, style) in cases {
            let fontSet = FontSet(font: try #require(NSFont(name: name, size: 12)), scale: 2)
            let metrics = CellMetrics(fontSet: fontSet)
            let shaper = GraphemeShaper(fontSet: fontSet)
            let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: metrics)
            for character in characters {
                let shaped = shaper.shape(character, style: style)
                let glyph = try #require(rasterizer.rasterize(shaped), "\(name) drew no \(character)")
                let inkWidth = glyph.width - 2 * rasterizer.padding
                try #require(inkWidth > metrics.width,
                             "\(name) \(style) \(character) spans \(inkWidth) px, no wider than its \(metrics.width) px cell")
                let scale: CGFloat = glyph.appliedScale
                #expect(scale == 1,
                        "\(name) \(style) \(character), spanning \(inkWidth) px in a \(metrics.width) px cell, was scaled by \(scale)")
            }
        }
        // At least one of them overhangs by more than a pixel, so a one-pixel tolerance would not
        // have passed this test.
        let menlo = FontSet(font: try #require(NSFont(name: "Menlo", size: 12)), scale: 2)
        let metrics = CellMetrics(fontSet: menlo)
        let rasterizer = GlyphRasterizer(fontSet: menlo, metrics: metrics)
        let italic = try #require(rasterizer.rasterize(GraphemeShaper(fontSet: menlo).shape("W", style: .italic)))
        let overhang = italic.width - 2 * rasterizer.padding - metrics.width
        #expect(overhang > 1, "Menlo's italic W overhangs its cell by only \(overhang) px")
    }

    /// A narrow glyph from a fallback font is drawn at its natural size too, as SwiftTerm draws it:
    /// Monaco has neither `●` nor `⧉`, and the fonts that do draw both wider than their 14 px cell.
    @Test(.enabled(if: monacoAndMenlo, monacoOrMenloMissing))
    func aNarrowFallbackGlyphIsNotScaledWhereItsInkOverhangsItsCell() throws {
        let fontSet = FontSet(font: try #require(NSFont(name: "Monaco", size: 12)), scale: 2)
        let metrics = CellMetrics(fontSet: fontSet)
        let shaper = GraphemeShaper(fontSet: fontSet)
        let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: metrics)
        let monacoName: String = fontSet.postScriptName(for: .regular)
        let symbols: [Character] = ["●", "⧉"]
        for symbol in symbols {
            let shaped = shaper.shape(symbol, cellSpan: 1)
            let fontName: String = shaped.fontName
            try #require(fontName != monacoName, "Monaco drew \(symbol) itself, not a fallback")
            try #require(!shaped.isColor, "\(symbol) came from a colour font, \(fontName)")
            let glyph = try #require(rasterizer.rasterize(shaped), "\(fontName) drew no \(symbol)")
            let inkWidth = glyph.width - 2 * rasterizer.padding
            try #require(inkWidth > metrics.width,
                         "\(symbol) from \(fontName) spans \(inkWidth) px, no wider than its \(metrics.width) px cell")
            let scale: CGFloat = glyph.appliedScale
            #expect(scale == 1,
                    "\(symbol) from \(fontName), spanning \(inkWidth) px in a \(metrics.width) px cell, was scaled by \(scale)")
        }
    }

    /// A wide glyph is scaled to fit its two cells, and a colour glyph its cells: here a CJK
    /// ideograph drawn at twice its size in two cells, and an emoji in one cell.
    @Test(.enabled(if: monacoAndMenlo, monacoOrMenloMissing))
    func aWideOrColourGlyphIsScaledToFitItsCells() throws {
        let fontSet = FontSet(font: try #require(NSFont(name: "Menlo", size: 12)), scale: 2)
        let metrics = CellMetrics(fontSet: fontSet)
        let shaper = GraphemeShaper(fontSet: fontSet)
        let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: metrics)

        let ideograph = shaper.shape("中", cellSpan: 2)
        let enlarged = CTFontCreateCopyWithAttributes(ideograph.font, CTFontGetSize(ideograph.font) * 2, nil, nil)
        let wide = ShapedGrapheme(font: enlarged, glyphs: ideograph.glyphs, isColor: ideograph.isColor, cellSpan: 2)
        let emoji = shaper.shape("😀", cellSpan: 1)
        try #require(emoji.isColor, "the emoji came from \(emoji.fontName), not a colour font")

        for (label, grapheme, span) in [("中 at twice its size in two cells", wide, 2), ("😀 in one cell", emoji, 1)] {
            let glyph = try #require(rasterizer.rasterize(grapheme), "\(label) drew nothing")
            let inkWidth = glyph.width - 2 * rasterizer.padding
            #expect(glyph.appliedScale < 1, "\(label) was not scaled")
            #expect(inkWidth <= metrics.width * span,
                    "\(label) is \(inkWidth) px wide, past its \(metrics.width * span) px")
        }
    }

    /// Narrow text is scaled only past twice its cell, which takes a stack of combining marks or an
    /// outsized icon. That keeps every bitmap bounded. Here Menlo's own W, drawn at three times its
    /// size, stands in for one.
    @Test(.enabled(if: monacoAndMenlo, monacoOrMenloMissing))
    func narrowTextIsScaledPastTwiceItsCell() throws {
        let fontSet = FontSet(font: try #require(NSFont(name: "Menlo", size: 12)), scale: 2)
        let metrics = CellMetrics(fontSet: fontSet)
        let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: metrics)
        let shaped = GraphemeShaper(fontSet: fontSet).shape("W")
        let regular = fontSet.font(for: .regular)
        let tripled = ShapedGrapheme(font: CTFontCreateCopyWithAttributes(regular, CTFontGetSize(regular) * 3, nil, nil),
                                     glyphs: shaped.glyphs, isColor: false, cellSpan: 1)

        let glyph = try #require(rasterizer.rasterize(tripled), "the enlarged W drew nothing")
        let inkWidth = glyph.width - 2 * rasterizer.padding
        let limit = Int(GlyphRasterizer.narrowTextOverhang) * metrics.width
        #expect(glyph.appliedScale < 1, "a W three times its size was not scaled")
        #expect(inkWidth <= limit, "the enlarged W is \(inkWidth) px wide, past twice its cell, \(limit) px")
    }

    // MARK: - Placing glyphs in their cells

    /// A wide glyph is centred in its two cells by its advance, rounded to a whole pixel, so the
    /// slack between a CJK ideograph's advance and its two cells is split evenly rather than all
    /// left on its right. A narrow glyph stays at its cell's left edge.
    @Test(.enabled(if: monacoAndMenlo, monacoOrMenloMissing))
    func aWideGlyphIsCentredInItsTwoCellsAndANarrowOneIsNot() throws {
        let fontSet = FontSet(font: try #require(NSFont(name: "Menlo", size: 12)), scale: 2)
        let metrics = CellMetrics(fontSet: fontSet)
        let shaper = GraphemeShaper(fontSet: fontSet)
        let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: metrics)

        let ideograph = shaper.shape("中", cellSpan: 2)
        let wide = try #require(rasterizer.rasterize(ideograph), "中 drew nothing")
        let wideScale: CGFloat = wide.appliedScale
        try #require(wideScale == 1, "中 was scaled by \(wideScale), which this case does not cover")
        let advance = advanceWidth(of: ideograph)
        let offset = Int(((CGFloat(metrics.width * 2) - advance) / 2).rounded())
        try #require(offset > 0, "中's \(advance) px advance leaves no slack in its \(metrics.width * 2) px cells")
        let wideBearing: Int = wide.bearingX
        let centred: Int = naturalBearingX(of: ideograph, padding: rasterizer.padding) + offset
        #expect(wideBearing == centred,
                "中 starts \(wideBearing) px from its cells' left edge, not \(centred): its \(advance) px advance is not centred")

        // A narrow glyph whose advance is far from its cell's width, so centring would move it.
        let corner = shaper.shape("\u{23BF}", cellSpan: 1)
        let narrow = try #require(rasterizer.rasterize(corner), "U+23BF drew nothing")
        let narrowScale: CGFloat = narrow.appliedScale
        try #require(narrowScale == 1, "U+23BF was scaled by \(narrowScale), which this case does not cover")
        let cornerAdvance = advanceWidth(of: corner)
        let wouldMove = Int(((CGFloat(metrics.width) - cornerAdvance) / 2).rounded())
        try #require(wouldMove != 0,
                     "U+23BF's \(cornerAdvance) px advance is too close to its \(metrics.width) px cell for centring to move it")
        let narrowBearing: Int = narrow.bearingX
        let natural: Int = naturalBearingX(of: corner, padding: rasterizer.padding)
        #expect(narrowBearing == natural,
                "U+23BF starts \(narrowBearing) px from its cell's left edge, not \(natural): a narrow glyph was moved")
    }
}

/// One set of raw metrics for `CellMetrics.swiftTermGrid` and the cell SwiftTerm makes of them.
struct SwiftTermCase: Sendable, CustomTestStringConvertible {
    let advance: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    let scale: CGFloat
    /// `[width, height, baseline]` in device pixels.
    let swiftTerm: [Int]

    var testDescription: String { "advance \(advance) px at \(scale)x" }
}

/// SwiftTerm's `computeFontDimensions` and `CellGeometry.baselineOffset` (MIT, Copyright (c)
/// 2019-2026 Miguel de Icaza), done the way SwiftTerm does them: in points on the point-size
/// `NSFont`, then snapped to device pixels. Returns `[width, height, baseline]` in device pixels,
/// the baseline measured down from the cell's top.
private func swiftTermCell(_ font: NSFont, scale: CGFloat) -> [Int] {
    let ctFont = font as CTFont
    let ascent = CTFontGetAscent(ctFont)
    let descent = CTFontGetDescent(ctFont)
    let leading = CTFontGetLeading(ctFont)
    let cellWidth = font.advancement(forGlyph: font.glyph(withName: "W")).width
    // computeFontDimensions' cell height and baselineOffset's natural height are the same sum.
    let naturalHeight = ceil(ascent + descent + leading)
    let snappedWidth = (cellWidth * scale).rounded() / scale
    let snappedHeight = ceil(naturalHeight * scale) / scale
    let extra = max(0, snappedHeight - naturalHeight)
    let baselineFromBottom = ceil(descent + leading) + floor(extra / 2)
    return [Int((snappedWidth * scale).rounded()),
            Int((snappedHeight * scale).rounded()),
            Int(((snappedHeight - baselineFromBottom) * scale).rounded())]
}

/// The cluster's advance in device pixels: the right edge of its furthest-reaching glyph.
private func advanceWidth(of shaped: ShapedGrapheme) -> CGFloat {
    let glyphIDs = shaped.glyphs.map(\.glyph)
    var advances = [CGSize](repeating: .zero, count: glyphIDs.count)
    _ = CTFontGetAdvancesForGlyphs(shaped.font, .horizontal, glyphIDs, &advances, glyphIDs.count)
    return zip(shaped.glyphs, advances).reduce(CGFloat(0)) { max($0, $1.0.xOffset + $1.1.width) }
}

/// Where an unscaled glyph's bitmap starts with no centring: its ink's left edge, floored, less
/// the rasterizer's padding.
private func naturalBearingX(of shaped: ShapedGrapheme, padding: Int) -> Int {
    let glyphIDs = shaped.glyphs.map(\.glyph)
    var bounds = [CGRect](repeating: .zero, count: glyphIDs.count)
    _ = CTFontGetBoundingRectsForGlyphs(shaped.font, .horizontal, glyphIDs, &bounds, glyphIDs.count)
    var union = CGRect.null
    for (glyph, rect) in zip(shaped.glyphs, bounds) where !rect.isNull && !rect.isEmpty {
        union = union.union(rect.offsetBy(dx: glyph.xOffset, dy: glyph.yOffset))
    }
    return Int(union.minX.rounded(.down)) - padding
}
