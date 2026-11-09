import AppKit
import CoreText
import Foundation
import TBDGhosttyShaderTypes
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

private let monacoAndMenloInstalled = NSFont(name: "Monaco", size: 12) != nil && NSFont(name: "Menlo", size: 12) != nil
private let monacoOrMenloNotInstalled: Comment = "Monaco or Menlo is not installed"

/// Bold and italic text as SwiftTerm draws it. SwiftTerm's Core Graphics and Metal renderers build
/// their text from the same attributes, so one answer covers both: each style in the face
/// SwiftTerm's `FontSet` takes for it, filled, with nothing slanted or stroked to stand in for a
/// face the family lacks, and bold text in the bright palette colour SwiftTerm picks for it.
///
/// Main actor, because a `FontSet` is built there, as is the `NSFontManager` these tests ask which
/// face SwiftTerm draws.
@Suite(.fastPassBounded)
@MainActor
struct BoldAndItalicTests {
    // MARK: - Faces

    /// Each style is drawn in the face SwiftTerm's `FontSet.init` takes for it: the font converted
    /// by `NSFontManager` with SwiftTerm's own trait masks. That is the family's face where it has
    /// one, and the font unchanged, upright, where it has none. Covered: Menlo, which has all four
    /// faces; Monaco, TBD's default, which has only a regular one; the system monospaced font,
    /// whose bold is its semibold; and, where it is installed, PT Mono, whose bold italic is its
    /// regular face although it has a bold.
    @Test(.enabled(if: monacoAndMenloInstalled, monacoOrMenloNotInstalled))
    func eachStyleIsDrawnInTheFaceSwiftTermDrawsItIn() throws {
        var fonts: [NSFont] = [NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        for name in ["Monaco", "Menlo", "PTMono-Regular"] {
            if let font = NSFont(name: name, size: 12) { fonts.append(font) }
        }
        for font in fonts {
            let fontSet = FontSet(font: font, scale: 2)
            // SwiftTerm's three conversions, as MacTerminalView.swift spells them.
            let swiftTerm: [(style: FontStyle, face: NSFont)] = [
                (.regular, font),
                (.bold, NSFontManager.shared.convert(font, toHaveTrait: [.boldFontMask])),
                (.italic, NSFontManager.shared.convert(font, toHaveTrait: [.italicFontMask])),
                (.boldItalic, NSFontManager.shared.convert(font, toHaveTrait: [.italicFontMask, .boldFontMask])),
            ]
            for (style, face) in swiftTerm {
                let drawn: String = fontSet.postScriptName(for: style)
                let wanted: String = face.fontName
                #expect(drawn == wanted, "\(font.fontName) \(style) is drawn in \(drawn), not SwiftTerm's \(wanted)")
                // A face slanted to stand in for a missing italic carries the slant in its matrix.
                let shear: CGFloat = CTFontGetMatrix(fontSet.font(for: style)).c
                let wantedShear: CGFloat = CTFontGetMatrix(face as CTFont).c
                #expect(shear == wantedShear, "\(font.fontName) \(style)'s face is sheared by \(shear), not \(wantedShear)")
            }
        }

        // The names themselves, so the comparison above cannot pass with both sides gone wrong.
        let monaco = FontSet(font: try #require(NSFont(name: "Monaco", size: 12)), scale: 2)
        let monacoFaces: [String] = FontStyle.allCases.map { monaco.postScriptName(for: $0) }
        #expect(monacoFaces == ["Monaco", "Monaco", "Monaco", "Monaco"], "Monaco's faces are \(monacoFaces)")
        let menlo = FontSet(font: try #require(NSFont(name: "Menlo", size: 12)), scale: 2)
        let menloFaces: [String] = FontStyle.allCases.map { menlo.postScriptName(for: $0) }
        #expect(menloFaces == ["Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"],
                "Menlo's faces are \(menloFaces)")
        if let ptMonoFont = NSFont(name: "PTMono-Regular", size: 12) {
            let ptMono = FontSet(font: ptMonoFont, scale: 2)
            let ptMonoFaces: [String] = FontStyle.allCases.map { ptMono.postScriptName(for: $0) }
            #expect(ptMonoFaces == ["PTMono-Regular", "PTMono-Bold", "PTMono-Regular", "PTMono-Regular"],
                    "PT Mono's faces are \(ptMonoFaces)")
        }
    }

    /// Monaco has only a regular face, and SwiftTerm draws its bold, italic and bold italic in it:
    /// at the regular weight, upright. So does this. Every style's bitmap is the regular one, pixel
    /// for pixel, with no stroke to thicken it and no slant.
    @Test(.enabled(if: NSFont(name: "Monaco", size: 12) != nil, "Monaco is not installed"))
    func aFamilyWithOnlyARegularFaceDrawsEveryStyleAtRegularWeightUpright() throws {
        for size: CGFloat in [12, 13] {
            let fontSet = FontSet(font: try #require(NSFont(name: "Monaco", size: size)), scale: 2)
            let shaper = GraphemeShaper(fontSet: fontSet)
            let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: CellMetrics(fontSet: fontSet))
            let characters: [Character] = ["l", "@", "W", "m"]
            for character in characters {
                let regular = try #require(rasterizer.rasterize(shaper.shape(character, style: .regular)),
                                           "Monaco \(size) pt drew no \(character)")
                for style in [FontStyle.bold, .italic, .boldItalic] {
                    let styled = try #require(rasterizer.rasterize(shaper.shape(character, style: style)),
                                              "Monaco \(size) pt drew no \(style) \(character)")
                    #expect(styled == regular,
                            "Monaco \(size) pt \(style) \(character) is not its regular glyph: \(styled.width) × \(styled.height) px with \(ink(styled)) ink, against \(regular.width) × \(regular.height) px with \(ink(regular))")
                }
            }
        }
    }

    /// Menlo has a bold face, and bold is drawn in it as it is, filled and never stroked: a bold
    /// glyph is pixel for pixel the one Menlo Bold draws as a terminal's regular font, and it is
    /// not the regular glyph.
    @Test(.enabled(if: monacoAndMenloInstalled, monacoOrMenloNotInstalled))
    func aFamilyWithABoldFaceDrawsBoldInThatFaceWithNoStroke() throws {
        let menlo = FontSet(font: try #require(NSFont(name: "Menlo", size: 12)), scale: 2)
        let menloBold = FontSet(font: try #require(NSFont(name: "Menlo-Bold", size: 12)), scale: 2)
        let shaper = GraphemeShaper(fontSet: menlo)
        let boldShaper = GraphemeShaper(fontSet: menloBold)
        let rasterizer = GlyphRasterizer(fontSet: menlo, metrics: CellMetrics(fontSet: menlo))
        let boldRasterizer = GlyphRasterizer(fontSet: menloBold, metrics: CellMetrics(fontSet: menloBold))
        let characters: [Character] = ["l", "@", "W"]
        for character in characters {
            let bold = try #require(rasterizer.rasterize(shaper.shape(character, style: .bold)),
                                    "Menlo drew no bold \(character)")
            let regular = try #require(rasterizer.rasterize(shaper.shape(character, style: .regular)),
                                       "Menlo drew no \(character)")
            let face = try #require(boldRasterizer.rasterize(boldShaper.shape(character, style: .regular)),
                                    "Menlo Bold drew no \(character)")
            #expect(bold == face,
                    "Menlo's bold \(character) is not Menlo Bold's: \(ink(bold)) ink against \(ink(face))")
            #expect(bold != regular, "Menlo's bold \(character) is its regular glyph")
        }
    }

    // MARK: - Colour

    /// Bold text is drawn in the colour SwiftTerm draws it in. SwiftTerm, with `useBrightColors`
    /// on as TBD leaves it, moves palette entries 0 to 6 to their bright twins 8 to 14 for bold
    /// text, and changes nothing else: not palette 7, not a bright or 256-colour entry, not the
    /// default foreground, and never the background. Under SGR 7 it is the colour the text takes
    /// after the swap that brightens.
    @Test(arguments: [
        BoldColorCase(sgr: "31", text: .palette(1), background: .defaultBackground),
        BoldColorCase(sgr: "1;31", text: .palette(9), background: .defaultBackground),
        BoldColorCase(sgr: "1;30", text: .palette(8), background: .defaultBackground),
        BoldColorCase(sgr: "1;36", text: .palette(14), background: .defaultBackground),
        BoldColorCase(sgr: "1;37", text: .palette(7), background: .defaultBackground),
        BoldColorCase(sgr: "1;91", text: .palette(9), background: .defaultBackground),
        BoldColorCase(sgr: "1;38;5;3", text: .palette(11), background: .defaultBackground),
        BoldColorCase(sgr: "1;38;5;100", text: .palette(100), background: .defaultBackground),
        BoldColorCase(sgr: "1", text: .defaultForeground, background: .defaultBackground),
        BoldColorCase(sgr: "1;32;44", text: .palette(10), background: .palette(4)),
        BoldColorCase(sgr: "1;7;32;44", text: .palette(12), background: .palette(2)),
        BoldColorCase(sgr: "1;7;32", text: .defaultBackground, background: .palette(2)),
        BoldColorCase(sgr: "1;7;44", text: .palette(12), background: .defaultForeground),
    ])
    func boldTextIsDrawnInSwiftTermsColour(_ given: BoldColorCase) throws {
        try withOneCellFrame("\u{1b}[\(given.sgr)mX") { surface in
            let colors = surface.colors
            let anchored = surface.glyphInstances().first { $0.gridPos.x == 0 && $0.gridPos.y == 0 }
            let glyph = try #require(anchored, "no glyph was built for the X")
            let text: UInt32 = glyph.color
            let wantedText: UInt32 = given.text.packed(colors)
            #expect(text == wantedText,
                    "SGR \(given.sgr) text is \(hex(text)), not \(given.text), \(hex(wantedText))")
            let background: UInt32 = glyph.bgColor
            let wantedBackground: UInt32 = given.background.packed(colors)
            #expect(background == wantedBackground,
                    "SGR \(given.sgr) background is \(hex(background)), not \(given.background), \(hex(wantedBackground))")
        }
    }

    /// A bold cell's underline colour (SGR 58) brightens by the same rule as its text, as in
    /// SwiftTerm.
    @Test(arguments: [
        BoldColorCase(sgr: "4;58;5;1", text: .palette(1), background: .defaultBackground),
        BoldColorCase(sgr: "1;4;58;5;1", text: .palette(9), background: .defaultBackground),
        BoldColorCase(sgr: "1;4;58;5;7", text: .palette(7), background: .defaultBackground),
        BoldColorCase(sgr: "1;4;58;5;9", text: .palette(9), background: .defaultBackground),
    ])
    func aBoldCellsUnderlineIsDrawnInSwiftTermsColour(_ given: BoldColorCase) throws {
        try withOneCellFrame("\u{1b}[\(given.sgr)mX") { surface in
            let underline = surface.rowRects.first?.first {
                $0.style == UInt32(TKZ_RECT_STYLE_UNDERLINE_SINGLE)
            }
            let rect = try #require(underline, "no underline was built for the X")
            let color: UInt32 = rect.color
            let wanted: UInt32 = given.text.packed(surface.colors)
            #expect(color == wanted, "SGR \(given.sgr) underline is \(hex(color)), not \(given.text), \(hex(wanted))")
        }
    }

    /// Builds the first frame of a terminal fed `text`, without a GPU, and hands `body` the surface.
    /// The palette's first sixteen entries must differ from one another, or a colour drawn from the
    /// wrong entry could not be told from the right one.
    private func withOneCellFrame(_ text: String, _ body: (TerminalSurface) throws -> Void) throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let builder = FrameBuilder(glyphCache: GlyphCache(fontSet: FontSet(font: font, scale: 2), device: nil))
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        terminal.feed(text: text)
        let surface = TerminalSurface()
        try surface.attach(terminal)
        try builder.update(surface)
        let base: [UInt32] = Array(surface.colors.palette.prefix(16))
        try #require(Set(base).count == 16, "the palette's first 16 entries are not distinct: \(base.map(hex))")
        try body(surface)
    }
}

/// What a cell's colour should be: a palette entry or one of the default colours.
enum DrawnColor: Sendable, Hashable, CustomStringConvertible {
    case palette(Int)
    case defaultForeground
    case defaultBackground

    func packed(_ colors: SurfaceColors) -> UInt32 {
        switch self {
        case .palette(let index): return colors.palette[index]
        case .defaultForeground: return colors.foreground
        case .defaultBackground: return colors.background
        }
    }

    var description: String {
        switch self {
        case .palette(let index): return "palette \(index)"
        case .defaultForeground: return "the default foreground"
        case .defaultBackground: return "the default background"
        }
    }
}

/// One SGR sequence and the colours SwiftTerm draws a cell of it in.
struct BoldColorCase: Sendable, CustomTestStringConvertible {
    let sgr: String
    /// The text's colour, or for the underline cases the underline's.
    let text: DrawnColor
    let background: DrawnColor

    var testDescription: String { "SGR \(sgr)" }
}

/// A grayscale glyph's total coverage.
private func ink(_ glyph: RasterizedGlyph) -> Int {
    glyph.pixels.reduce(0) { $0 + Int($1) }
}

private func hex(_ color: UInt32) -> String {
    String(color, radix: 16)
}
