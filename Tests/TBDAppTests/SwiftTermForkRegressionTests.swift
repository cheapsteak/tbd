import SwiftTerm
import Testing

// Regression tests for two fixes TBD's SwiftTerm fork carries (see the pin's
// comment in Package.swift). They use only SwiftTerm's public API, so they keep
// guarding the behavior after a re-pin to upstream, whatever the fix looks like
// there.

/// `Terminal.tdel` is weak, so each test holds its delegate strongly.
private final class SilentDelegate: TerminalDelegate {
    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
}

private struct Harness {
    let delegate = SilentDelegate()
    let terminal: SwiftTerm.Terminal

    init(cols: Int, rows: Int, scrollback: Int = 500) {
        terminal = SwiftTerm.Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    func feed(_ text: String) { terminal.feed(text: text) }
}

@Suite("SwiftTerm fork regressions")
struct SwiftTermForkRegressionTests {
    /// TBD creates every terminal at the pane's width, often wider than 80
    /// columns. The default stops sit every 8 columns across the whole grid, so
    /// a tab from column 88 (0-based) stops at 96 rather than running to the
    /// last column.
    @Test(arguments: [false, true])
    func tabPastColumn80StopsAtTheNextDefaultStop(onAlternateScreen: Bool) throws {
        let harness = Harness(cols: 120, rows: 24)
        if onAlternateScreen {
            harness.feed("\u{1b}[?1049h")
            try #require(harness.terminal.isCurrentBufferAlternate)
        }

        harness.feed("\u{1b}[1;89H")
        try #require(harness.terminal.getCursorLocation().x == 88)
        harness.feed("\t")

        #expect(harness.terminal.getCursorLocation().x == 96)
    }

    /// Style identifiers are 16 bits wide, so the style table holds 65,535
    /// entries. A long session that prints many distinct colours fills it with
    /// styles whose cells have long since scrolled out of a small scrollback.
    /// A colour first seen after that point must still reach its cell, and the
    /// cells still on screen must keep the colours they were written with.
    @Test
    func newColourKeepsItsCellAfterTheStyleTableFills() throws {
        let cols = 80
        let rows = 24
        // 820 full lines of 80 cells: 65,600 distinct styles, more than the
        // table holds.
        let floodLines = 820
        let harness = Harness(cols: cols, rows: rows, scrollback: 10)

        var flood = ""
        flood.reserveCapacity(floodLines * cols * 20)
        for line in 0..<floodLines {
            if line > 0 { flood += "\r\n" }
            for col in 0..<cols {
                flood += foregroundSequence(floodColour(line * cols + col)) + "x"
            }
        }
        harness.feed(flood)

        // The flood's blue component is 0 or 1, so 252 is a colour it never used.
        let lastColour = Attribute.Color.trueColor(red: 250, green: 251, blue: 252)
        harness.feed("\r\n" + foregroundSequence(lastColour) + "Z")

        let cursor = harness.terminal.getCursorLocation()
        try #require(cursor.x == 1 && cursor.y == rows - 1)

        var mismatches: [String] = []
        let lastCell = harness.terminal.getCharData(col: 0, row: rows - 1)?.attribute.fg
        if lastCell != lastColour {
            mismatches.append("last cell: \(String(describing: lastCell))")
        }
        // Rows above the last show the flood's final lines.
        let firstVisibleLine = floodLines - (rows - 1)
        for row in 0..<(rows - 1) {
            for col in 0..<cols {
                let expected = floodColour((firstVisibleLine + row) * cols + col)
                let actual = harness.terminal.getCharData(col: col, row: row)?.attribute.fg
                if actual != expected {
                    mismatches.append("row \(row) col \(col): \(String(describing: actual))")
                }
            }
        }

        #expect(
            mismatches.isEmpty,
            "\(mismatches.count) cells lost their colour; first: \(mismatches.prefix(5))")
    }

