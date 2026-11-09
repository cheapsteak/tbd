// Adapted from tkzmux c961533 Sources/TkzTerminalRender/FontSet.swift (MIT, see LICENSE-tkzmux.txt). Takes an NSFont; no bundled faces.
// FontSet — CoreText font resolution for the terminal grid.
//
// TBD bundles no fonts: the caller hands in the `NSFont` it already shows terminals in, and this
// builds that face plus its bold, italic and bold-italic siblings at device-pixel size.
//
// The siblings are the faces SwiftTerm draws with, found the way SwiftTerm finds them, and nothing
// is synthesized: a family with no bold face draws bold at its regular weight, and one with no
// italic draws italic upright, as in a SwiftTerm terminal. Monaco, TBD's default font, has only a
// regular face, so all four of its styles are that face.

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

    /// The traits `NSFontManager` is asked to add to the regular face for this style.
    var fontTraitMask: NSFontTraitMask {
        var mask: NSFontTraitMask = []
        if isBold { mask.insert(.boldFontMask) }
        if isItalic { mask.insert(.italicFontMask) }
        return mask
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

    /// Main actor only, because the faces come from `NSFontManager`, an AppKit object SwiftTerm
    /// also uses only there.
    ///
    /// - Parameters:
    ///   - font: the regular face, at the point size terminals are shown in.
    ///   - scale: backing scale factor; faces are built at `font.pointSize * scale`.
    @MainActor
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
        // SwiftTerm's faces (adapted from SwiftTerm, MIT, Copyright (c) 2019-2026 Miguel de Icaza,
        // Sources/SwiftTerm/Mac/MacTerminalView.swift `FontSet.init` at cheapsteak/SwiftTerm
        // b4db5b0): the font converted to have the style's traits, which `NSFontManager` returns
        // unchanged when the family has no face with all of them. So Monaco's bold is Monaco
        // regular, and PT Mono's bold italic is PT Mono regular, though PT Mono has a bold.
        // CoreText's own trait lookup, `CTFontCreateCopyWithSymbolicTraits`, agrees for Monaco,
        // Menlo, SF Mono, Courier, PT Mono and Andale Mono, but over the 660 faces of one Mac's
        // installed fonts it picked a different face for 140 of the 1,980 styles, Hiragino Sans'
        // bold among them, so it is not used.
        for style in FontStyle.allCases where style != .regular {
            let face = NSFontManager.shared.convert(font, toHaveTrait: style.fontTraitMask)
            faces[style] = CTFontCreateCopyWithAttributes(face as CTFont, pixelSize, nil, nil)
        }
        let family = CTFontCopyFamilyName(base) as String
        FontSet.coreTextLock.unlock()

        self.resolvedFamily = family
        self.regular = base
        self.faces = faces
    }

    // MARK: - Lookup

    /// The face for `style`: the regular face itself when the family has no face for it.
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
