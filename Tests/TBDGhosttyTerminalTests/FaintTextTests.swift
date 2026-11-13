import AppKit
import Foundation
import TBDGhosttyShaderTypes
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// Faint (SGR 2) text as SwiftTerm draws it. SwiftTerm's Core Graphics and Metal renderers both
/// take the text colour from `dimmedColor(towards:)`: each sRGB channel the mean of the text's and
/// the cell's background's, opaque. The text colour is the one after the inverse swap and the bold
/// brightening, and the background is the cell's own after the swap, the default background when
/// it has none. The default underline and the strikethrough take the dimmed colour; an SGR 58
/// underline colour does not.
///
/// SwiftTerm blends in floating point, so where a channel's two values sum to an odd number its
/// mean falls between two 8-bit values. A drawn channel matches when it is within half a step of
/// the exact mean, which is the nearest any 8-bit colour comes; where the sum is even that is the
/// mean exactly. `aTruecolourPairWithEvenSumsIsDimmedExactly` spells one result out in full.
///
/// Main actor, because a `FontSet` is built there.
@Suite(.fastPassBounded)
@MainActor
struct FaintTextTests {
    // MARK: - Text

    /// Faint text is drawn opaque, halfway between its colour and its cell's background.
    @Test(arguments: [
        FaintColorCase(sgr: "2", text: .defaultForeground, background: .defaultBackground),
        FaintColorCase(sgr: "2;31", text: .palette(1), background: .defaultBackground),
        FaintColorCase(sgr: "2;31;44", text: .palette(1), background: .palette(4)),
        // Bold brightens first, then the bright colour dims.
        FaintColorCase(sgr: "1;2;31", text: .palette(9), background: .defaultBackground),
        // Under SGR 7 the text dims towards the background the swap gave the cell.
        FaintColorCase(sgr: "2;7;32;44", text: .palette(4), background: .palette(2)),
        FaintColorCase(sgr: "1;2;7;32;44", text: .palette(12), background: .palette(2)),
        FaintColorCase(sgr: "2;7", text: .defaultBackground, background: .defaultForeground),
        FaintColorCase(sgr: "2;38;2;200;100;50;48;2;20;40;60",
                       text: .rgb(200, 100, 50), background: .rgb(20, 40, 60)),
        FaintColorCase(sgr: "2;38;2;255;0;0", text: .rgb(255, 0, 0), background: .defaultBackground),
    ])
    func faintTextIsDrawnInSwiftTermsColour(_ given: FaintColorCase) throws {
        try withOneCellFrame("\u{1b}[\(given.sgr)mX") { surface in
            let colors = surface.colors
            let glyph = try #require(glyphAtOrigin(surface), "no glyph was built for the X")
            let text: UInt32 = given.text.packed(colors)
            let background: UInt32 = given.background.packed(colors)
            try #require(text != background, "SGR \(given.sgr) puts \(given.text) on itself, so dimming cannot show")

            let cellBackground: UInt32 = glyph.bgColor
            #expect(cellBackground == background,
                    "SGR \(given.sgr) background is \(hex(cellBackground)), not \(given.background), \(hex(background))")
            let drawn: UInt32 = glyph.color
            #expect(isSwiftTermsDim(drawn, of: text, towards: background),
                    "SGR \(given.sgr) text is \(hex(drawn)), not \(given.text) \(hex(text)) dimmed towards \(given.background) \(hex(background)), \(halfSum(text, background))")
        }
    }

    /// The test's own arithmetic, checked against a result worked by hand: rgb(200, 100, 50) on
    /// rgb(20, 40, 60) sums to (220, 140, 110), so the faint text is rgb(110, 70, 55), opaque.
    @Test func aTruecolourPairWithEvenSumsIsDimmedExactly() throws {
        try withOneCellFrame("\u{1b}[2;38;2;200;100;50;48;2;20;40;60mX") { surface in
            let glyph = try #require(glyphAtOrigin(surface), "no glyph was built for the X")
            let drawn: UInt32 = glyph.color
            let wanted: UInt32 = 0xFF37_466E
            #expect(drawn == wanted, "the faint text is \(hex(drawn)), not \(hex(wanted))")
        }
    }

    // MARK: - Decorations

    /// The underline and the strikethrough of faint text take the dimmed colour, as in SwiftTerm,
    /// unless SGR 58 gives the underline a colour of its own, which is drawn undimmed (and, under
    /// bold, brightened). The text is dimmed in every case.
    @Test(arguments: [
        FaintDecorationCase(sgr: "2;4", style: .underline, color: .defaultForeground, isDimmed: true),
        FaintDecorationCase(sgr: "2;9", style: .strikethrough, color: .defaultForeground, isDimmed: true),
        FaintDecorationCase(sgr: "2;4;58;5;1", style: .underline, color: .palette(1), isDimmed: false),
        FaintDecorationCase(sgr: "1;2;4;58;5;1", style: .underline, color: .palette(9), isDimmed: false),
    ])
    func aFaintCellsDecorationsAreDrawnInSwiftTermsColour(_ given: FaintDecorationCase) throws {
        try withOneCellFrame("\u{1b}[\(given.sgr)mX") { surface in
            let colors = surface.colors
            let glyph = try #require(glyphAtOrigin(surface), "no glyph was built for the X")
            let text: UInt32 = glyph.color
            #expect(isSwiftTermsDim(text, of: colors.foreground, towards: colors.background),
                    "SGR \(given.sgr) text is \(hex(text)), not the default foreground dimmed, \(halfSum(colors.foreground, colors.background))")

            let rectStyle = given.style.rectStyle
            let decoration = surface.rowRects.first?.first { $0.style == rectStyle }
            let rect = try #require(decoration, "no \(given.style) was built for the X")
            let drawn: UInt32 = rect.color
            let color: UInt32 = given.color.packed(colors)
            if given.isDimmed {
                #expect(isSwiftTermsDim(drawn, of: color, towards: colors.background),
                        "SGR \(given.sgr) \(given.style) is \(hex(drawn)), not \(given.color) dimmed, \(halfSum(color, colors.background))")
            } else {
                #expect(drawn == color,
                        "SGR \(given.sgr) \(given.style) is \(hex(drawn)), not \(given.color) undimmed, \(hex(color))")
            }
        }
    }

    // MARK: - Selection and colour glyphs

    /// A selected faint cell dims towards its own background, not the selection colour drawn over
    /// it: SwiftTerm draws the selection behind the cell's text and leaves the text's colour alone.
    @Test func aSelectedFaintCellDimsTowardsItsOwnBackground() throws {
        let tint: UInt32 = 0xFF56_3412
        try withOneCellFrame("\u{1b}[2;31;44mX", selectionTint: tint) { surface in
            let colors = surface.colors
            let selectedBackground: UInt32 = surface.backgroundCells[0].color
            try #require(selectedBackground == tint,
                         "the selected cell's background is \(hex(selectedBackground)), not the selection colour \(hex(tint))")
            let glyph = try #require(glyphAtOrigin(surface), "no glyph was built for the X")
            let drawn: UInt32 = glyph.color
            let text: UInt32 = colors.palette[1]
            let cellBackground: UInt32 = colors.palette[4]
            #expect(isSwiftTermsDim(drawn, of: text, towards: cellBackground),
                    "the selected faint text is \(hex(drawn)), not palette 1 dimmed towards palette 4, \(halfSum(text, cellBackground))")
            #expect(!isSwiftTermsDim(drawn, of: text, towards: tint),
                    "the selected faint text \(hex(drawn)) was dimmed towards the selection colour")
        }
    }

    /// A faint colour glyph draws at full alpha. SwiftTerm dims the text colour, which does not
    /// tint a colour glyph, and the shader multiplies a colour glyph by the instance's alpha, so
    /// the instance colour has to stay opaque.
    @Test func aFaintColourGlyphIsDrawnAtFullAlpha() throws {
        try withOneCellFrame("\u{1b}[2m\u{1F600}") { surface in
            let glyph = try #require(glyphAtOrigin(surface), "no glyph was built for the emoji")
            try #require(glyph.flags & UInt32(TKZ_GLYPH_FLAG_COLOR) != 0, "the emoji was not drawn as a colour glyph")
            let alpha: UInt32 = glyph.color >> 24
            #expect(alpha == 0xFF, "the faint emoji is drawn at alpha \(hex(alpha)), not opaque")
        }
    }

    // MARK: - Helpers

    private func glyphAtOrigin(_ surface: TerminalSurface) -> TkzGlyphInstance? {
        surface.glyphInstances().first { $0.gridPos.x == 0 && $0.gridPos.y == 0 }
    }

    /// Builds the first frame of a terminal fed `text`, without a GPU, and hands `body` the surface.
    /// With a `selectionTint`, everything is selected and the surface carries that tint. The
    /// palette's first sixteen entries must differ from one another, or a colour drawn from the
    /// wrong entry could not be told from the right one.
    private func withOneCellFrame(
        _ text: String, selectionTint: UInt32? = nil, _ body: (TerminalSurface) throws -> Void
    ) throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let builder = FrameBuilder(glyphCache: GlyphCache(fontSet: FontSet(font: font, scale: 2), device: nil))
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        terminal.feed(text: text)
        let surface = TerminalSurface()
        if let selectionTint {
            let selected = terminal.selectAll()
            try #require(selected, "Select All selected nothing")
            surface.selectionColor = selectionTint
        }
        try surface.attach(terminal)
        try builder.update(surface)
        let base: [UInt32] = Array(surface.colors.palette.prefix(16))
        try #require(Set(base).count == 16, "the palette's first 16 entries are not distinct: \(base.map(hex))")
        try body(surface)
    }
}

