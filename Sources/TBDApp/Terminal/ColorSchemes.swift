import Foundation
import SwiftTerm

// SwiftTerm.Color is a class but our usage is read-only post-construction.
extension SwiftTerm.Color: @retroactive @unchecked Sendable {}

struct TerminalColorScheme {
    let id: String
    let displayName: String
    let ansi: [SwiftTerm.Color]      // 16 colors, indices 0..15
    let foreground: SwiftTerm.Color
    let background: SwiftTerm.Color
    let cursor: SwiftTerm.Color
    let selection: SwiftTerm.Color
}

enum ColorSchemes {
    /// Single source of truth for the fallback scheme. Both `scheme(forID:)`
    /// and `AppearanceSettings.Defaults.schemeID` route through this so a
    /// poisoned id never lands the runtime renderer and the Settings Picker
    /// on different schemes.
    static let defaultScheme: TerminalColorScheme = tango

    static func scheme(forID id: String) -> TerminalColorScheme {
        bundled.first { $0.id == id } ?? defaultScheme
    }

    static let bundled: [TerminalColorScheme] = [
        // tango sits first because it's the default on fresh install — users
        // see it at the top of the Picker without having to scroll.
        tango, tbdDefault,
        solarizedDark, tomorrowNight, dracula,
        nord, oneDark, gruvboxDark,
    ]

    // MARK: - tbd-default
    // Mirrors SwiftTerm's stock palette (xterm-compatible defaults). Provided
    // so existing users can revert to today's look.
    static let tbdDefault = TerminalColorScheme(
        id: "tbd-default",
        displayName: "TBD Default",
        ansi: [
            rgb(0, 0, 0),           // 0 black
            rgb(170, 0, 0),         // 1 red
            rgb(0, 170, 0),         // 2 green
            rgb(170, 85, 0),        // 3 yellow
            rgb(0, 0, 170),         // 4 blue
            rgb(170, 0, 170),       // 5 magenta
            rgb(0, 170, 170),       // 6 cyan
            rgb(170, 170, 170),     // 7 white
            rgb(85, 85, 85),        // 8 bright black
            rgb(255, 85, 85),       // 9 bright red
            rgb(85, 255, 85),       // 10 bright green
            rgb(255, 255, 85),      // 11 bright yellow
            rgb(85, 85, 255),       // 12 bright blue
            rgb(255, 85, 255),      // 13 bright magenta
            rgb(85, 255, 255),      // 14 bright cyan
            rgb(255, 255, 255),     // 15 bright white
        ],
        foreground: rgb(255, 255, 255),
        background: rgb(0, 0, 0),
        cursor: rgb(255, 255, 255),
        selection: rgb(80, 80, 80)
    )

    // MARK: - tango
    /// Dark variant of user's iTerm profile; Tango palette. RGB values
    /// transcribed from guake.json's dark-mode entries.
    static let tango = TerminalColorScheme(
        id: "tango",
        displayName: "Tango",
        ansi: [
            rgb(0, 0, 0),           // 0 black
            rgb(204, 0, 0),         // 1 red
            rgb(78, 154, 6),        // 2 green
            rgb(196, 160, 0),       // 3 yellow
            rgb(52, 101, 164),      // 4 blue
            rgb(117, 80, 123),      // 5 magenta
            rgb(6, 152, 154),       // 6 cyan
            rgb(211, 215, 207),     // 7 white
            rgb(85, 87, 83),        // 8 bright black
            rgb(239, 41, 41),       // 9 bright red
            rgb(138, 226, 52),      // 10 bright green
            rgb(252, 233, 79),      // 11 bright yellow
            rgb(114, 159, 207),     // 12 bright blue
            rgb(173, 127, 168),     // 13 bright magenta
            rgb(52, 226, 226),      // 14 bright cyan
            rgb(238, 238, 236),     // 15 bright white
        ],
        foreground: rgb(255, 255, 255),
        background: rgb(0, 0, 0),
        cursor: rgb(255, 255, 255),
        selection: rgb(181, 213, 255)
    )