    /// A pen with a background also interns a background-only style for the
    /// cells that erases paint. Reclaiming style identifiers can release that
    /// erase style while a cell keeps the pen. Selecting the pen again must
    /// still erase with its background, as `ESC[31;44m ESC[K` does in a shell
    /// that has run long enough to fill the style table. This guards the
    /// erase-style reclaim. It also passes on `c6b544f`, which never reclaims,
    /// because there the erase style keeps its identifier.
    @Test
    func erasingWithAReselectedPenKeepsItsBackground() {
        let cols = 80
        let harness = Harness(cols: cols, rows: 24, scrollback: 1000)
        let blue = Attribute.Color.ansi256(code: 4)

        // The pen and its erase style take two of the table's 65,535 style
        // identifiers, and only the printed cell holds either of them.
        harness.feed("\u{1b}[31;44mA\u{1b}[0m")
        // The first 65,533 colours take the remaining identifiers, and the
        // scrollback keeps every cell. The last colour finds the table full and
        // reclaims the one identifier no cell holds: the erase style's.
        let floodCount = 65_534
        var flood = ""
        flood.reserveCapacity(floodCount * 20)
        for index in 0..<floodCount {
            flood += foregroundSequence(floodColour(index)) + "x"
        }
        harness.feed(flood)
        // ED 3, which `clear` sends, discards the scrollback.
        harness.feed("\u{1b}[3J")

        harness.feed("\u{1b}[0;31;44m\u{1b}[H\u{1b}[K")

        var mismatches: [String] = []
        for col in 0..<cols {
            let background = harness.terminal.getCharData(col: col, row: 0)?.attribute.bg
            if background != blue {
                mismatches.append("col \(col): \(String(describing: background))")
            }
        }
        #expect(
            mismatches.isEmpty,
            "\(mismatches.count) erased cells lost their background; first: \(mismatches.prefix(5))")
    }

    /// The terminal caches the erase cells of a pen with a background, and
    /// only those cached cells hold their background-only style until
    /// something erases. A reclaim must keep that style while the pen stays
    /// selected, or a new colour takes its identifier and erasing paints that
    /// colour's foreground. The 300 by 220 screen holds every printed cell
    /// without scrolling, because a line scrolled in would be filled with the
    /// erase style and keep it whether or not the reclaim marks the cache.
    @Test
    func erasingWithAPenKeptThroughAReclaimKeepsTheEraseStyle() {
        let cols = 300
        let harness = Harness(cols: cols, rows: 220)
        let blue = Attribute.Color.ansi256(code: 4)

        // The pen takes style identifier 1 and its erase style 2, and the
        // background stays blue from here on.
        harness.feed("\u{1b}[31;44mA")
        // The first flood colour takes 3, and the second prints over its cell,
        // so nothing holds 3 any more.
        harness.feed(foregroundSequence(floodColour(0)) + "x\u{8}")
        // The rest take 4 through 65,535, which fills the table, and the last
        // finds it full. Its reclaim releases 3, which the last colour then
        // takes. A reclaim that left out the cached erase cells would release
        // 2 as well, and the last colour would take that one, the lowest.
        let floodCount = 65_534
        var flood = ""
        flood.reserveCapacity(floodCount * 20)
        for index in 1..<floodCount {
            flood += foregroundSequence(floodColour(index)) + "x"
        }
        harness.feed(flood)

        harness.feed("\u{1b}[H\u{1b}[K")

        var mismatches: [String] = []
        for col in 0..<cols {
            guard let attribute = harness.terminal.getCharData(col: col, row: 0)?.attribute else {
                mismatches.append("col \(col): no cell")
                continue
            }
            if attribute.fg != .defaultColor || attribute.bg != blue
                || attribute.style != SwiftTerm.CharacterStyle.none
                || attribute.underlineStyle != SwiftTerm.UnderlineStyle.none
                || attribute.underlineColor != nil {
                mismatches.append("col \(col): \(attribute)")
            }
        }
        #expect(
            mismatches.isEmpty,
            "\(mismatches.count) erased cells lost the erase style; first: \(mismatches.prefix(5))")
    }
}

/// A distinct truecolour for each flood cell.
private func floodColour(_ index: Int) -> Attribute.Color {
    .trueColor(
        red: UInt8(index & 0xff),
        green: UInt8((index >> 8) & 0xff),
        blue: UInt8((index >> 16) & 0xff))
}

private func foregroundSequence(_ colour: Attribute.Color) -> String {
    guard case let .trueColor(red, green, blue) = colour else { return "" }
    return "\u{1b}[38;2;\(red);\(green);\(blue)m"
}