/// A colour a faint case names: a palette entry, a default colour, or a 24-bit one.
enum FaintCellColor: Sendable, Hashable, CustomStringConvertible {
    case palette(Int)
    case defaultForeground
    case defaultBackground
    case rgb(UInt8, UInt8, UInt8)

    func packed(_ colors: SurfaceColors) -> UInt32 {
        switch self {
        case .palette(let index): return colors.palette[index]
        case .defaultForeground: return colors.foreground
        case .defaultBackground: return colors.background
        case .rgb(let r, let g, let b): return UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
        }
    }

    var description: String {
        switch self {
        case .palette(let index): return "palette \(index)"
        case .defaultForeground: return "the default foreground"
        case .defaultBackground: return "the default background"
        case .rgb(let r, let g, let b): return "rgb(\(r), \(g), \(b))"
        }
    }
}

/// One SGR sequence, the colour its text takes before the dim, and the cell's background.
struct FaintColorCase: Sendable, CustomTestStringConvertible {
    let sgr: String
    let text: FaintCellColor
    let background: FaintCellColor

    var testDescription: String { "SGR \(sgr)" }
}

/// One SGR sequence and the colour SwiftTerm draws its decoration in.
struct FaintDecorationCase: Sendable, CustomTestStringConvertible {
    enum Style: Sendable, CustomStringConvertible {
        case underline
        case strikethrough

