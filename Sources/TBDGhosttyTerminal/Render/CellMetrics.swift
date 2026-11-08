// Adapted from tkzmux c961533 Sources/TkzTerminalRender/CellMetrics.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// CellMetrics — integer terminal cell geometry in device pixels.
//
// Everything here is device pixels at the `FontSet`'s scale, because `FontSet` builds its `CTFont`s
// at `pointSize * scale`. All values are integral and deterministic for a given (family, size, scale),
// so a regression in font handling shows up as a changed number rather than a blurry frame.
//
// The cell width, height and baseline are SwiftTerm's (`swiftTermGrid`), so a libghostty terminal
// lays out the same columns and rows, with text on the same baseline, as a SwiftTerm terminal in the
// same pane.
//
// Vertical convention: y grows *downward* (screen space). `baseline` is the distance from the top of
// the cell to the text baseline. Decoration offsets are relative to the baseline, positive downward —
// so `underlineOffset` is positive (below the baseline) and `strikethroughOffset` is negative.

import CoreText
import Foundation

struct CellMetrics: Sendable, Equatable, Hashable {
    /// Cell width: the advance of `W`, rounded to the nearest device pixel.
    let width: Int
    /// Cell height: `ascent + descent + leading` rounded up to a whole point, in device pixels.
    let height: Int
    /// Rounded font ascent.
    let ascent: Int
    /// Rounded font descent.
    let descent: Int
    /// Rounded font leading (line gap).
    let leading: Int
    /// Distance from the top of the cell down to the baseline, which sits `ceil(descent + leading)`
    /// points above the cell's bottom.
    let baseline: Int
    /// Underline centre, relative to the baseline, positive downward.
    let underlineOffset: Int
    /// Underline thickness, at least 1 px.
    let underlineThickness: Int
    /// Strikethrough centre, relative to the baseline, positive downward (normally negative).
    let strikethroughOffset: Int
    /// Strikethrough thickness, at least 1 px.
    let strikethroughThickness: Int
    /// Backing scale the metrics were measured at.
    let scale: CGFloat

    /// Width of a double-width (wide) grapheme's box.
    var wideWidth: Int { width * 2 }

    // MARK: - Measurement

    /// Measures the regular face of `fontSet`.
    init(fontSet: FontSet) {
        self.init(font: fontSet.font(for: .regular), scale: fontSet.scale)
    }

    /// Measures a `CTFont` that is already sized in device pixels.
    init(font: CTFont, scale: CGFloat) {
        let ascentF = CTFontGetAscent(font)
        let descentF = CTFontGetDescent(font)
        let leadingF = CTFontGetLeading(font)

        self.ascent = Int(ascentF.rounded())
        self.descent = Int(descentF.rounded())
        self.leading = Int(leadingF.rounded())
        let grid = CellMetrics.swiftTermGrid(advance: CellMetrics.cellAdvance(of: font),
                                             ascent: ascentF, descent: descentF, leading: leadingF,
                                             scale: scale)
        self.width = grid.width
        self.height = grid.height
        self.baseline = grid.baseline
        self.scale = scale

        // Underline: CoreText reports position relative to the baseline, positive *up*.
        let underlinePos = CTFontGetUnderlinePosition(font)
        let underlineThick = CTFontGetUnderlineThickness(font)
        self.underlineThickness = max(1, Int(underlineThick.rounded()))
        self.underlineOffset = Int((-underlinePos).rounded())

        // Strikethrough: CoreText has no accessor, so read OS/2 (`yStrikeoutSize` at byte 26,
        // `yStrikeoutPosition` at 28, both big-endian int16 in font units, positive up).
        let strike = CellMetrics.strikeout(of: font)
        self.strikethroughThickness = max(1, Int(strike.thickness.rounded()))
        self.strikethroughOffset = Int((-strike.position).rounded())
    }

    // MARK: - SwiftTerm's grid
    //
    // Adapted from SwiftTerm (MIT, Copyright (c) 2019-2026 Miguel de Icaza), cheapsteak/SwiftTerm
    // b4db5b0, Sources/SwiftTerm/Apple/AppleTerminalView.swift: `computeFontDimensions` and
    // `CellGeometry.baselineOffset`. The arithmetic is copied, not approximated: any difference
    // shows up as a column or row more or fewer than a SwiftTerm terminal in the same pane.

