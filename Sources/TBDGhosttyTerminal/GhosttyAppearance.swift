// How a libghostty terminal looks: its font, colours and cursor.
//
// The view hands the colours and cursor to the terminal as its defaults, beneath anything a
// program sets with OSC 4, 10, 11 or 12, and builds its glyph atlas from the font. Applying a new
// appearance to a live view keeps what is on screen; only the defaults and the cell size change.
import AppKit
import GhosttyVt

/// The font, colours and cursor a `GhosttyTerminalView` draws with.
///
/// `@unchecked Sendable` because of `font`: `NSFont` is immutable, and Apple documents font
/// objects as safe to use from any thread, but the SDK does not mark the class `Sendable`. The
/// colours and the cursor settings are plain values.
public struct GhosttyAppearance: @unchecked Sendable, Equatable {
    /// An opaque 8-bit sRGB colour.
    public struct RGB: Sendable, Hashable {
        public var r: UInt8
        public var g: UInt8
        public var b: UInt8

        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// The cursor's shape when a program has not chosen one with DECSCUSR.
    public enum CursorStyle: Sendable, Hashable {
        case block, underline, bar
    }

    /// The terminal font. Bold and italic come from its family.
    public var font: NSFont
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    /// The 256-colour palette. A shorter array sets the first entries and keeps libghostty's
    /// defaults for the rest; extra entries are ignored.
    public var palette: [RGB]
    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool

    public init(
        font: NSFont,
        foreground: RGB,
        background: RGB,
        cursor: RGB,
        palette: [RGB] = GhosttyAppearance.defaultPalette,
        cursorStyle: CursorStyle = .block,
        cursorBlink: Bool = true
    ) {
        self.font = font
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.palette = palette
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
    }

    /// libghostty's own 256-colour palette: the xterm colours.
    public static let defaultPalette: [RGB] = {
        var colors = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        colors.withUnsafeMutableBufferPointer { buffer in ghostty_color_palette_default(buffer.baseAddress) }
        return colors.map { RGB($0) }
    }()

    /// True when the background is dark, which is what the terminal reports to a program that asks
    /// for the colour scheme (mode 2031). Rec. 709 luma below one half.
    var isDark: Bool {
        let luma = 0.2126 * Double(background.r) + 0.7152 * Double(background.g) + 0.0722 * Double(background.b)
        return luma < 128
    }
}

extension GhosttyAppearance.RGB {
    init(_ color: GhosttyColorRgb) {
        self.init(r: color.r, g: color.g, b: color.b)
    }

    var vtColor: GhosttyTerminal.VtColor {
        GhosttyTerminal.VtColor(r: r, g: g, b: b)
    }
}

extension GhosttyAppearance.CursorStyle {
    var ghostty: GhosttyCursorStyle {
        switch self {
        case .block: GHOSTTY_CURSOR_STYLE_BLOCK
        case .underline: GHOSTTY_CURSOR_STYLE_UNDERLINE
        case .bar: GHOSTTY_CURSOR_STYLE_BAR
        }
    }
}

extension GhosttyTerminal {
    /// Sets `appearance`'s colours and cursor as the terminal's defaults.
    func apply(_ appearance: GhosttyAppearance) {
        applyDefaults(
            foreground: appearance.foreground.vtColor,
            background: appearance.background.vtColor,
            cursor: appearance.cursor.vtColor,
            palette: appearance.palette.map(\.vtColor),
            cursorStyle: appearance.cursorStyle.ghostty,
            cursorBlink: appearance.cursorBlink,
            darkScheme: appearance.isDark)
    }
}