        var rectStyle: UInt32 {
            switch self {
            case .underline: return UInt32(TKZ_RECT_STYLE_UNDERLINE_SINGLE)
            case .strikethrough: return UInt32(TKZ_RECT_STYLE_STRIKETHROUGH)
            }
        }

        var description: String {
            switch self {
            case .underline: return "underline"
            case .strikethrough: return "strikethrough"
            }
        }
    }

    let sgr: String
    let style: Style
    /// The decoration's colour before any dim.
    let color: FaintCellColor
    /// Whether the decoration is drawn dimmed towards the default background, or in `color` as is.
    let isDimmed: Bool

    var testDescription: String { "SGR \(sgr)" }
}

/// Whether `drawn` is SwiftTerm's faint blend of `text` towards `background`: opaque, and each
/// channel within half a step of the exact mean of the two.
private func isSwiftTermsDim(_ drawn: UInt32, of text: UInt32, towards background: UInt32) -> Bool {
    guard drawn >> 24 == 0xFF else { return false }
    let shifts: [UInt32] = [0, 8, 16]
    return shifts.allSatisfy { shift in
        let d = Int((drawn >> shift) & 0xFF)
        let t = Int((text >> shift) & 0xFF)
        let b = Int((background >> shift) & 0xFF)
        return abs(2 * d - (t + b)) <= 1
    }
}

/// The exact per-channel mean of two packed colours, for failure messages.
private func halfSum(_ text: UInt32, _ background: UInt32) -> String {
    let shifts: [UInt32] = [0, 8, 16]
    let channels: [String] = shifts.map { shift in
        let sum = Int((text >> shift) & 0xFF) + Int((background >> shift) & 0xFF)
        return sum % 2 == 0 ? "\(sum / 2)" : "\(sum / 2).5"
    }
    return "rgb(\(channels.joined(separator: ", "))) opaque"
}

private func hex(_ color: UInt32) -> String {
    String(color, radix: 16)
}
