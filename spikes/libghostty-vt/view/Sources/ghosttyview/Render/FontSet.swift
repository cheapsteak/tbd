// Adapted from tkzmux c961533 Sources/TkzTerminalRender/FontSet.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// FontSet — CoreText font resolution for the terminal grid (M1.4).
//
// The bundled JetBrains Mono faces live in `Bundle.module/Fonts`. Outside an app bundle
// (`swift test`, `swift run`) nothing registers them, so `FontSet` registers the directory
// with `CTFontManagerRegisterFontsForURL(.process)` exactly once before resolving. Inside the
// built `.app` the same files are also registered at launch through `ATSApplicationFontsPath`,
// so registration must tolerate "already registered" and be idempotent.

import CoreText
import Foundation

/// The four faces a terminal draws with.
public enum FontStyle: UInt8, CaseIterable, Sendable, Hashable {
    case regular, bold, italic, boldItalic

    public var isBold: Bool { self == .bold || self == .boldItalic }
    public var isItalic: Bool { self == .italic || self == .boldItalic }

    public init(bold: Bool, italic: Bool) {
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

/// Outcome of the one-shot process registration of the bundled fonts.
public struct FontRegistration: Sendable, Equatable {
    /// The `Fonts` directory inside `Bundle.module`, if it exists.
    public let directory: URL?
    /// Font files handed to CoreText.
    public let registeredFiles: [URL]
    /// Human-readable failures (a file that neither registered nor was already registered).
    public let failures: [String]
}

/// A resolved family of faces at one point size and backing scale.
///
/// Not `Sendable`: `CTFont` is a CoreFoundation type without concurrency guarantees. The renderer
/// owns one `FontSet` on the render thread; tests create their own.
public final class FontSet {
    /// Family that was actually resolved (`family`, or `fallback` if the primary was unavailable).
    public let resolvedFamily: String
    /// True when the requested family could not be resolved and `fallback` was used.
    public let usedFallbackFamily: Bool
    /// Point size in *points* (not device pixels).
    public let pointSize: CGFloat
    /// Backing scale (2.0 on Retina).
    public let scale: CGFloat
    /// Point size the `CTFont`s are actually built at: `pointSize * scale`, so rasterization is
    /// pixel-exact and every metric is already in device pixels.
    public let pixelSize: CGFloat

    /// True when the family has no real bold face and bold must be synthesized (fill + stroke).
    public let needsSyntheticBold: Bool
    /// True when the family has no real italic face and italics must be synthesized (skew).
    public let needsSyntheticItalic: Bool

    private let faces: [FontStyle: CTFont]
    private static let coreTextLock = NSLock()

    /// Per-scalar fallback cache: scalar+style → the font CoreText picked for it.
    private var fallbackCache: [FallbackKey: CTFont] = [:]
    private var colorFontCache: [String: Bool] = [:]

    private struct FallbackKey: Hashable {
        let scalar: UInt32
        let style: FontStyle
    }

    // MARK: - Bundled font registration

    // MARK: - Init

    /// - Parameters:
    ///   - family: preferred family name, e.g. `"JetBrains Mono"`.
    ///   - fallback: family used when `family` cannot be resolved, e.g. `"Menlo"`.
    ///   - pointSize: size in points.
    ///   - scale: backing scale factor; fonts are built at `pointSize * scale`.
    public init(family: String = "JetBrains Mono",
                fallback: String = "Menlo",
                pointSize: CGFloat = 12.5,
                scale: CGFloat = 2.0) {

        self.pointSize = pointSize
        self.scale = scale
        let pixelSize = pointSize * scale
        self.pixelSize = pixelSize

        // Every CTFont *construction* below goes through the XType XPC connection; keep them all on
        // one side of the lock (see `coreTextLock`).
        FontSet.coreTextLock.lock()
        let (base, resolvedFamily, usedFallback) = FontSet.resolveBase(
            family: family, fallback: fallback, size: pixelSize)
        var faces: [FontStyle: CTFont] = [.regular: base]
        var syntheticBold = false
        var syntheticItalic = false
        for style in FontStyle.allCases where style != .regular {
            if let face = CTFontCreateCopyWithSymbolicTraits(
                base, pixelSize, nil, style.symbolicTraits, style.symbolicTraits) {
                faces[style] = face
            } else {
                faces[style] = base
                if style.isBold { syntheticBold = true }
                if style.isItalic { syntheticItalic = true }
            }
        }
        FontSet.coreTextLock.unlock()

        self.resolvedFamily = resolvedFamily
        self.usedFallbackFamily = usedFallback
        self.faces = faces
        self.needsSyntheticBold = syntheticBold
        self.needsSyntheticItalic = syntheticItalic
    }

    /// Resolves `family`, falling back to `fallback` and finally to the system monospaced font.
    ///
    /// `CTFontCreateWithName` never fails — it silently substitutes — so resolution goes through a
    /// descriptor match on `kCTFontFamilyNameAttribute`, which *does* return nil for a missing family.
    private static func resolveBase(family: String, fallback: String, size: CGFloat)
        -> (CTFont, String, Bool) {
        if let font = matchFamily(family, size: size) { return (font, family, false) }
        if let font = matchFamily(fallback, size: size) { return (font, fallback, true) }
        let system = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        let name = CTFontCopyFamilyName(system) as String
        return (system, name, true)
    }

    private static func matchFamily(_ family: String, size: CGFloat) -> CTFont? {
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(
            descriptor, nil) else { return nil }
        let font = CTFontCreateWithFontDescriptor(matched, size, nil)
        // Defensive: CoreText should not substitute here, but verify anyway.
        guard (CTFontCopyFamilyName(font) as String) == family else { return nil }
        return font
    }

    // MARK: - Lookup

    /// The face for `style` (may be the regular face when the family lacks that face — see
    /// `needsSyntheticBold` / `needsSyntheticItalic`).
    public func font(for style: FontStyle) -> CTFont {
        faces[style] ?? faces[.regular]!
    }

    /// PostScript name of a face, e.g. `"JetBrainsMono-Regular"`.
    public func postScriptName(for style: FontStyle) -> String {
        CTFontCopyPostScriptName(font(for: style)) as String
    }

    /// The font that can draw `codepoints`, following CoreText's cascade list when the primary
    /// face has no glyph. Results are cached per (first scalar, style).
    public func font(for codepoints: [Unicode.Scalar], style: FontStyle = .regular) -> CTFont {
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
    public func font(for scalar: Unicode.Scalar, style: FontStyle = .regular) -> CTFont {
        font(for: [scalar], style: style)
    }

    /// True when `font` carries colour glyph tables (Apple Color Emoji and friends), which must be
    /// rasterized into the BGRA atlas rather than the alpha one.
    public func isColorFont(_ font: CTFont) -> Bool {
        let key = CTFontCopyPostScriptName(font) as String
        if let cached = colorFontCache[key] { return cached }
        let value = CTFontGetSymbolicTraits(font).contains(.colorGlyphsTrait)
        colorFontCache[key] = value
        return value
    }
}