    // MARK: - solarized-dark
    /// Solarized Dark — Ethan Schoonover, https://ethanschoonover.com/solarized/
    static let solarizedDark = TerminalColorScheme(
        id: "solarized-dark",
        displayName: "Solarized Dark",
        ansi: [
            rgb(7, 54, 66),         // 0 base02 (black)
            rgb(220, 50, 47),       // 1 red
            rgb(133, 153, 0),       // 2 green
            rgb(181, 137, 0),       // 3 yellow
            rgb(38, 139, 210),      // 4 blue
            rgb(211, 54, 130),      // 5 magenta
            rgb(42, 161, 152),      // 6 cyan
            rgb(238, 232, 213),     // 7 base2 (white)
            rgb(0, 43, 54),         // 8 base03 (bright black)
            rgb(203, 75, 22),       // 9 orange (bright red)
            rgb(88, 110, 117),      // 10 base01 (bright green)
            rgb(101, 123, 131),     // 11 base00 (bright yellow)
            rgb(131, 148, 150),     // 12 base0 (bright blue)
            rgb(108, 113, 196),     // 13 violet (bright magenta)
            rgb(147, 161, 161),     // 14 base1 (bright cyan)
            rgb(253, 246, 227),     // 15 base3 (bright white)
        ],
        foreground: rgb(131, 148, 150),
        background: rgb(0, 43, 54),
        cursor: rgb(131, 148, 150),
        selection: rgb(7, 54, 66)
    )

    // MARK: - tomorrow-night
    /// Tomorrow Night — Chris Kempson, https://github.com/chriskempson/tomorrow-theme
    static let tomorrowNight = TerminalColorScheme(
        id: "tomorrow-night",
        displayName: "Tomorrow Night",
        ansi: [
            rgb(29, 31, 33),        // 0 black
            rgb(204, 102, 102),     // 1 red
            rgb(181, 189, 104),     // 2 green
            rgb(240, 198, 116),     // 3 yellow
            rgb(129, 162, 190),     // 4 blue
            rgb(178, 148, 187),     // 5 magenta
            rgb(138, 190, 183),     // 6 cyan
            rgb(197, 200, 198),     // 7 white
            rgb(150, 152, 150),     // 8 bright black
            rgb(204, 102, 102),     // 9 bright red
            rgb(181, 189, 104),     // 10 bright green
            rgb(240, 198, 116),     // 11 bright yellow
            rgb(129, 162, 190),     // 12 bright blue
            rgb(178, 148, 187),     // 13 bright magenta
            rgb(138, 190, 183),     // 14 bright cyan
            rgb(255, 255, 255),     // 15 bright white
        ],
        foreground: rgb(197, 200, 198),
        background: rgb(29, 31, 33),
        cursor: rgb(197, 200, 198),
        selection: rgb(55, 59, 65)
    )

    // MARK: - dracula
    /// Dracula — https://draculatheme.com/
    static let dracula = TerminalColorScheme(
        id: "dracula",
        displayName: "Dracula",
        ansi: [
            rgb(33, 34, 44),        // 0 black
            rgb(255, 85, 85),       // 1 red
            rgb(80, 250, 123),      // 2 green
            rgb(241, 250, 140),     // 3 yellow
            rgb(189, 147, 249),     // 4 blue
            rgb(255, 121, 198),     // 5 magenta
            rgb(139, 233, 253),     // 6 cyan
            rgb(248, 248, 242),     // 7 white
            rgb(98, 114, 164),      // 8 bright black
            rgb(255, 110, 103),     // 9 bright red
            rgb(90, 247, 142),      // 10 bright green
            rgb(244, 249, 157),     // 11 bright yellow
            rgb(202, 169, 250),     // 12 bright blue
            rgb(255, 146, 208),     // 13 bright magenta
            rgb(154, 237, 254),     // 14 bright cyan
            rgb(255, 255, 255),     // 15 bright white
        ],
        foreground: rgb(248, 248, 242),
        background: rgb(40, 42, 54),
        cursor: rgb(248, 248, 242),
        selection: rgb(68, 71, 90)
    )

