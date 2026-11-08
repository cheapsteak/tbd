// Adapted from tkzmux c961533 Sources/TkzTerminalRender/FontSet.swift (MIT, see LICENSE-tkzmux.txt). Takes an NSFont; no bundled faces.
// FontSet — CoreText font resolution for the terminal grid.
//
// TBD bundles no fonts: the caller hands in the `NSFont` it already shows terminals in, and this
// builds that face plus its bold, italic and bold-italic siblings at device-pixel size.

import AppKit
import CoreText
import Foundation

/// The four faces a terminal draws with.
enum FontStyle: UInt8, CaseIterable, Sendable, Hashable {
    case regular, bold, italic, boldItalic

    var isBold: Bool { self == .bold || self == .boldItalic }
    var isItalic: Bool { self == .italic || self == .boldItalic }

    init(bold: Bool, italic: Bool) {
        switch (bold, italic) {
        case (false, false): self = .regular
        case (true, false): self = .bold
        case (false, true): self = .italic
        case (true, true): self = .boldItalic
        }
    }

    var symbolicTraits: CTFontSymbolicTraits {
        var traits: CTFontSymbolicTraits = []
        if isBold { traits.insert(.boldTrait) }
        if isItalic { traits.insert(.italicTrait) }
        return traits
    }
}

/// A resolved family of faces at one point size and backing scale.
///
/// Not `Sendable`: `CTFont` is a CoreFoundation type without concurrency guarantees. The renderer
/// owns one `FontSet` on the main thread; tests create their own.
final class FontSet {
    /// The family of the font that was handed in.
    let resolvedFamily: String
    /// Point size in *points* (not device pixels).
    let pointSize: CGFloat
    /// Backing scale (2.0 on Retina).
    let scale: CGFloat
    /// Point size the `CTFont`s are actually built at: `pointSize * scale`, so rasterization is
    /// pixel-exact and every metric is already in device pixels.
    let pixelSize: CGFloat

    /// True when the family has no real bold face and bold must be synthesized (fill + stroke).
    let needsSyntheticBold: Bool
    /// True when an italic face had to be made by slanting an upright one by
    /// `syntheticItalicSkew`, because the family has no such face.
    let needsSyntheticItalic: Bool

    /// The slant of a synthesized italic, in radians from the vertical: the shear a face's
    /// matrix gets when the family has no italic of its own.
    static let syntheticItalicSkew: CGFloat = 0.2

    private let faces: [FontStyle: CTFont]
    private let regular: CTFont
    /// CTFont construction goes through one XPC connection; keep every construction on one side
    /// of this lock.
    private static let coreTextLock = NSLock()

    /// Per-scalar fallback cache: scalar+style → the font CoreText picked for it.
    private var fallbackCache: [FallbackKey: CTFont] = [:]
    private var colorFontCache: [String: Bool] = [:]

    private struct FallbackKey: Hashable {
        let scalar: UInt32
        let style: FontStyle
    }

    // MARK: - Init

    /// - Parameters:
    ///   - font: the regular face, at the point size terminals are shown in.
    ///   - scale: backing scale factor; faces are built at `font.pointSize * scale`.
    init(font: NSFont, scale: CGFloat) {
        let pointSize = max(font.pointSize, 1)
        let scale = max(scale, 1)
        self.pointSize = pointSize
        self.scale = scale
        let pixelSize = pointSize * scale
        self.pixelSize = pixelSize

        FontSet.coreTextLock.lock()
        let base = CTFontCreateCopyWithAttributes(font as CTFont, pixelSize, nil, nil)
        var faces: [FontStyle: CTFont] = [.regular: base]
        var syntheticBold = false
        var syntheticItalic = false
        // `allCases` runs bold and italic before bold italic, which builds on them.
        for style in FontStyle.allCases where style != .regular {
            if let face = CTFontCreateCopyWithSymbolicTraits(
                base, pixelSize, nil, style.symbolicTraits, style.symbolicTraits) {
                faces[style] = face
                continue
            }
            // The family has no such face.
            switch style {
            case .regular:
                break
            case .bold:
                // The regular face, which the rasterizer strokes heavier.
                syntheticBold = true
                faces[style] = base
            case .italic:
                syntheticItalic = true
                faces[style] = FontSet.slanted(base, pixelSize: pixelSize)
            case .boldItalic:
                if syntheticBold {
                    // No bold to slant: the italic face, real or slanted, stroked heavier.
                    faces[style] = faces[.italic] ?? base
                } else {
                    syntheticItalic = true
                    faces[style] = FontSet.slanted(faces[.bold] ?? base, pixelSize: pixelSize)
                }
            }
        }
        let family = CTFontCopyFamilyName(base) as String
        FontSet.coreTextLock.unlock()

        self.resolvedFamily = family
        self.regular = base
        self.faces = faces
        self.needsSyntheticBold = syntheticBold
        self.needsSyntheticItalic = syntheticItalic
    }

    /// `face` sheared by `syntheticItalicSkew`: the top of each glyph leans right. Caller holds
    /// `coreTextLock`.
    private static func slanted(_ face: CTFont, pixelSize: CGFloat) -> CTFont {
        var skew = CGAffineTransform(a: 1, b: 0, c: tan(syntheticItalicSkew), d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(face, pixelSize, &skew, nil)
    }

    // MARK: - Lookup

    /// The face for `style`. When the family lacks that face this is the regular face, or a
    /// slanted copy of an upright one; see `needsSyntheticBold` and `needsSyntheticItalic`.
    func font(for style: FontStyle) -> CTFont {
        faces[style] ?? regular
    }

    /// PostScript name of a face.
    func postScriptName(for style: FontStyle) -> String {
        CTFontCopyPostScriptName(font(for: style)) as String
    }

    /// The font that can draw `codepoints`, following CoreText's cascade list when the primary
    /// face has no glyph. Results are cached per (first scalar, style).
    func font(for codepoints: [Unicode.Scalar], style: FontStyle = .regular) -> CTFont {
        let primary = font(for: style)
        guard let first = codepoints.first else { return primary }

        let key = FallbackKey(scalar: first.value, style: style)
        if codepoints.count == 1, let cached = fallbackCache[key] { return cached }

        var utf16: [UniChar] = []
        for scalar in codepoints { utf16.append(contentsOf: Array(String(scalar).utf16)) }
        let string = String(decoding: utf16, as: UTF16.self) as CFString
        FontSet.coreTextLock.lock()
        let resolved = CTFontCreateForString(primary, string, CFRange(location: 0, length: utf16.count))
        FontSet.coreTextLock.unlock()

        if codepoints.count == 1 { fallbackCache[key] = resolved }
        return resolved
    }

    /// Convenience for a single scalar.
    func font(for scalar: Unicode.Scalar, style: FontStyle = .regular) -> CTFont {
        font(for: [scalar], style: style)
    }

    /// True when `font` carries colour glyph tables (Apple Color Emoji and friends), which must be
    /// rasterized into the BGRA atlas rather than the alpha one.
    func isColorFont(_ font: CTFont) -> Bool {
        let key = CTFontCopyPostScriptName(font) as String
        if let cached = colorFontCache[key] { return cached }
        let value = CTFontGetSymbolicTraits(font).contains(.colorGlyphsTrait)
        colorFontCache[key] = value
        return value
    }
}
