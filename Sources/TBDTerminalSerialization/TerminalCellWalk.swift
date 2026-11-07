import Foundation
import SwiftTerm

/// Renders a terminal's retained scrollback and current screen as styled lines.
///
/// **Every function here reads `Terminal` state, so the caller must hold
/// `terminal.terminalLock` for the whole call.** `Terminal` is not `Sendable`,
/// does not lock itself, and is fed from a different thread than the one
/// rendering it in both processes that use this — the daemon's drain thread
/// against its emulator, the app's IO thread against its view. Reading a buffer
/// mid-parse garbles the output rather than crashing, which is why the rule is
/// stated rather than left to be noticed. The lock is not taken here because
/// it is not re-entrant and every real caller is already inside it: the whole
/// snapshot — mode capture, this walk, and the alt-screen toggle around it —
/// has to be one critical section or the pieces disagree about which screen
/// they describe.
///
/// Each returned line is self-contained: it opens with an SGR run and carries
/// its own attribute changes, so a reader can begin at any line. Lines carry no
/// terminator — the caller joins them with `\r\n` and must not add a trailing
/// one, because a trailing newline scrolls one extra row into the receiver's
/// scrollback (the same rule `ReplayWriter.assemble` follows for the same
/// reason).
public enum TerminalCellWalk {
    public static func styledHistory(of terminal: Terminal, maxScrollbackLines: Int) -> String {
        join(lines(of: terminal, maxScrollbackLines: maxScrollbackLines), cols: terminal.cols)
    }

