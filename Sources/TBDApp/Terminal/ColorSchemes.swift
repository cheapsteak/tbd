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

        // Light themes
        solarizedLight, githubLight, catppuccinLatte, gruvboxLight,
        rosePineDawn, flexokiLight, tokyoNightDay,
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

    // MARK: - solarized-light
    /// Solarized Light — Ethan Schoonover, https://ethanschoonover.com/solarized/
    static let solarizedLight = TerminalColorScheme(
        id: "solarized-light",
        displayName: "Solarized Light",
        ansi: [
            rgb(0, 43, 54),         // 0 base03 (black)
            rgb(220, 50, 47),       // 1 red
            rgb(133, 153, 0),       // 2 green
            rgb(181, 137, 0),       // 3 yellow
            rgb(38, 139, 210),      // 4 blue
            rgb(211, 54, 130),      // 5 magenta
            rgb(42, 161, 152),      // 6 cyan
            rgb(238, 232, 213),     // 7 base2 (white)
            rgb(7, 54, 66),         // 8 base02 (bright black)
            rgb(203, 75, 22),       // 9 orange (bright red)
            rgb(88, 110, 117),      // 10 base01 (bright green)
            rgb(101, 123, 131),     // 11 base00 (bright yellow)
            rgb(131, 148, 150),     // 12 base0 (bright blue)
            rgb(108, 113, 196),     // 13 violet (bright magenta)
            rgb(147, 161, 161),     // 14 base1 (bright cyan)
            rgb(253, 246, 227),     // 15 base3 (bright white)
        ],
        foreground: rgb(101, 123, 131),
        background: rgb(253, 246, 227),
        cursor: rgb(101, 123, 131),
        selection: rgb(238, 232, 213)
    )

    // MARK: - github-light
    /// GitHub Light — https://github.com
    static let githubLight = TerminalColorScheme(
        id: "github-light",
        displayName: "GitHub Light",
        ansi: [
            rgb(36, 41, 46),        // 0 black
            rgb(209, 18, 47),       // 1 red
            rgb(46, 160, 67),       // 2 green
            rgb(158, 106, 3),       // 3 yellow
            rgb(9, 105, 218),       // 4 blue
            rgb(139, 58, 98),       // 5 magenta
            rgb(7, 112, 122),       // 6 cyan
            rgb(225, 228, 232),     // 7 white
            rgb(87, 96, 106),       // 8 bright black
            rgb(248, 81, 73),       // 9 bright red
            rgb(63, 185, 80),       // 10 bright green
            rgb(210, 153, 34),      // 11 bright yellow
            rgb(88, 166, 255),      // 12 bright blue
            rgb(188, 142, 247),     // 13 bright magenta
            rgb(57, 197, 207),      // 14 bright cyan
            rgb(255, 255, 255),     // 15 bright white
        ],
        foreground: rgb(36, 41, 46),
        background: rgb(255, 255, 255),
        cursor: rgb(9, 105, 218),
        selection: rgb(225, 228, 232)
    )

    // MARK: - catppuccin-latte
    /// Catppuccin Latte — https://github.com/catppuccin/catppuccin
    static let catppuccinLatte = TerminalColorScheme(
        id: "catppuccin-latte",
        displayName: "Catppuccin Latte",
        ansi: [
            rgb(92, 95, 119),       // 0 black
            rgb(210, 15, 57),       // 1 red
            rgb(64, 160, 43),       // 2 green
            rgb(223, 142, 29),      // 3 yellow
            rgb(30, 102, 245),      // 4 blue
            rgb(234, 118, 203),     // 5 magenta
            rgb(32, 159, 181),      // 6 cyan
            rgb(230, 233, 239),     // 7 white
            rgb(108, 111, 133),     // 8 bright black
            rgb(210, 15, 57),       // 9 bright red
            rgb(64, 160, 43),       // 10 bright green
            rgb(223, 142, 29),      // 11 bright yellow
            rgb(30, 102, 245),      // 12 bright blue
            rgb(234, 118, 203),     // 13 bright magenta
            rgb(32, 159, 181),      // 14 bright cyan
            rgb(239, 241, 245),     // 15 bright white
        ],
        foreground: rgb(76, 79, 105),
        background: rgb(239, 241, 245),
        cursor: rgb(30, 102, 245),
        selection: rgb(230, 233, 239)
    )

    // MARK: - gruvbox-light
    /// Gruvbox Light — Pavel Pertsev, https://github.com/morhetz/gruvbox
    static let gruvboxLight = TerminalColorScheme(
        id: "gruvbox-light",
        displayName: "Gruvbox Light",
        ansi: [
            rgb(251, 241, 199),     // 0 black
            rgb(204, 36, 29),       // 1 red
            rgb(152, 151, 26),      // 2 green
            rgb(215, 153, 33),      // 3 yellow
            rgb(69, 133, 136),      // 4 blue
            rgb(177, 98, 134),      // 5 magenta
            rgb(104, 157, 106),     // 6 cyan
            rgb(60, 56, 54),        // 7 white
            rgb(146, 131, 116),     // 8 bright black
            rgb(157, 0, 6),         // 9 bright red
            rgb(121, 116, 14),      // 10 bright green
            rgb(181, 118, 20),      // 11 bright yellow
            rgb(7, 102, 120),       // 12 bright blue
            rgb(143, 63, 113),      // 13 bright magenta
            rgb(66, 123, 88),       // 14 bright cyan
            rgb(40, 40, 40),        // 15 bright white
        ],
        foreground: rgb(60, 56, 54),
        background: rgb(251, 241, 199),
        cursor: rgb(69, 133, 136),
        selection: rgb(242, 229, 188)
    )

    // MARK: - rose-pine-dawn
    /// Rosé Pine Dawn — https://github.com/rose-pine/alacritty
    static let rosePineDawn = TerminalColorScheme(
        id: "rose-pine-dawn",
        displayName: "Rosé Pine Dawn",
        ansi: [
            rgb(242, 233, 225),     // 0 black
            rgb(180, 99, 122),      // 1 red
            rgb(40, 105, 131),      // 2 green
            rgb(234, 157, 52),      // 3 yellow
            rgb(86, 148, 159),      // 4 blue
            rgb(144, 122, 169),     // 5 magenta
            rgb(215, 130, 126),     // 6 cyan
            rgb(87, 82, 121),       // 7 white
            rgb(152, 147, 165),     // 8 bright black
            rgb(180, 99, 122),      // 9 bright red
            rgb(40, 105, 131),      // 10 bright green
            rgb(234, 157, 52),      // 11 bright yellow
            rgb(86, 148, 159),      // 12 bright blue
            rgb(144, 122, 169),     // 13 bright magenta
            rgb(215, 130, 126),     // 14 bright cyan
            rgb(87, 82, 121),       // 15 bright white
        ],
        foreground: rgb(87, 82, 121),
        background: rgb(250, 244, 237),
        cursor: rgb(206, 202, 205),
        selection: rgb(223, 218, 217)
    )

    // MARK: - tokyo-night-day
    /// Tokyo Night Day — https://github.com/folke/tokyonight.nvim
    static let tokyoNightDay = TerminalColorScheme(
        id: "tokyo-night-day",
        displayName: "Tokyo Night Day",
        ansi: [
            rgb(180, 181, 185),     // 0 black
            rgb(245, 42, 101),      // 1 red
            rgb(88, 117, 57),       // 2 green
            rgb(140, 108, 62),      // 3 yellow
            rgb(46, 125, 233),      // 4 blue
            rgb(152, 84, 241),      // 5 magenta
            rgb(0, 113, 151),       // 6 cyan
            rgb(97, 114, 176),      // 7 white
            rgb(161, 166, 197),     // 8 bright black
            rgb(255, 71, 116),      // 9 bright red
            rgb(92, 133, 36),       // 10 bright green
            rgb(162, 118, 41),      // 11 bright yellow
            rgb(53, 138, 255),      // 12 bright blue
            rgb(164, 99, 255),      // 13 bright magenta
            rgb(0, 126, 168),       // 14 bright cyan
            rgb(55, 96, 191),       // 15 bright white
        ],
        foreground: rgb(60, 62, 71),
        background: rgb(225, 226, 231),
        cursor: rgb(46, 125, 233),
        selection: rgb(183, 193, 227)
    )

    // MARK: - flexoki-light
    /// Flexoki Light — https://github.com/kepano/flexoki
    static let flexokiLight = TerminalColorScheme(
        id: "flexoki-light",
        displayName: "Flexoki Light",
        ansi: [
            rgb(16, 15, 15),        // 0 black
            rgb(209, 77, 65),       // 1 red
            rgb(135, 154, 57),      // 2 green
            rgb(208, 162, 21),      // 3 yellow
            rgb(67, 133, 190),      // 4 blue
            rgb(206, 93, 151),      // 5 magenta
            rgb(58, 169, 159),      // 6 cyan
            rgb(255, 252, 240),     // 7 white
            rgb(16, 15, 15),        // 8 bright black
            rgb(209, 77, 65),       // 9 bright red
            rgb(135, 154, 57),      // 10 bright green
            rgb(208, 162, 21),      // 11 bright yellow
            rgb(67, 133, 190),      // 12 bright blue
            rgb(206, 93, 151),      // 13 bright magenta
            rgb(58, 169, 159),      // 14 bright cyan
            rgb(255, 252, 240),     // 15 bright white
        ],
        foreground: rgb(16, 15, 15),
        background: rgb(255, 252, 240),
        cursor: rgb(16, 15, 15),
        selection: rgb(240, 235, 220)
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
