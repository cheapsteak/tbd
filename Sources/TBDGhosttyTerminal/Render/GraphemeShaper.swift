// Adapted from tkzmux c961533 Sources/TkzTerminalRender/GraphemeShaper.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// GraphemeShaper — grapheme cluster → glyphs.
//
// A terminal shapes *per cell*, never across cells, so there are no ligatures in v1: `fi`, `->` and
// `==` stay separate glyphs because they are separate grapheme clusters and are shaped separately.
// `kCTLigatureAttributeName = 0` is set on the CTLine path as well, belt and braces.
//
// Single-scalar BMP clusters take the cheap `CTFontGetGlyphsForCharacters` path. Anything else —
// non-BMP scalars (emoji), ZWJ sequences, VS16, combining marks — goes through a one-line CTLine,
// because `CTFontGetGlyphsForCharacters` does not handle surrogate pairs or reordering.

import CoreText
import Foundation

/// One positioned glyph inside a shaped grapheme. Offsets are device pixels from the cluster's pen
/// origin (baseline left), y positive up.
struct ShapedGlyph: Sendable, Equatable {
    let glyph: CGGlyph
    let xOffset: CGFloat
    let yOffset: CGFloat

    init(glyph: CGGlyph, xOffset: CGFloat = 0, yOffset: CGFloat = 0) {
        self.glyph = glyph
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}

/// The result of shaping one grapheme cluster.
struct ShapedGrapheme {
    /// The font that actually carries the glyphs (may be a CoreText fallback, not the primary face).
    let font: CTFont
    /// Positioned glyphs, in draw order.
    let glyphs: [ShapedGlyph]
    /// True when `font` is a colour font and the result belongs in the BGRA atlas.
    let isColor: Bool
    /// How many terminal cells the cluster occupies (1 or 2).
    let cellSpan: Int
    /// True when every glyph id is 0 — the cluster has no coverage anywhere.
    var isEmpty: Bool { glyphs.isEmpty || glyphs.allSatisfy { $0.glyph == 0 } }

    /// PostScript name of the resolved font; handy in tests and dumps.
    var fontName: String { CTFontCopyPostScriptName(font) as String }
}

/// Shapes grapheme clusters with a `FontSet`, caching by codepoint array + style.
///
/// Not `Sendable` (holds `CTFont`s); owned by the renderer on the render thread.
final class GraphemeShaper {
    let fontSet: FontSet

    private struct Key: Hashable {
        let scalars: [UInt32]
        let style: FontStyle
        let span: Int
    }
    private var cache: [Key: ShapedGrapheme] = [:]

    init(fontSet: FontSet) {
        self.fontSet = fontSet
    }

    /// Number of cached clusters (test/diagnostic hook).
    var cachedCount: Int { cache.count }

    func clearCache() { cache.removeAll(keepingCapacity: true) }

    // MARK: - Shaping

    /// Shapes a grapheme cluster.
    /// - Parameter cellSpan: how many cells the terminal assigned the cluster. In production this
    ///   comes from libghostty's `WIDE` flag; when `nil` a Unicode-property heuristic is used.
    func shape(_ scalars: [Unicode.Scalar],
               style: FontStyle = .regular,
               cellSpan: Int? = nil) -> ShapedGrapheme {
        let span = cellSpan ?? GraphemeShaper.defaultCellSpan(for: scalars)
        let key = Key(scalars: scalars.map(\.value), style: style, span: span)
        if let cached = cache[key] { return cached }

        let shaped = shapeUncached(scalars, style: style, span: span)
        cache[key] = shaped
        return shaped
    }

    /// Convenience for a Swift `Character` (already a grapheme cluster).
    func shape(_ character: Character,
               style: FontStyle = .regular,
               cellSpan: Int? = nil) -> ShapedGrapheme {
        shape(Array(character.unicodeScalars), style: style, cellSpan: cellSpan)
    }

    private func shapeUncached(_ scalars: [Unicode.Scalar],
                               style: FontStyle,
                               span: Int) -> ShapedGrapheme {
        let primary = fontSet.font(for: scalars, style: style)

        // Fast path: one BMP scalar — no surrogate pair, no reordering, no marks.
        if scalars.count == 1, scalars[0].value <= 0xFFFF {
            var chars = [UniChar(scalars[0].value)]
            var glyphs = [CGGlyph](repeating: 0, count: 1)
            if CTFontGetGlyphsForCharacters(primary, &chars, &glyphs, 1), glyphs[0] != 0 {
                return ShapedGrapheme(font: primary,
                                      glyphs: [ShapedGlyph(glyph: glyphs[0])],
                                      isColor: fontSet.isColorFont(primary),
                                      cellSpan: span)
            }
        }

        return shapeWithCTLine(scalars, primary: primary, span: span)
    }

    private func shapeWithCTLine(_ scalars: [Unicode.Scalar],
                                 primary: CTFont,
                                 span: Int) -> ShapedGrapheme {
        var text = ""
        for scalar in scalars { text.unicodeScalars.append(scalar) }

        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: primary,
            // No ligatures in v1.
            kCTLigatureAttributeName as NSAttributedString.Key: NSNumber(value: 0),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let firstRun = runs.first else {
            return ShapedGrapheme(font: primary, glyphs: [], isColor: fontSet.isColorFont(primary),
                                  cellSpan: span)
        }

        // The font that actually shaped the text is the first run's, not necessarily `primary`.
        let runFont = GraphemeShaper.font(of: firstRun) ?? primary

        var result: [ShapedGlyph] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                result.append(ShapedGlyph(glyph: glyphs[i],
                                          xOffset: positions[i].x,
                                          yOffset: positions[i].y))
            }
        }

        return ShapedGrapheme(font: runFont,
                              glyphs: result,
                              isColor: fontSet.isColorFont(runFont),
                              cellSpan: span)
    }

    private static func font(of run: CTRun) -> CTFont? {
        guard let attributes = CTRunGetAttributes(run) as? [String: Any] else { return nil }
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        // CTFont is toll-free-bridged into the attribute dictionary.
        return (value as! CTFont)  // swiftlint:disable:this force_cast
    }

    // MARK: - Cell span heuristic

    /// Best-effort East-Asian-Width / emoji width, used when the caller has no `WIDE` flag from the
    /// VT (tests, headless dumps). libghostty is authoritative in the renderer.
    static func defaultCellSpan(for scalars: [Unicode.Scalar]) -> Int {
        guard let first = scalars.first else { return 1 }

        // An explicit VS16 forces emoji presentation, which is double width.
        if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        // A ZWJ sequence renders as one double-width emoji.
        if scalars.contains(where: { $0.value == 0x200D }) { return 2 }

        if first.properties.isEmojiPresentation { return 2 }
        return isWideScalar(first) ? 2 : 1
    }

    /// East Asian Wide (W) and Fullwidth (F) ranges, condensed. Not a full UAX #11 table — the VT
    /// owns that; this only has to be right for tests and offline tooling.
    static func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        switch v {
        case 0x1100...0x115F,      // Hangul Jamo init. consonants
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,      // Hiragana … CJK compatibility
             0x3400...0x4DBF,      // CJK ext A
             0x4E00...0x9FFF,      // CJK unified ideographs
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE10...0xFE19,      // vertical forms
             0xFE30...0xFE6F,      // CJK compatibility forms
             0xFF00...0xFF60,      // fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,    // emoji blocks
             0x1F900...0x1F9FF,
             0x20000...0x2FFFD,    // CJK ext B…
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
