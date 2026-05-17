import Foundation
import SwiftTerm

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
    static func scheme(forID id: String) -> TerminalColorScheme {
        bundled.first { $0.id == id } ?? tbdDefault
    }

    // `nonisolated(unsafe)` is required because `SwiftTerm.Color` is a
    // non-final class (not `Sendable`), but these values are immutable
    // after initialization and only read.
    nonisolated(unsafe) static let bundled: [TerminalColorScheme] = [
        tbdDefault,
        tango,
    ]

    // MARK: - tbd-default
    // Mirrors SwiftTerm's stock palette (xterm-compatible defaults). Provided
    // so existing users can revert to today's look.
    nonisolated(unsafe) static let tbdDefault = TerminalColorScheme(
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

    // MARK: - tango (dark variant of user's iTerm profile; Tango palette)
    // RGB values transcribed from guake.json's dark-mode entries.
    nonisolated(unsafe) static let tango = TerminalColorScheme(
        id: "tango",
        displayName: "Tango",
        ansi: [
            rgb(0, 0, 0),
            rgb(204, 0, 0),
            rgb(78, 154, 6),
            rgb(196, 160, 0),
            rgb(52, 101, 164),
            rgb(117, 80, 123),
            rgb(6, 152, 154),
            rgb(211, 215, 207),
            rgb(85, 87, 83),
            rgb(239, 41, 41),
            rgb(138, 226, 52),
            rgb(252, 233, 79),
            rgb(114, 159, 207),
            rgb(173, 127, 168),
            rgb(52, 226, 226),
            rgb(238, 238, 236),
        ],
        foreground: rgb(255, 255, 255),
        background: rgb(0, 0, 0),
        cursor: rgb(255, 255, 255),
        selection: rgb(181, 213, 255)
    )

    /// 8-bit-per-channel → SwiftTerm.Color (16-bit per channel).
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(r) * 257,
            green: UInt16(g) * 257,
            blue: UInt16(b) * 257
        )
    }
}