    /// SwiftTerm's cell width, height and baseline, in device pixels, from metrics measured on a
    /// font built at `pointSize * scale`.
    ///
    /// SwiftTerm does its arithmetic in points and snaps to device pixels at the end, so the
    /// metrics go back to points first. Dividing loses nothing at a backing scale of 1 or 2, a
    /// power of two, for a font whose metrics are linear in its size, as SF Mono's, Monaco's and
    /// Menlo's are. A font with an optical-size axis is not: CoreText measures the device-pixel
    /// copy at a larger optical size than SwiftTerm's point-size font. Then:
    ///
    /// - **Width** – `(advance * scale).rounded() / scale` points: the advance, rounded to the
    ///   nearest device pixel. `advance` here is already that product.
    /// - **Height** – `ceil(ascent + descent + leading)` points, then rounded up to a device pixel.
    ///   A whole number of points, so Monaco 12 pt's 16.002 pt line gets a 17 pt, 34 px row.
    ///   SwiftTerm multiplies the sum by its `lineSpacing`, which TBD leaves at 1.
    /// - **Baseline** – `ceil(descent + leading) + floor(extra / 2)` points above the cell's bottom,
    ///   where `extra` is how much taller the snapped cell is than the line rounded up to a point.
    static func swiftTermGrid(advance: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat,
                              scale: CGFloat) -> (width: Int, height: Int, baseline: Int) {
        let scale = max(scale, 1)
        let ascent = ascent / scale
        let descent = descent / scale
        let leading = leading / scale

        // computeFontDimensions, whose `cellHeight` is this natural height times `lineSpacing`.
        let naturalHeight = ceil(ascent + descent + leading)
        let snappedHeight = ceil(naturalHeight * scale) / scale

        // CellGeometry.baselineOffset
        let extra = max(0, snappedHeight - naturalHeight)
        let baselineFromBottom = ceil(descent + leading) + floor(extra / 2)

        let width = max(1, Int(advance.rounded()))
        let height = max(1, Int((snappedHeight * scale).rounded()))
        return (width, height, height - Int((baselineFromBottom * scale).rounded()))
    }

    /// The advance SwiftTerm sizes its cells by: that of the glyph named `W`, looked up by name as
    /// SwiftTerm looks it up. A face with no glyph of that name gets glyph 0, `.notdef`, as in
    /// SwiftTerm. Only if that advance is zero, where SwiftTerm would fall to its 1 pt minimum and
    /// lay out an unusable grid, does this take the widest printable-ASCII advance instead.
    static func cellAdvance(of font: CTFont) -> CGFloat {
        var glyph = CTFontGetGlyphWithName(font, "W" as CFString)
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width > 0 ? advance.width : maxASCIIAdvance(of: font)
    }

    /// Max horizontal advance over printable ASCII (U+0020…U+007E).
    static func maxASCIIAdvance(of font: CTFont) -> CGFloat {
        let chars: [UniChar] = (0x20...0x7E).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count) else {
            // A face missing some ASCII glyph: measure what we can, zeros contribute nothing.
            return CellMetrics.advanceMax(font: font, glyphs: glyphs)
        }
        return CellMetrics.advanceMax(font: font, glyphs: glyphs)
    }

    private static func advanceMax(font: CTFont, glyphs: [CGGlyph]) -> CGFloat {
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.reduce(CGFloat(0)) { max($0, $1.width) }
    }

    /// Strikeout size and position in device pixels, positive up. Falls back to half the x-height
    /// and the underline thickness when the font has no usable OS/2 table.
    static func strikeout(of font: CTFont) -> (position: CGFloat, thickness: CGFloat) {
        let fallback = (position: CTFontGetXHeight(font) / 2,
                        thickness: max(1, CTFontGetUnderlineThickness(font)))
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) else {
            return fallback
        }
        let length = CFDataGetLength(table)
        guard length >= 30, let bytes = CFDataGetBytePtr(table) else { return fallback }
        func int16(at offset: Int) -> Int16 {
            Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
        }
        let unitsPerEm = CGFloat(CTFontGetUnitsPerEm(font))
        guard unitsPerEm > 0 else { return fallback }
        let pixelsPerUnit = CTFontGetSize(font) / unitsPerEm
        let size = CGFloat(int16(at: 26)) * pixelsPerUnit
        let position = CGFloat(int16(at: 28)) * pixelsPerUnit
        guard size > 0 else { return fallback }
        return (position: position, thickness: size)
    }
}