    // MARK: - nord
    /// Nord — https://www.nordtheme.com/
    static let nord = TerminalColorScheme(
        id: "nord",
        displayName: "Nord",
        ansi: [
            rgb(59, 66, 82),        // 0 black
            rgb(191, 97, 106),      // 1 red
            rgb(163, 190, 140),     // 2 green
            rgb(235, 203, 139),     // 3 yellow
            rgb(129, 161, 193),     // 4 blue
            rgb(180, 142, 173),     // 5 magenta
            rgb(136, 192, 208),     // 6 cyan
            rgb(229, 233, 240),     // 7 white
            rgb(76, 86, 106),       // 8 bright black
            rgb(191, 97, 106),      // 9 bright red
            rgb(163, 190, 140),     // 10 bright green
            rgb(235, 203, 139),     // 11 bright yellow
            rgb(129, 161, 193),     // 12 bright blue
            rgb(180, 142, 173),     // 13 bright magenta
            rgb(143, 188, 187),     // 14 bright cyan
            rgb(236, 239, 244),     // 15 bright white
        ],
        foreground: rgb(216, 222, 233),
        background: rgb(46, 52, 64),
        cursor: rgb(216, 222, 233),
        selection: rgb(67, 76, 94)
    )

    // MARK: - one-dark
    /// One Dark — Atom / VS Code default dark.
    static let oneDark = TerminalColorScheme(
        id: "one-dark",
        displayName: "One Dark",
        ansi: [
            rgb(40, 44, 52),        // 0 black
            rgb(224, 108, 117),     // 1 red
            rgb(152, 195, 121),     // 2 green
            rgb(229, 192, 123),     // 3 yellow
            rgb(97, 175, 239),      // 4 blue
            rgb(198, 120, 221),     // 5 magenta
            rgb(86, 182, 194),      // 6 cyan
            rgb(171, 178, 191),     // 7 white
            rgb(92, 99, 112),       // 8 bright black
            rgb(224, 108, 117),     // 9 bright red
            rgb(152, 195, 121),     // 10 bright green
            rgb(229, 192, 123),     // 11 bright yellow
            rgb(97, 175, 239),      // 12 bright blue
            rgb(198, 120, 221),     // 13 bright magenta
            rgb(86, 182, 194),      // 14 bright cyan
            rgb(255, 255, 255),     // 15 bright white
        ],
        foreground: rgb(171, 178, 191),
        background: rgb(40, 44, 52),
        cursor: rgb(171, 178, 191),
        selection: rgb(62, 68, 81)
    )

    // MARK: - gruvbox-dark
    /// Gruvbox Dark — Pavel Pertsev, https://github.com/morhetz/gruvbox
    static let gruvboxDark = TerminalColorScheme(
        id: "gruvbox-dark",
        displayName: "Gruvbox Dark",
        ansi: [
            rgb(40, 40, 40),        // 0 black
            rgb(204, 36, 29),       // 1 red
            rgb(152, 151, 26),      // 2 green
            rgb(215, 153, 33),      // 3 yellow
            rgb(69, 133, 136),      // 4 blue
            rgb(177, 98, 134),      // 5 magenta
            rgb(104, 157, 106),     // 6 cyan
            rgb(168, 153, 132),     // 7 white
            rgb(146, 131, 116),     // 8 bright black
            rgb(251, 73, 52),       // 9 bright red
            rgb(184, 187, 38),      // 10 bright green
            rgb(250, 189, 47),      // 11 bright yellow
            rgb(131, 165, 152),     // 12 bright blue
            rgb(211, 134, 155),     // 13 bright magenta
            rgb(142, 192, 124),     // 14 bright cyan
            rgb(235, 219, 178),     // 15 bright white
        ],
        foreground: rgb(235, 219, 178),
        background: rgb(40, 40, 40),
        cursor: rgb(235, 219, 178),
        selection: rgb(60, 56, 54)
    )

    /// 8-bit-per-channel → SwiftTerm.Color (16-bit per channel).
    /// `UInt8` parameters make the 0–255 constraint self-documenting and
    /// prevent silent overflow if a future scheme uses an out-of-range literal.
    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(r) * 257,
            green: UInt16(g) * 257,
            blue: UInt16(b) * 257
        )
    }
}
