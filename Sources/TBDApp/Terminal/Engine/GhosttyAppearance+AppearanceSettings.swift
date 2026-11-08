import AppKit
import SwiftTerm
import TBDGhosttyTerminal

/// The libghostty appearance that matches what `TBDTerminalView` draws from the same settings:
/// the font, the scheme's foreground, background, cursor and sixteen ANSI colours, and the
/// cursor style. Entries 16 to 255 of the palette stay libghostty's xterm colours, as SwiftTerm
/// keeps its own.
///
/// `thinStrokes` has no counterpart: it is a CoreGraphics font-smoothing switch, and the
/// libghostty renderer rasterizes its glyphs itself.
extension GhosttyAppearance {
    @MainActor
    init(settings: AppearanceSettings) {
        let scheme = settings.effectiveScheme
        var palette = GhosttyAppearance.defaultPalette
        for (index, color) in scheme.ansi.prefix(16).enumerated() where index < palette.count {
            palette[index] = RGB(color)
        }
        let cursor = Self.cursor(for: settings.cursorStyle)
        self.init(
            font: settings.font,
            foreground: RGB(scheme.foreground),
            background: RGB(scheme.background),
            cursor: RGB(scheme.cursor),
            palette: palette,
            cursorStyle: cursor.style,
            cursorBlink: cursor.blinks)
    }

    /// SwiftTerm's six cursor styles as a shape and whether it blinks.
    static func cursor(for style: SwiftTerm.CursorStyle) -> (style: CursorStyle, blinks: Bool) {
        switch style {
        case .blinkBlock: return (.block, true)
        case .steadyBlock: return (.block, false)
        case .blinkUnderline: return (.underline, true)
        case .steadyUnderline: return (.underline, false)
        case .blinkBar: return (.bar, true)
        case .steadyBar: return (.bar, false)
        @unknown default: return (.block, true)
        }
    }
}

extension GhosttyAppearance.RGB {
    /// A SwiftTerm colour, whose channels run to 65535, as 8-bit sRGB.
    init(_ color: SwiftTerm.Color) {
        self.init(
            r: UInt8(clamping: Int(color.red) / 257),
            g: UInt8(clamping: Int(color.green) / 257),
            b: UInt8(clamping: Int(color.blue) / 257))
    }
}