    public static func styledViewport(of terminal: Terminal) -> String {
        let rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0) }
        return join(rows, cols: terminal.cols)
    }

    /// Joins rendered lines with `\r\n` — but ONLY before a line that is not a
    /// wrapped continuation. A continuation must follow its predecessor with no
    /// line ending at all, so the receiver's DECAWM re-wraps it at its own
    /// width. Emitting a separator there hard-breaks the line instead, and no
    /// assertion about the resulting text can tell the two apart.
    ///
    /// A line's own `isWrapped` says whether IT continues its predecessor —
    /// that is what gates the separator above. Whether a line must itself be
    /// emitted at full width is the opposite question: whether the NEXT line
    /// continues it. Reusing `isWrapped` for both pads the last physical row
    /// of a wrapped paragraph out to the full column count with blank cells
    /// instead of trimming it, because that row's own flag is `true` (it
    /// continues the row above) even though nothing continues it.
    private static func join(_ lines: [BufferLine], cols: Int) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            if index > 0 && !line.isWrapped { out += "\r\n" }
            let continuesToNextLine = index + 1 < lines.count && lines[index + 1].isWrapped
            out += render(line: line, cols: cols, fullWidth: continuesToNextLine)
        }
        return out
    }

    private static func lines(of terminal: Terminal, maxScrollbackLines: Int) -> [BufferLine] {
        // `Buffer.lines` is internal and there is no public line count, so the
        // only way to enumerate is to walk from the oldest retained row until
        // the accessor stops answering. See HolderReader.swift:893-906.
        var rows: [Int] = []
        var row = terminal.buffer.totalLinesTrimmed
        while terminal.getScrollInvariantLine(row: row) != nil {
            rows.append(row)
            row += 1
        }

        // Keep the TAIL when capping: the newest scrollback is the part a
        // returning viewer is looking for. The viewport always survives.
        let viewportRows = terminal.rows
        if rows.count > maxScrollbackLines + viewportRows {
            rows = Array(rows.suffix(maxScrollbackLines + viewportRows))
        }

        var walked = rows.compactMap { terminal.getScrollInvariantLine(row: $0) }

        // Trailing blank rows are dropped only when the walk holds no row
        // above the viewport. The receiver starts on an erased screen with
        // the cursor at home, and once it reaches its bottom row, every
        // further row it is sent scrolls one row into its scrollback. So a
        // walk that holds history must arrive whole: each trailing row
        // dropped is a scroll the receiver never makes, so the viewport lands
        // that many rows low, the history comes up that many rows short, and
        // the absolute cursor address that ends the snapshot points at the
        // wrong line. The cap above changes only how much history there is,
        // so the same test holds for a capped walk.
        //
        // Without history the receiver never scrolls, its screen below the
        // last row sent is already blank, and the closing cursor address puts
        // the cursor back wherever it was. There a trailing blank row adds
        // only a line ending, so dropping it lets a short screen walk as its
        // text instead of its text plus a run of empty lines. A row is blank
        // when `visibleLength` is 0, so a row of coloured blanks stays. A
        // wrapped continuation is never dropped, and a blank row earlier in
        // the walk is real content and stays.
        //
        // `styledViewport` does not apply this trim: on the alt screen a blank
        // trailing row is the application's own layout, not unused padding.
        let holdsHistory = walked.count > viewportRows
        if !holdsHistory {
            while let last = walked.last, !last.isWrapped, visibleLength(of: last) == 0 {
                walked.removeLast()
            }
        }

        return walked
    }

    /// How many leading cells a receiver needs to show `line` as the source
    /// does: through the last character, or through the last blank that
    /// `isVisibleWhenBlank` says can be seen, whichever is further.
    ///
    /// `getTrimmedLength()` alone is not enough. It stops after the last cell
    /// with a character, and erasing under a background colour (BCE, such as
    /// `ESC[44m ESC[2J`, `ESC[41m ESC[K`, ECH or DCH) leaves blanks with no
    /// character that still carry the colour. A receiver that is not sent
    /// them shows the default background there.
    ///
    /// When a line's coloured blanks run to the last column, the receiver is
    /// left in pending wrap, as it is after a line of text that long. Nothing
    /// that follows prints before the cursor moves: `join` sends `\r\n` next,
    /// whose CR clears the pending wrap before the LF moves down, and after
    /// the last line the writer sends only mode escapes and cursor moves
    /// before anything prints again. So no extra row wraps.
    private static func visibleLength(of line: BufferLine) -> Int {
        let trimmed = line.getTrimmedLength()
        // Every cell from `trimmed` on has no character, so only attributes
        // can make one of them visible.
        var length = line.count
        while length > trimmed {
            if isVisibleWhenBlank(line[length - 1].attribute) { return length }
            length -= 1
        }
        return trimmed
    }

    /// Whether a cell with no character looks different from the erased cells
    /// a receiver starts with, which the prelude erased under SGR 0.
    ///
    /// A background colour fills the cell, and inverse fills it with the
    /// foreground colour. Underline and strikethrough are lines a terminal
    /// draws across the cell whether or not it holds a glyph. Bold, dim,
    /// italic, blink, invisible and a foreground colour change only how a
    /// glyph is drawn, and a blank has none, so they do not count. SwiftTerm's
    /// erase keeps only the background, so the background is the case erasing
    /// produces; the other three count because a blank that carried them would
    /// be just as visible. Both default background cases count as default,
    /// because `SGREncoder` writes neither and the receiver cannot tell them
    /// apart.
    private static func isVisibleWhenBlank(_ attribute: Attribute) -> Bool {
        switch attribute.bg {
        case .defaultColor, .defaultInvertedColor:
            break
        case .ansi256, .trueColor:
            return true
        }
        let style = attribute.style
        return style.contains(.inverse)
            || style.contains(.underline) || attribute.underlineStyle != .none
            || style.contains(.crossedOut)
    }

    private static func render(line: BufferLine, cols: Int, fullWidth: Bool) -> String {
        // A line the next one wraps from is emitted at full width; `join` is
        // what withholds its line ending so DECAWM re-wraps it in the
        // receiver. Otherwise the line ends at its `visibleLength`, so a
        // mostly-empty screen does not cost `cols` bytes/row and a coloured
        // blank at the end of a line still arrives.
        //
        // The full-width branch caps at `line.count`, not just `cols`: a
        // scrollback line shorter than the terminal's current column count
        // (reachable around resize/reflow) would otherwise read past its own
        // storage — `BufferLine`'s subscript clamps an out-of-range index to
        // its last cell instead of trapping, which would silently repeat
        // that cell out to `cols`.
        let limit = fullWidth ? min(cols, line.count) : min(visibleLength(of: line), cols)
        guard limit > 0 else { return "" }

        var out = ""
        var openAttribute: Attribute?
        for column in 0..<limit {
            let cell = line[column]
            // The trailing half of a wide character. Emitting it would double
            // every CJK glyph and every emoji.
            if cell.width == 0 { continue }
            if openAttribute != cell.attribute {
                out += SGREncoder.sequence(for: cell.attribute)
                openAttribute = cell.attribute
            }
            // An unwritten or erased cell carries code 0, and
            // `CharData.getCharacter()` renders that literally as
            // `Character(Unicode.Scalar(0))`. On the receiving terminal 0x00
            // is an `.execute` code with no case in ground-state dispatch —
            // it logs an unknown code and advances nothing, so the column
            // collapses instead of holding a position: `ESC[10Chello` comes
            // back as `hello` at column 0, and any background colour on the
            // blank cell is lost with it. A space cell moves the cursor
            // forward exactly one column, under whatever SGR run is already
            // open, so a coloured blank still paints its background.
            let character = cell.getCharacter()
            out.append(character == Character(Unicode.Scalar(0)) ? " " : character)
        }
        // Never leave an attribute open across a line boundary.
        if openAttribute != nil { out += "\u{1b}[0m" }
        return out
    }
}
