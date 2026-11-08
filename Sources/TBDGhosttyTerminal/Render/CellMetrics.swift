// Adapted from tkzmux c961533 Sources/TkzTerminalRender/CellMetrics.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// CellMetrics — integer terminal cell geometry in device pixels.
//
// Everything here is device pixels at the `FontSet`'s scale, because `FontSet` builds its `CTFont`s
// at `pointSize * scale`. All values are integral and deterministic for a given (family, size, scale),
// so a regression in font handling shows up as a changed number rather than a blurry frame.
//
// Vertical convention: y grows *downward* (screen space). `baseline` is the distance from the top of
// the cell to the text baseline. Decoration offsets are relative to the baseline, positive downward —
// so `underlineOffset` is positive (below the baseline) and `strikethroughOffset` is negative.

import CoreText
import Foundation

struct CellMetrics: Sendable, Equatable, Hashable {
    /// Cell width: the widest advance over printable ASCII, rounded up.
    let width: Int
    /// Cell height: `round(ascent + descent + leading)`.
    let height: Int
    /// Rounded font ascent.
    let ascent: Int
    /// Rounded font descent.
    let descent: Int
    /// Rounded font leading (line gap).
    let leading: Int
    /// Distance from the top of the cell down to the baseline.
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
        self.height = max(1, Int((ascentF + descentF + leadingF).rounded()))
        self.baseline = Int(ascentF.rounded())
        self.width = max(1, Int(CellMetrics.maxASCIIAdvance(of: font).rounded(.up)))
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
